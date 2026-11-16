import Darwin
import Foundation

/// Bounded single-producer/single-consumer Float32 ring guarded by an unfair lock.
/// Real-time callbacks only hold the lock for a memcpy.
public final class SampleRing: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let storage: UnsafeMutablePointer<Float>
    public let capacity: Int
    private var readIndex = 0
    private var count = 0
    public private(set) var droppedFrames: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    public var available: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    /// Appends samples; when full, the oldest samples are dropped (counted in `droppedFrames`).
    public func write(_ src: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var src = src, n = n
        if n > capacity { droppedFrames += UInt64(n - capacity); src += n - capacity; n = capacity }
        let overflow = count + n - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            count -= overflow
            droppedFrames += UInt64(overflow)
        }
        var writeIndex = (readIndex + count) % capacity
        var remaining = n
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            (storage + writeIndex).update(from: src + (n - remaining), count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            remaining -= chunk
        }
        count += n
    }

    /// Reads up to `n` samples, returns how many were copied.
    @discardableResult
    public func read(_ dst: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let take = min(n, count)
        var copied = 0
        while copied < take {
            let chunk = min(take - copied, capacity - readIndex)
            (dst + copied).update(from: storage + readIndex, count: chunk)
            readIndex = (readIndex + chunk) % capacity
            copied += chunk
        }
        count -= take
        return take
    }

    public func clear() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        readIndex = 0; count = 0
    }
}

/// Streaming linear resampler (mono). Only used when a tap does not run at 48 kHz.
public final class LinearResampler {
    private let step: Double
    private var position: Double = 0
    private var last: Float = 0
    public init(from: Double, to: Double) { step = from / to }

    /// Returns the number of output samples written into `out` (capacity must be ≥ n / step + 2).
    /// Extended index 0 is the previous block's last sample; index k is `input[k - 1]`.
    public func process(_ input: UnsafePointer<Float>, _ n: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        guard n > 0 else { return 0 }
        var produced = 0
        while position < Double(n) {
            let i = Int(position)
            let frac = Float(position - Double(i))
            let a = i == 0 ? last : input[i - 1]
            let b = input[i]
            out[produced] = a + (b - a) * frac
            produced += 1
            position += step
        }
        position -= Double(n)
        last = input[n - 1]
        return produced
    }
}

public enum PCM16 {
    public static func toFloat(_ src: UnsafePointer<Int16>, _ n: Int, _ dst: UnsafeMutablePointer<Float>) {
        for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768.0 }
    }

    public static func fromFloat(_ src: UnsafePointer<Float>, _ n: Int, _ dst: UnsafeMutablePointer<Int16>) {
        for i in 0..<n {
            let v = max(-1, min(1, src[i]))
            dst[i] = Int16(v * 32767).littleEndian
        }
    }
}

public struct Level {
    public var peak: Float = 0
    public var sumSquares: Double = 0
    public var frames: UInt64 = 0
    /// Upward zero crossings of non-trivial samples, for a rough pitch estimate in self-tests.
    public var crossings: UInt64 = 0
    public var activeFrames: UInt64 = 0
    private var wasNegative = false

    public init() {}

    public mutating func add(_ p: UnsafePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let v = p[i]
            peak = max(peak, abs(v))
            sumSquares += Double(v * v)
            if abs(v) > 0.001 { activeFrames += 1 }
            if v < -0.001 { wasNegative = true } else if v > 0.001, wasNegative { crossings += 1; wasNegative = false }
        }
        frames += UInt64(n)
    }

    public var rms: Double { frames == 0 ? 0 : (sumSquares / Double(frames)).squareRoot() }

    /// Estimated frequency over the frames that carried signal.
    public func frequency(sampleRate: Double) -> Double {
        activeFrames == 0 ? 0 : Double(crossings) / (Double(activeFrames) / sampleRate)
    }

    public var json: [String: Any] {
        ["peak": (Double(peak) * 10_000).rounded() / 10_000, "rms": (rms * 10_000).rounded() / 10_000, "frames": frames]
    }
}

/// Generates a mono Float32 sine.
public func sine(frequency: Double, amplitude: Float, seconds: Double, rate: Double = 48_000) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
}

/// Writes all bytes to a file descriptor, retrying partial writes. Returns false on EPIPE/EBADF.
func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ n: Int) -> Bool {
    var off = 0
    while off < n {
        let w = Darwin.write(fd, ptr + off, n - off)
        if w < 0 {
            if errno == EINTR || errno == EAGAIN { usleep(1000); continue }
            return false
        }
        off += w
    }
    return true
}

public final class Events: @unchecked Sendable {
    public static let shared = Events()
    private let queue = DispatchQueue(label: "pua.events")
    public var fd: Int32 = 2

    public func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["event"] = event
        obj["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        queue.sync {
            data.withUnsafeBytes { _ = writeAll(fd, $0.baseAddress!, data.count) }
            _ = writeAll(fd, "\n", 1)
        }
    }
}
