import CoreAudio
import Darwin
import Foundation

public struct PuaError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var description: String { "\(code): \(message)" }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw PuaError("coreaudio_error", "\(what) failed (\(fourCC(status)))") }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(bytes: bytes, encoding: .ascii)! + "'" }
    return String(status)
}

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

/// UID of the `PUA Call Mic` virtual device published by Driver/PuaCallMic.c.
public let callMicUID = "dev.pua.callmic.device"
/// Output-only twin of PUA Call Mic on the same clock; whatever plays here comes out of the mic.
public let callFeedUID = "dev.pua.callmic.feed"

func caGet<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var addr = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    try check(status, "get \(fourCC(OSStatus(bitPattern: selector)))")
    return value
}

func caGetArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size")
    var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
    if values.isEmpty { return [] }
    let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
    try check(status, "get array")
    return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
}

func caString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
    return ref.takeRetainedValue() as String
}

// MARK: - Devices

public struct AudioDevice: Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let transport: UInt32

    public var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }
    public var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual }

    public static func all() -> [AudioDevice] {
        let ids = (try? caGetArray(systemObject, kAudioHardwarePropertyDevices, AudioObjectID(0))) ?? []
        return ids.compactMap { AudioDevice(id: $0) }
    }

    public static func find(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }
    public static func find(name: String) -> AudioDevice? { all().first { $0.name == name } }

    public static func defaultDevice(input: Bool) -> AudioDevice? {
        let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = try? caGet(systemObject, sel, AudioObjectID(0)), id != 0 else { return nil }
        return AudioDevice(id: id)
    }

    init?(id: AudioObjectID) {
        guard let uid = caString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        self.id = id
        self.uid = uid
        self.name = caString(id, kAudioObjectPropertyName) ?? uid
        self.inputChannels = AudioDevice.channels(id, kAudioObjectPropertyScopeInput)
        self.outputChannels = AudioDevice.channels(id, kAudioObjectPropertyScopeOutput)
        self.transport = (try? caGet(id, kAudioDevicePropertyTransportType, UInt32(0))) ?? 0
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public var json: [String: Any] {
        ["id": id, "uid": uid, "name": name, "input_channels": inputChannels,
         "output_channels": outputChannels, "aggregate": isAggregate, "virtual": isVirtual]
    }
}

// MARK: - Core Audio process objects (macOS 14+)

public struct AudioProcess: Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let runningInput: Bool
    public let runningOutput: Bool

    public static func all() -> [AudioProcess] {
        let ids = (try? caGetArray(systemObject, kAudioHardwarePropertyProcessObjectList, AudioObjectID(0))) ?? []
        return ids.map { id in
            AudioProcess(
                objectID: id,
                pid: (try? caGet(id, kAudioProcessPropertyPID, pid_t(0))) ?? 0,
                bundleID: caString(id, kAudioProcessPropertyBundleID) ?? "",
                runningInput: ((try? caGet(id, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0) != 0,
                runningOutput: ((try? caGet(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0)
        }
    }

    /// Translates a PID into its Core Audio process object (0 when it has no audio client).
    public static func objectID(for pid: pid_t) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr ? object : 0
    }

    public var json: [String: Any] {
        ["object_id": objectID, "pid": pid, "bundle_id": bundleID, "name": processName(pid) ?? "",
         "running_input": runningInput, "running_output": runningOutput]
    }
}

// MARK: - Process lookup

public func processName(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 1024)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

public func pids(named name: String) -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(n, 0))).filter { $0 > 0 && processName($0) == name }
}

/// PIDs that render call audio: Core Audio process objects matching the bundle ID first,
/// then any process with that executable name.
public func callAudioPIDs(bundleID: String) -> [pid_t] {
    let fromCoreAudio = AudioProcess.all().filter { $0.bundleID == bundleID }.map(\.pid)
    if !fromCoreAudio.isEmpty { return fromCoreAudio }
    let exe = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    return pids(named: exe)
}
