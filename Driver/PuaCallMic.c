// PUA Call Mic: a minimal AudioServerPlugIn loopback device for call audio injection.
//
// One device, one input stream and one output stream, 48 kHz mono Float32.
// Audio written to the output side (by `pua audio-stream`) is read back on the input side
// (by the Phone app, which uses this device as its microphone). Reads clear the ring, so a
// stopped writer yields silence instead of a repeating buffer.
//
// Object IDs: 1 plug-in, 2 device, 3 input stream, 4 output stream. No controls.
// SPDX-License-Identifier: MIT

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>

#define kPlugInBundleID   "dev.pua.callmic"
#define kDeviceName       "PUA Call Mic"
#define kDeviceUID        "dev.pua.callmic.device"
#define kModelUID         "dev.pua.callmic.model"
#define kManufacturer     "pua"

enum { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStreamIn = 3, kObjStreamOut = 4 };

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannels = 1;
static const UInt32 kRingFrames = 16384;  // ~341 ms; also the zero time stamp period
static const UInt32 kBytesPerFrame = sizeof(Float32) * 1;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static UInt64 gIORunning = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static Float32 gRing[16384];

// MARK: - Forward declarations

static HRESULT PlugIn_QueryInterface(void*, REFIID, LPVOID*);
static ULONG PlugIn_AddRef(void*);
static ULONG PlugIn_Release(void*);
static OSStatus PlugIn_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus PlugIn_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus PlugIn_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus PlugIn_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus PlugIn_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus PlugIn_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus PlugIn_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean PlugIn_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus PlugIn_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus PlugIn_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus PlugIn_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus PlugIn_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus PlugIn_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus PlugIn_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus PlugIn_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus PlugIn_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus PlugIn_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus PlugIn_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus PlugIn_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    PlugIn_QueryInterface, PlugIn_AddRef, PlugIn_Release,
    PlugIn_Initialize, PlugIn_CreateDevice, PlugIn_DestroyDevice,
    PlugIn_AddDeviceClient, PlugIn_RemoveDeviceClient,
    PlugIn_PerformDeviceConfigurationChange, PlugIn_AbortDeviceConfigurationChange,
    PlugIn_HasProperty, PlugIn_IsPropertySettable, PlugIn_GetPropertyDataSize,
    PlugIn_GetPropertyData, PlugIn_SetPropertyData,
    PlugIn_StartIO, PlugIn_StopIO, PlugIn_GetZeroTimeStamp,
    PlugIn_WillDoIOOperation, PlugIn_BeginIOOperation, PlugIn_DoIOOperation, PlugIn_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory and COM

void* PuaCallMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void* PuaCallMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT PlugIn_QueryInterface(void* driver, REFIID iid, LPVOID* out) {
    if (driver != gDriverRef || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *out = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG PlugIn_AddRef(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG PlugIn_Release(void* driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

// MARK: - Lifecycle

static OSStatus PlugIn_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 hostClockHz = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockHz / kSampleRate;
    return 0;
}

static OSStatus PlugIn_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus PlugIn_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus PlugIn_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return id == kObjDevice ? 0 : kAudioHardwareBadObjectError;
}
static OSStatus PlugIn_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return id == kObjDevice ? 0 : kAudioHardwareBadObjectError;
}
static OSStatus PlugIn_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}
static OSStatus PlugIn_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}

// MARK: - Property helpers

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean IsStream(AudioObjectID id) { return id == kObjStreamIn || id == kObjStreamOut; }

// Number of stream IDs the device reports for a scope, written into `out` (up to 2).
static UInt32 DeviceStreams(AudioObjectPropertyScope scope, AudioObjectID* out) {
    UInt32 n = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) out[n++] = kObjStreamIn;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) out[n++] = kObjStreamOut;
    return n;
}

#define RETURN_SIZE(T) do { *outSize = sizeof(T); return 0; } while (0)

