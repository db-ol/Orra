// Orra Microphone, a loopback audio device for macOS.
//
// An Audio Server plug in that coreaudiod loads. It publishes one device with an output
// stream and an input stream. Whatever is played to the output side comes back on the
// input side a few milliseconds later, so Orra can play translated speech to the output
// side and a call app such as Google Meet can pick the device as its microphone.
//
// Written from the interface in CoreAudio/AudioServerPlugIn.h. The object layout follows
// the pattern of Apple's NullAudio sample: a plug in object, one device and two streams,
// all with fixed object IDs.
//
// The IO functions (GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation and
// EndIOOperation) run on the real time IO thread of coreaudiod. They never allocate, never
// lock and never log. They use only atomics and a ring buffer that lives in static storage.
//
// Copyright (c) 2026 Orra contributors. MIT License, see LICENSE in the repository root.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

#pragma mark Configuration

#define kOrraManufacturer       "Orra"
#define kOrraDeviceName         "Orra Microphone"
#define kOrraDeviceUID          "io.github.db-ol.Orra.Microphone"
#define kOrraDeviceModelUID     "io.github.db-ol.Orra.Microphone.Model"
#define kOrraInputStreamName    "Orra Microphone Input"
#define kOrraOutputStreamName   "Orra Microphone Output"

// One fixed format, 48 kHz interleaved 32 bit float stereo. Call apps take it as is, and
// Orra converts the speech it plays to it.
#define kOrraSampleRate         48000.0
#define kOrraChannelCount       2u
#define kOrraBytesPerFrame      (kOrraChannelCount * (UInt32)sizeof(Float32))

// The ring buffer holds 16384 frames, about 340 ms at 48 kHz. The zero time stamp period is
// the same length, so one zero time stamp marks one trip around the ring.
#define kOrraRingFrames         16384u

// The object IDs. kAudioObjectPlugInObject (1) is the plug in itself.
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_InputStream   = 3,
    kObjectID_OutputStream  = 4,
};

#pragma mark State

// State that the control threads change. gStateMutex guards it. The IO thread never takes
// the mutex. It reads only the atomics below.
static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32                   gIORunningCount = 0;
static bool                     gInputStreamActive = true;
static bool                     gOutputStreamActive = true;

// Time keeping. StartIO sets the anchor before the IO thread starts. gHostTicksPerPeriod is
// set once in Initialize.
static _Atomic(UInt64)          gAnchorHostTime = 0;
static Float64                  gHostTicksPerFrame = 0.0;
static Float64                  gHostTicksPerPeriod = 0.0;

// The loopback buffer. Frame f of the device timeline lives at index f modulo
// kOrraRingFrames. gWriteEnd is one past the last sample time the output side wrote. Frames
// at or past it, or a whole ring or more before it, read as silence.
static Float32                  gRing[kOrraRingFrames * kOrraChannelCount];
static _Atomic(SInt64)          gWriteEnd = 0;

static _Atomic(ULONG)           gRefCount = 0;

#pragma mark Forward declarations

static HRESULT  Orra_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    Orra_AddRef(void* inDriver);
static ULONG    Orra_Release(void* inDriver);
static OSStatus Orra_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Orra_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus Orra_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Orra_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Orra_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Orra_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus Orra_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  Orra_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus Orra_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus Orra_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus Orra_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus Orra_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus Orra_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Orra_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Orra_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus Orra_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus Orra_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Orra_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus Orra_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark Driver interface

