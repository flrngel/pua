import AudioToolbox
import CoreAudio
import Foundation

/// Captures the mixed output of a set of processes (for example `avconferenced`, which renders
/// Continuity call audio) through a private Core Audio process tap and a private aggregate device.
/// Delivers 48 kHz mono Float32 into `sink`.
@available(macOS 14.2, *)
public final class ProcessTapCapture: @unchecked Sendable {
    public static let outputRate: Double = 48_000

    public let pids: [pid_t]
    public let mute: Bool
    public private(set) var tapFormat = AudioStreamBasicDescription()
    public private(set) var callbacks: UInt64 = 0
    public private(set) var level = Level()

    private let sink: SampleRing
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var resampler: LinearResampler?
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 65_536)

    /// - Parameter mute: when true the tapped processes are silenced on their real output device
    ///   while tapped (`CATapMuteBehavior.muted`), so the caller is not heard on the speakers.
    public init(pids: [pid_t], mute: Bool, sink: SampleRing) throws {
        self.pids = pids
        self.mute = mute
        self.sink = sink
        let objects = pids.map(AudioProcess.objectID(for:)).filter { $0 != 0 }
        guard !objects.isEmpty else {
            throw PuaError("no_audio_process", "none of PIDs \(pids) is a Core Audio client yet (is a call connected?)")
        }
        let desc = CATapDescription(monoMixdownOfProcesses: objects)
        desc.name = "pua call capture"
        desc.isPrivate = true
        desc.muteBehavior = mute ? .muted : .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")
        do {
            tapFormat = try caGet(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tapFormat.mBitsPerChannel == 32 else {
                throw PuaError("tap_format", "unexpected tap format (expected Float32 PCM)")
            }
            if tapFormat.mSampleRate != Self.outputRate {
                resampler = LinearResampler(from: tapFormat.mSampleRate, to: Self.outputRate)
            }
            let uid = "dev.pua.capture." + UUID().uuidString
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "pua call capture",
                kAudioAggregateDeviceUIDKey: uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    public func start() throws {
        let channels = Int(max(tapFormat.mChannelsPerFrame, 1))
        let nonInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { [unowned self] _, inData, _, _, _ in
            self.handle(inData, channels: channels, nonInterleaved: nonInterleaved)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, ioProc), "AudioDeviceStart")
    }

    private func handle(_ inData: UnsafePointer<AudioBufferList>, channels: Int, nonInterleaved: Bool) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = list.first, let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        callbacks &+= 1

        // Fold to mono into `scratch`. A mono mixdown tap already has one channel.
        let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        var frames = channels > 0 ? totalFloats / channels : totalFloats
        if frames > 32_768 { frames = 32_768 }
        if channels == 1 {
            scratch.update(from: base, count: frames)
        } else if nonInterleaved {
            for ch in 0..<channels {
                guard ch < list.count, let p = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames { scratch[f] = (ch == 0 ? 0 : scratch[f]) + p[f] / Float(channels) }
            }
        } else {
            for f in 0..<frames {
                var acc: Float = 0
                for ch in 0..<channels { acc += base[f * channels + ch] }
                scratch[f] = acc / Float(channels)
            }
        }

        if let resampler {
            let out = scratch + 32_768
            let produced = resampler.process(scratch, frames, into: out)
            level.add(out, produced)
            sink.write(out, produced)
        } else {
            level.add(scratch, frames)
            sink.write(scratch, frames)
        }
    }

    public func stop() {
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    deinit {
        stop()
        scratch.deallocate()
    }
}