static Boolean PlugIn_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (d != gDriverRef || a == NULL) return false;
    UInt32 sz = 0;
    // A property exists exactly when its size can be computed.
    return PlugIn_GetPropertyDataSize(d, id, pid, a, 0, NULL, &sz) == 0;
}

static OSStatus PlugIn_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* outSettable) {
    if (d != gDriverRef || a == NULL || outSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!PlugIn_HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    // Formats and the sample rate accept their single supported value, so clients may "set" them.
    *outSettable = (IsStream(id) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat))
                || (id == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate);
    return 0;
}

static OSStatus PlugIn_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32* outSize) {
    (void)pid; (void)qs; (void)qd;
    if (d != gDriverRef || a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    AudioObjectID tmp[2];
    switch (id) {
    case kObjPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID);
        case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID);
        case kAudioObjectPropertyManufacturer: case kAudioPlugInPropertyResourceBundle: RETURN_SIZE(CFStringRef);
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: RETURN_SIZE(AudioObjectID);
        case kAudioPlugInPropertyTranslateUIDToDevice: RETURN_SIZE(AudioObjectID);
        default: return kAudioHardwareUnknownPropertyError;
        }
    case kObjDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID);
        case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID);
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: RETURN_SIZE(CFStringRef);
        case kAudioDevicePropertyTransportType: case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_SIZE(UInt32);
        case kAudioDevicePropertyRelatedDevices: RETURN_SIZE(AudioObjectID);
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
            *outSize = DeviceStreams(a->mScope, tmp) * (UInt32)sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyControlList: *outSize = 0; return 0;
        case kAudioDevicePropertyNominalSampleRate: RETURN_SIZE(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates: RETURN_SIZE(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout: *outSize = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * (UInt32)sizeof(AudioChannelDescription); return 0;
        default: return kAudioHardwareUnknownPropertyError;
        }
    case kObjStreamIn: case kObjStreamOut:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: RETURN_SIZE(AudioClassID);
        case kAudioObjectPropertyOwner: RETURN_SIZE(AudioObjectID);
        case kAudioObjectPropertyName: RETURN_SIZE(CFStringRef);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: RETURN_SIZE(UInt32);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: RETURN_SIZE(AudioStreamBasicDescription);
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: RETURN_SIZE(AudioStreamRangedDescription);
        default: return kAudioHardwareUnknownPropertyError;
        }
    default:
        return kAudioHardwareBadObjectError;
    }
}

#define WRITE(T, V) do { if (inSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; *(T*)outData = (V); *outSize = sizeof(T); return 0; } while (0)