static AudioServerPlugInDriverInterface gDriverInterface = {
    ._reserved                          = NULL,
    .QueryInterface                     = Orra_QueryInterface,
    .AddRef                             = Orra_AddRef,
    .Release                            = Orra_Release,
    .Initialize                         = Orra_Initialize,
    .CreateDevice                       = Orra_CreateDevice,
    .DestroyDevice                      = Orra_DestroyDevice,
    .AddDeviceClient                    = Orra_AddDeviceClient,
    .RemoveDeviceClient                 = Orra_RemoveDeviceClient,
    .PerformDeviceConfigurationChange   = Orra_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange     = Orra_AbortDeviceConfigurationChange,
    .HasProperty                        = Orra_HasProperty,
    .IsPropertySettable                 = Orra_IsPropertySettable,
    .GetPropertyDataSize                = Orra_GetPropertyDataSize,
    .GetPropertyData                    = Orra_GetPropertyData,
    .SetPropertyData                    = Orra_SetPropertyData,
    .StartIO                            = Orra_StartIO,
    .StopIO                             = Orra_StopIO,
    .GetZeroTimeStamp                   = Orra_GetZeroTimeStamp,
    .WillDoIOOperation                  = Orra_WillDoIOOperation,
    .BeginIOOperation                   = Orra_BeginIOOperation,
    .DoIOOperation                      = Orra_DoIOOperation,
    .EndIOOperation                     = Orra_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

#pragma mark Factory

// The factory that Info.plist names under CFPlugInFactories. coreaudiod calls it with the
// Audio Server plug in type and gets the one driver object back.
__attribute__((visibility("default")))
void* OrraMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void* OrraMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (inRequestedTypeUUID != NULL && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

#pragma mark Helpers

static bool IsStream(AudioObjectID inObjectID)
{
    return inObjectID == kObjectID_InputStream || inObjectID == kObjectID_OutputStream;
}

static AudioStreamBasicDescription StreamFormat(void)
{
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate       = kOrraSampleRate;
    format.mFormatID         = kAudioFormatLinearPCM;
    format.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket   = kOrraBytesPerFrame;
    format.mFramesPerPacket  = 1;
    format.mBytesPerFrame    = kOrraBytesPerFrame;
    format.mChannelsPerFrame = kOrraChannelCount;
    format.mBitsPerChannel   = 32;
    return format;
}

static bool FormatIsSupported(const AudioStreamBasicDescription* inFormat)
{
    AudioStreamBasicDescription supported = StreamFormat();
    return inFormat->mSampleRate == supported.mSampleRate
        && inFormat->mFormatID == supported.mFormatID
        && inFormat->mFormatFlags == supported.mFormatFlags
        && inFormat->mBytesPerPacket == supported.mBytesPerPacket
        && inFormat->mFramesPerPacket == supported.mFramesPerPacket
        && inFormat->mBytesPerFrame == supported.mBytesPerFrame
        && inFormat->mChannelsPerFrame == supported.mChannelsPerFrame
        && inFormat->mBitsPerChannel == supported.mBitsPerChannel;
}

// The streams of the device in a scope: input, output, or both for the global scope.
static UInt32 StreamsInScope(AudioObjectPropertyScope inScope, AudioObjectID outIDs[2])
{
    UInt32 count = 0;
    if (inScope == kAudioObjectPropertyScopeGlobal || inScope == kAudioObjectPropertyScopeInput) {
        outIDs[count++] = kObjectID_InputStream;
    }
    if (inScope == kAudioObjectPropertyScopeGlobal || inScope == kAudioObjectPropertyScopeOutput) {
        outIDs[count++] = kObjectID_OutputStream;
    }
    return count;
}

// Copies as many object IDs as fit in the caller's buffer, which is how the HAL expects
// list properties to behave.
static OSStatus CopyIDs(const AudioObjectID* inIDs, UInt32 inCount, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    UInt32 fit = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (fit > inCount) {
        fit = inCount;
    }
    if (fit > 0) {
        memcpy(outData, inIDs, fit * sizeof(AudioObjectID));
    }
    *outDataSize = fit * (UInt32)sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

#define REQUIRE_SIZE(type) \
    do { if (inDataSize < sizeof(type)) { return kAudioHardwareBadPropertySizeError; } } while (0)

#define RETURN_VALUE(type, value) \
    do { REQUIRE_SIZE(type); *((type*)outData) = (value); *outDataSize = (UInt32)sizeof(type); return kAudioHardwareNoError; } while (0)

#pragma mark IUnknown

static HRESULT Orra_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    } else {
        *outInterface = NULL;
    }
    CFRelease(requested);
    return result;
}

static ULONG Orra_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) {
        return 0;
    }
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Orra_Release(void* inDriver)
{
    if (inDriver != gDriverRef) {
        return 0;
    }
    // The driver object is static, so nothing is freed when the count reaches zero.
    ULONG current = atomic_load(&gRefCount);
    while (current > 0 && !atomic_compare_exchange_weak(&gRefCount, &current, current - 1)) {
    }
    return current > 0 ? current - 1 : 0;
}

#pragma mark Basic operations

static OSStatus Orra_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostTicksPerSecond = 1.0e9 * (Float64)timebase.denom / (Float64)timebase.numer;

    pthread_mutex_lock(&gStateMutex);
    gHost = inHost;
    gHostTicksPerFrame = hostTicksPerSecond / kOrraSampleRate;
    gHostTicksPerPeriod = gHostTicksPerFrame * (Float64)kOrraRingFrames;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Orra_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Orra_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Orra_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return inDeviceObjectID == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Orra_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    return inDeviceObjectID == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// The device never asks for a configuration change, so the host never calls these with
