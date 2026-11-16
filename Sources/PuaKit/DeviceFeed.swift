import AudioToolbox
import CoreAudio
import Foundation

/// Renders PCM into an output device (the `PUA Call Mic` virtual device) through an AUHAL output
/// unit. Whatever is written to `source` becomes the device's input, which the Phone app reads as
/// its microphone. This is the uplink: our voice to the caller.
public final class DeviceFeed: @unchecked Sendable {
    public let device: AudioDevice
    public private(set) var renderCallbacks: UInt64 = 0
    public private(set) var underrunFrames: UInt64 = 0

    private let source: SampleRing
    private var unit: AudioUnit?
    private let silence = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)

    public init(device: AudioDevice, source: SampleRing) {
        self.device = device
        self.source = source
        silence.initialize(repeating: 0, count: 16_384)
    }

    public func start() throws {
        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &acd) else {
            throw PuaError("no_hal_output", "HAL output component not found")
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        guard let unit else { throw PuaError("no_hal_output", "AudioComponentInstanceNew returned nil") }
        self.unit = unit

        var deviceID = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "set CurrentDevice")

        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set StreamFormat")

        var callback = AURenderCallbackStruct(inputProc: { ctx, _, _, _, frames, ioData in
            let me = Unmanaged<DeviceFeed>.fromOpaque(ctx).takeUnretainedValue()
            return me.render(frames: Int(frames), ioData: ioData)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set RenderCallback")

        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        renderCallbacks &+= 1
        guard let ioData, let buffer = UnsafeMutableAudioBufferListPointer(ioData).first,
              let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let got = source.read(out, frames)
        if got < frames {
            underrunFrames &+= UInt64(frames - got)
            (out + got).update(repeating: 0, count: frames - got)
        }
        return noErr
    }

    public func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
    }

    deinit {
        stop()
        silence.deallocate()
    }
}