static OSStatus PlugIn_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32 inSize, UInt32* outSize, void* outData) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    AudioObjectID streams[2];
    switch (id) {
    case kObjPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: WRITE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: WRITE(CFStringRef, CFSTR(kManufacturer));
        case kAudioPlugInPropertyResourceBundle: WRITE(CFStringRef, CFSTR(""));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
            if (inSize < sizeof(AudioObjectID)) { *outSize = 0; return 0; }
            WRITE(AudioObjectID, kObjDevice);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qs != sizeof(CFStringRef) || qd == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)qd;
            WRITE(AudioObjectID, (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) ? kObjDevice : kAudioObjectUnknown);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    case kObjDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: WRITE(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName: WRITE(CFStringRef, CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer: WRITE(CFStringRef, CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID: WRITE(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID: WRITE(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: WRITE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: WRITE(AudioObjectID, kObjDevice);
        case kAudioDevicePropertyClockDomain: WRITE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: WRITE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIORunning > 0;
            pthread_mutex_unlock(&gStateMutex);
            WRITE(UInt32, running);
        }
        // Selectable as a default microphone, never offered as a default speaker.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: WRITE(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: WRITE(UInt32, 0);
        case kAudioDevicePropertyLatency: WRITE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: WRITE(UInt32, 0);
        case kAudioDevicePropertyIsHidden: WRITE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: WRITE(UInt32, kRingFrames);
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            UInt32 n = DeviceStreams(a->mScope, streams);
            UInt32 fit = inSize / (UInt32)sizeof(AudioObjectID);
            if (fit < n) n = fit;
            memcpy(outData, streams, n * sizeof(AudioObjectID));
            *outSize = n * (UInt32)sizeof(AudioObjectID);
            return 0;
        }
        case kAudioObjectPropertyControlList: *outSize = 0; return 0;
        case kAudioDevicePropertyNominalSampleRate: WRITE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            if (inSize < sizeof(r)) { *outSize = 0; return 0; }
            WRITE(AudioValueRange, r);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 1;
            *outSize = 2 * sizeof(UInt32);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 need = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * (UInt32)sizeof(AudioChannelDescription);
            if (inSize < need) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            memset(l, 0, need);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            *outSize = need;
            return 0;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    case kObjStreamIn: case kObjStreamOut: {
        Boolean input = id == kObjStreamIn;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: WRITE(AudioObjectID, kObjDevice);
        case kAudioObjectPropertyName: WRITE(CFStringRef, input ? CFSTR("PUA Call Mic Input") : CFSTR("PUA Call Mic Feed"));
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
        case kAudioStreamPropertyIsActive: WRITE(UInt32, 1);
        case kAudioStreamPropertyDirection: WRITE(UInt32, input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: WRITE(UInt32, input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: WRITE(UInt32, 1);
        case kAudioStreamPropertyLatency: WRITE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            WRITE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = StreamFormat();
            r.mSampleRateRange.mMinimum = kSampleRate;
            r.mSampleRateRange.mMaximum = kSampleRate;
            if (inSize < sizeof(r)) { *outSize = 0; return 0; }
            WRITE(AudioStreamRangedDescription, r);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    default:
        return kAudioHardwareBadObjectError;
    }
}

static OSStatus PlugIn_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32 inSize, const void* inData) {
    (void)pid; (void)qs; (void)qd;
    if (d != gDriverRef || a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (id == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)inData == kSampleRate ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    if (IsStream(id) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = inData;
        AudioStreamBasicDescription ours = StreamFormat();
        Boolean same = f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID
                    && f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel
                    && (f->mFormatFlags & kAudioFormatFlagIsFloat);
        return same ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus PlugIn_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof(gRing));
    }
    ++gIORunning;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus PlugIn_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning > 0) --gIORunning;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus PlugIn_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) ++gNumberTimeStamps;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus PlugIn_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean* outWill, Boolean* outInPlace) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    Boolean will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWill) *outWill = will;
    if (outInPlace) *outInPlace = true;
    return 0;
}

static OSStatus PlugIn_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjDevice) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus PlugIn_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjDevice) ? 0 : kAudioHardwareBadObjectError;
}

// The ring is indexed by absolute sample time. Writes land at the output sample time; reads
// at the (earlier) input sample time pick them up one IO cycle later. Reads zero what they
// consume so a stalled writer produces silence.
static OSStatus PlugIn_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* main, void* secondary) {
    (void)client; (void)secondary;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    if (main == NULL || info == NULL || frames > kRingFrames) return kAudioHardwareIllegalOperationError;
    Float32* buf = (Float32*)main;
    if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjStreamOut) {
        UInt64 start = (UInt64)info->mOutputTime.mSampleTime % kRingFrames;
        UInt32 first = kRingFrames - (UInt32)start;
        if (first > frames) first = frames;
        memcpy(gRing + start, buf, first * kBytesPerFrame);
        memcpy(gRing, buf + first, (frames - first) * kBytesPerFrame);
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjStreamIn) {
        UInt64 start = (UInt64)info->mInputTime.mSampleTime % kRingFrames;
        UInt32 first = kRingFrames - (UInt32)start;
        if (first > frames) first = frames;
        memcpy(buf, gRing + start, first * kBytesPerFrame);
        memcpy(buf + first, gRing, (frames - first) * kBytesPerFrame);
        memset(gRing + start, 0, first * kBytesPerFrame);
        memset(gRing, 0, (frames - first) * kBytesPerFrame);
    }
    return 0;
}