// one of ours.
static OSStatus Orra_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus Orra_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

#pragma mark Properties

static Boolean PlugInHasProperty(AudioObjectPropertySelector inSelector)
{
    switch (inSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static Boolean DeviceHasProperty(AudioObjectPropertySelector inSelector, AudioObjectPropertyScope inScope)
{
    switch (inSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        // These have a meaning only for the input or the output side.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return inScope == kAudioObjectPropertyScopeInput || inScope == kAudioObjectPropertyScopeOutput;
        default:
            return false;
    }
}

static Boolean StreamHasProperty(AudioObjectPropertySelector inSelector)
{
    switch (inSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean Orra_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) {
        return false;
    }
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return PlugInHasProperty(inAddress->mSelector);
        case kObjectID_Device:
            return DeviceHasProperty(inAddress->mSelector, inAddress->mScope);
        case kObjectID_InputStream:
        case kObjectID_OutputStream:
            return StreamHasProperty(inAddress->mSelector);
        default:
            return false;
    }
}

static OSStatus Orra_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Orra_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    // A stream can be turned off and on. The device has one rate and one format, so
    // nothing else changes.
    *outIsSettable = IsStream(inObjectID) && inAddress->mSelector == kAudioStreamPropertyIsActive;
    return kAudioHardwareNoError;
}

static OSStatus Orra_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Orra_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    AudioObjectID streams[2];
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kObjectID_PlugIn) {
                *outDataSize = sizeof(AudioObjectID);
            } else if (inObjectID == kObjectID_Device) {
                *outDataSize = StreamsInScope(inAddress->mScope, streams) * (UInt32)sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *outDataSize = StreamsInScope(inAddress->mScope, streams) * (UInt32)sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        default:
            // Everything else the objects publish is a UInt32.
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
    }
}

static OSStatus GetPlugInPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    static const AudioObjectID devices[1] = { kObjectID_Device };
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:
            RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer:
            RETURN_VALUE(CFStringRef, CFSTR(kOrraManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return CopyIDs(devices, 1, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            REQUIRE_SIZE(AudioObjectID);
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) {
                return kAudioHardwareBadPropertySizeError;
            }
            CFStringRef uid = *((const CFStringRef*)inQualifierData);
            AudioObjectID device = kAudioObjectUnknown;
            if (uid != NULL && CFStringCompare(uid, CFSTR(kOrraDeviceUID), 0) == kCFCompareEqualTo) {
                device = kObjectID_Device;
            }
            *((AudioObjectID*)outData) = device;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyResourceBundle:
            // The path of the resources relative to the bundle. The device has none.
            RETURN_VALUE(CFStringRef, CFSTR(""));
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    AudioObjectID streams[2];
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:
            RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:
            RETURN_VALUE(CFStringRef, CFSTR(kOrraDeviceName));
        case kAudioObjectPropertyManufacturer:
            RETURN_VALUE(CFStringRef, CFSTR(kOrraManufacturer));
        case kAudioDevicePropertyDeviceUID:
            RETURN_VALUE(CFStringRef, CFSTR(kOrraDeviceUID));
        case kAudioDevicePropertyModelUID:
            RETURN_VALUE(CFStringRef, CFSTR(kOrraDeviceModelUID));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            UInt32 count = StreamsInScope(inAddress->mScope, streams);
            return CopyIDs(streams, count, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: {
            static const AudioObjectID related[1] = { kObjectID_Device };
            return CopyIDs(related, 1, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyClockDomain:
            RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive:
            RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIORunningCount > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // The input side may be the default microphone. The output side never becomes
            // the default speaker, so system sounds and music never reach a call by accident.
            RETURN_VALUE(UInt32, inAddress->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate:
            RETURN_VALUE(Float64, kOrraSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = { kOrraSampleRate, kOrraSampleRate };
            UInt32 fit = inDataSize / (UInt32)sizeof(AudioValueRange);
            if (fit > 0) {
                *((AudioValueRange*)outData) = range;
            }
            *outDataSize = (fit > 0 ? 1 : 0) * (UInt32)sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyIsHidden:
            RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
            RETURN_VALUE(UInt32, kOrraRingFrames);
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    bool isInput = inObjectID == kObjectID_InputStream;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:
            RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyName:
            RETURN_VALUE(CFStringRef, isInput ? CFSTR(kOrraInputStreamName) : CFSTR(kOrraOutputStreamName));
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 active = (isInput ? gInputStreamActive : gOutputStreamActive) ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, active);
        }
        case kAudioStreamPropertyDirection:
            // 1 means input, 0 means output.
            RETURN_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel:
            RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency:
            RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 fit = inDataSize / (UInt32)sizeof(AudioStreamRangedDescription);
            if (fit > 0) {
                AudioStreamRangedDescription ranged;
                ranged.mFormat = StreamFormat();
                ranged.mSampleRateRange.mMinimum = kOrraSampleRate;
                ranged.mSampleRateRange.mMaximum = kOrraSampleRate;
                *((AudioStreamRangedDescription*)outData) = ranged;
            }
            *outDataSize = (fit > 0 ? 1 : 0) * (UInt32)sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Orra_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || outDataSize == NULL || (outData == NULL && inDataSize > 0)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Orra_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    switch (inObjectID) {
        case kObjectID_PlugIn:
            return GetPlugInPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Device:
            return GetDevicePropertyData(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_InputStream:
        case kObjectID_OutputStream:
            return GetStreamPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Orra_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Orra_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsStream(inObjectID) && inAddress->mSelector == kAudioStreamPropertyIsActive) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        bool active = *((const UInt32*)inData) != 0;
        bool changed;
        pthread_mutex_lock(&gStateMutex);
        bool* flag = inObjectID == kObjectID_InputStream ? &gInputStreamActive : &gOutputStreamActive;
        changed = *flag != active;
        *flag = active;
        AudioServerPlugInHostRef host = gHost;
        pthread_mutex_unlock(&gStateMutex);
        if (changed && host != NULL) {
            AudioObjectPropertyAddress changedAddress = {
                kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            host->PropertiesChanged(host, inObjectID, 1, &changedAddress);
        }
        return kAudioHardwareNoError;
    }

    // A client may set the one rate or the one format the device already has.
    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        return *((const Float64*)inData) == kOrraSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    if (IsStream(inObjectID)
        && (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        return FormatIsSupported((const AudioStreamBasicDescription*)inData) ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark IO control

static OSStatus Orra_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    OSStatus status = kAudioHardwareNoError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount == UINT32_MAX) {
        status = kAudioHardwareIllegalOperationError;
    } else {
        if (gIORunningCount == 0) {
            // The first client starts the clock. The IO thread is not running yet, so the
            // ring can be cleared without racing it.
            memset(gRing, 0, sizeof(gRing));
            atomic_store(&gWriteEnd, 0);
            atomic_store(&gAnchorHostTime, mach_absolute_time());
        }
        gIORunningCount += 1;
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus Orra_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    OSStatus status = kAudioHardwareNoError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount == 0) {
        status = kAudioHardwareIllegalOperationError;
    } else {
        gIORunningCount -= 1;
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

#pragma mark IO (real time thread)

static OSStatus Orra_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    // The device clock is the host clock. Zero time stamps fall every kOrraRingFrames frames
    // after the anchor, and this returns the latest one that has passed. It holds no state,
    // so it needs no lock and always moves forward.
    UInt64 anchor = atomic_load_explicit(&gAnchorHostTime, memory_order_relaxed);
    UInt64 now = mach_absolute_time();
    UInt64 elapsed = now > anchor ? now - anchor : 0;
    UInt64 periods = (UInt64)((Float64)elapsed / gHostTicksPerPeriod);
    *outSampleTime = (Float64)(periods * kOrraRingFrames);
    *outHostTime = anchor + (UInt64)((Float64)periods * gHostTicksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus Orra_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    bool willDo = inOperationID == kAudioServerPlugInIOOperationReadInput
               || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != NULL) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true;
    }
    return kAudioHardwareNoError;
}

static OSStatus Orra_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

// Copies frames between the ring and a buffer. inStart is a sample time on the device
// timeline, and the copy wraps at the end of the ring.
static void RingCopy(SInt64 inStart, UInt32 inFrames, Float32* ioBuffer, bool inToRing)
{
    UInt32 offset = (UInt32)((UInt64)inStart % kOrraRingFrames);
    UInt32 first = kOrraRingFrames - offset;
    if (first > inFrames) {
        first = inFrames;
    }
    size_t firstBytes = (size_t)first * kOrraBytesPerFrame;
    size_t restBytes = (size_t)(inFrames - first) * kOrraBytesPerFrame;
    Float32* ringAtOffset = gRing + (size_t)offset * kOrraChannelCount;
    Float32* bufferRest = ioBuffer + (size_t)first * kOrraChannelCount;
    if (inToRing) {
        memcpy(ringAtOffset, ioBuffer, firstBytes);
        memcpy(gRing, bufferRest, restBytes);
    } else {
        memcpy(ioBuffer, ringAtOffset, firstBytes);
        memcpy(bufferRest, gRing, restBytes);
    }
}

static void RingClear(SInt64 inStart, UInt32 inFrames)
{
    UInt32 offset = (UInt32)((UInt64)inStart % kOrraRingFrames);
    UInt32 first = kOrraRingFrames - offset;
    if (first > inFrames) {
        first = inFrames;
    }
    memset(gRing + (size_t)offset * kOrraChannelCount, 0, (size_t)first * kOrraBytesPerFrame);
    memset(gRing, 0, (size_t)(inFrames - first) * kOrraBytesPerFrame);
}

// The output side. The HAL has already mixed every client that plays to the device into
// ioBuffer, so this runs once per IO cycle.
static void WriteMix(SInt64 inStart, UInt32 inFrames, const Float32* inBuffer)
{
    if (inStart < 0 || inFrames == 0) {
        return;
    }
    // A buffer longer than the ring keeps only its last ring of frames.
    if (inFrames > kOrraRingFrames) {
        inBuffer += (size_t)(inFrames - kOrraRingFrames) * kOrraChannelCount;
        inStart += inFrames - kOrraRingFrames;
        inFrames = kOrraRingFrames;
    }
    SInt64 writeEnd = atomic_load_explicit(&gWriteEnd, memory_order_relaxed);
    // After a pause in playback, the frames between the last write and this one still
    // hold audio from an earlier trip around the ring. Clear them so the input side reads
    // silence there instead of an echo.
    if (inStart > writeEnd) {
        SInt64 gapStart = writeEnd;
        if (inStart - gapStart > (SInt64)kOrraRingFrames) {
            gapStart = inStart - (SInt64)kOrraRingFrames;
        }
        RingClear(gapStart, (UInt32)(inStart - gapStart));
    }
    RingCopy(inStart, inFrames, (Float32*)inBuffer, true);
    SInt64 end = inStart + (SInt64)inFrames;
    if (end > writeEnd) {
        atomic_store_explicit(&gWriteEnd, end, memory_order_release);
    }
}

// The input side. Frames the output side has written within the last trip around the
// ring come back, everything else is silence.
static void ReadInput(SInt64 inStart, UInt32 inFrames, Float32* outBuffer)
{
    SInt64 writeEnd = atomic_load_explicit(&gWriteEnd, memory_order_acquire);
    SInt64 end = inStart + (SInt64)inFrames;
    SInt64 validStart = writeEnd - (SInt64)kOrraRingFrames;
    if (validStart < inStart) {
        validStart = inStart;
    }
    SInt64 validEnd = writeEnd < end ? writeEnd : end;
    if (validStart < 0) {
        validStart = 0;
    }
    if (validEnd <= validStart) {
        memset(outBuffer, 0, (size_t)inFrames * kOrraBytesPerFrame);
        return;
    }
    UInt32 lead = (UInt32)(validStart - inStart);
    UInt32 count = (UInt32)(validEnd - validStart);
    UInt32 tail = inFrames - lead - count;
    if (lead > 0) {
        memset(outBuffer, 0, (size_t)lead * kOrraBytesPerFrame);
    }
    RingCopy(validStart, count, outBuffer + (size_t)lead * kOrraChannelCount, false);
    if (tail > 0) {
        memset(outBuffer + (size_t)(lead + count) * kOrraChannelCount, 0, (size_t)tail * kOrraBytesPerFrame);
    }
}

static OSStatus Orra_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (inIOCycleInfo == NULL || ioMainBuffer == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_OutputStream) {
        WriteMix((SInt64)inIOCycleInfo->mOutputTime.mSampleTime, inIOBufferFrameSize, (const Float32*)ioMainBuffer);
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_InputStream) {
        ReadInput((SInt64)inIOCycleInfo->mInputTime.mSampleTime, inIOBufferFrameSize, (Float32*)ioMainBuffer);
    }
    return kAudioHardwareNoError;
}

static OSStatus Orra_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}
