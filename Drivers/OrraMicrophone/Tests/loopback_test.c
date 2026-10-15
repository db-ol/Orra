// Loads OrraMicrophone.driver in this process the way coreaudiod finds it, through
// CFPlugIn and the factory that Info.plist names, and drives it with a stub host. It checks
// the properties the HAL reads and that audio written to the output side comes back on the
// input side. Nothing is installed and coreaudiod is never involved.
//
// Usage: loopback_test path/to/OrraMicrophone.driver
//
// Copyright (c) 2026 Orra contributors. MIT License, see LICENSE in the repository root.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { kPlugIn = 1, kDevice = 2, kInput = 3, kOutput = 4 };
enum { kChannels = 2, kRing = 16384, kCycle = 512 };

static int gFailures = 0;

#define CHECK(condition, ...) \
    do { if (!(condition)) { gFailures++; fprintf(stderr, "FAIL line %d: ", __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static OSStatus StubPropertiesChanged(AudioServerPlugInHostRef inHost, AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses)
{
    (void)inHost; (void)inObjectID; (void)inNumberAddresses; (void)inAddresses;
    return 0;
}

static OSStatus StubCopyFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef* outData)
{
    (void)inHost; (void)inKey;
    *outData = NULL;
    return 0;
}

static OSStatus StubWriteToStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef inData)
{
    (void)inHost; (void)inKey; (void)inData;
    return 0;
}

static OSStatus StubDeleteFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey)
{
    (void)inHost; (void)inKey;
    return 0;
}

static OSStatus StubRequestConfigurationChange(AudioServerPlugInHostRef inHost, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inHost; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return 0;
}

static AudioServerPlugInHostInterface gHost = {
    StubPropertiesChanged, StubCopyFromStorage, StubWriteToStorage, StubDeleteFromStorage, StubRequestConfigurationChange
};

static AudioServerPlugInDriverRef gDriver;

static OSStatus Get(AudioObjectID inObject, AudioObjectPropertySelector inSelector, AudioObjectPropertyScope inScope, UInt32 inQualifierSize, const void* inQualifier, UInt32 inSize, UInt32* outSize, void* outData)
{
    AudioObjectPropertyAddress address = { inSelector, inScope, kAudioObjectPropertyElementMain };
    return (*gDriver)->GetPropertyData(gDriver, inObject, 0, &address, inQualifierSize, inQualifier, inSize, outSize, outData);
}

static UInt32 GetUInt32(AudioObjectID inObject, AudioObjectPropertySelector inSelector, AudioObjectPropertyScope inScope)
{
    UInt32 value = 0xFFFFFFFF, size = 0;
    OSStatus status = Get(inObject, inSelector, inScope, 0, NULL, sizeof(value), &size, &value);
    CHECK(status == 0 && size == sizeof(value), "UInt32 property '%.4s' of object %u: status %d", (const char*)&inSelector, inObject, (int)status);
    return value;
}

static bool StringEquals(AudioObjectID inObject, AudioObjectPropertySelector inSelector, const char* inExpected)
{
    CFStringRef value = NULL;
    UInt32 size = 0;
    OSStatus status = Get(inObject, inSelector, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(value), &size, &value);
    if (status != 0 || value == NULL) {
        return false;
    }
    char buffer[256];
    bool ok = CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8) && strcmp(buffer, inExpected) == 0;
    CFRelease(value);
    return ok;
}

static UInt32 StreamCount(AudioObjectPropertyScope inScope, AudioObjectID outIDs[2])
{
    UInt32 size = 0;
    OSStatus status = Get(kDevice, kAudioDevicePropertyStreams, inScope, 0, NULL, 2 * sizeof(AudioObjectID), &size, outIDs);
    CHECK(status == 0, "streams status %d", (int)status);
    return size / sizeof(AudioObjectID);
}

static void CheckProperties(void)
{
    CHECK(GetUInt32(kPlugIn, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioPlugInClassID, "plug in class");
    CHECK(GetUInt32(kDevice, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioDeviceClassID, "device class");
    CHECK(GetUInt32(kInput, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioStreamClassID, "stream class");
    CHECK(StringEquals(kDevice, kAudioObjectPropertyName, "Orra Microphone"), "device name");
    CHECK(StringEquals(kDevice, kAudioDevicePropertyDeviceUID, "io.github.db-ol.Orra.Microphone"), "device UID");

    AudioObjectID devices[4] = { 0 };
    UInt32 size = 0;
    CHECK(Get(kPlugIn, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(devices), &size, devices) == 0, "device list");
    CHECK(size == sizeof(AudioObjectID) && devices[0] == kDevice, "device list holds the one device");

    CFStringRef uid = CFSTR("io.github.db-ol.Orra.Microphone");
    AudioObjectID translated = 0;
    CHECK(Get(kPlugIn, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, sizeof(uid), &uid, sizeof(translated), &size, &translated) == 0 && translated == kDevice, "UID translates to the device");
    CFStringRef other = CFSTR("some.other.device");
    CHECK(Get(kPlugIn, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, sizeof(other), &other, sizeof(translated), &size, &translated) == 0 && translated == kAudioObjectUnknown, "unknown UID translates to nothing");

    AudioObjectID streams[2] = { 0 };
    CHECK(StreamCount(kAudioObjectPropertyScopeInput, streams) == 1 && streams[0] == kInput, "one input stream");
    CHECK(StreamCount(kAudioObjectPropertyScopeOutput, streams) == 1 && streams[0] == kOutput, "one output stream");
    CHECK(StreamCount(kAudioObjectPropertyScopeGlobal, streams) == 2, "two streams in the global scope");
    CHECK(GetUInt32(kInput, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1, "input direction");
    CHECK(GetUInt32(kOutput, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0, "output direction");
    CHECK(GetUInt32(kDevice, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1, "input can be the default");
    CHECK(GetUInt32(kDevice, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "output is never the default");
    CHECK(GetUInt32(kDevice, kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal) == kRing, "zero time stamp period");

    AudioStreamBasicDescription format;
    CHECK(Get(kInput, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(format), &size, &format) == 0, "virtual format");
    CHECK(format.mSampleRate == 48000.0 && format.mChannelsPerFrame == kChannels && format.mBitsPerChannel == 32
          && (format.mFormatFlags & kAudioFormatFlagIsFloat), "48 kHz float stereo");

    Float64 rate = 0;
    CHECK(Get(kDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(rate), &size, &rate) == 0 && rate == 48000.0, "nominal rate");

    // A buffer that is too small is an error, not an overflow.
    UInt16 tooSmall = 0;
    CHECK(Get(kDevice, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(tooSmall), &size, &tooSmall) == kAudioHardwareBadPropertySizeError, "short buffer rejected");

    AudioObjectPropertyAddress unknown = { 'zzzz', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CHECK(!(*gDriver)->HasProperty(gDriver, kDevice, 0, &unknown), "unknown property");
    CHECK(!(*gDriver)->HasProperty(gDriver, 99, 0, &unknown), "unknown object");
}

static float Sample(SInt64 inFrame, int inChannel)
{
    // Distinct, non zero values per frame and channel.
    return (float)((inFrame % 100000) + 1) * (inChannel == 0 ? 1.0f : -1.0f);
}

static void Write(SInt64 inStart, UInt32 inFrames)
{
    static float buffer[4096 * kChannels];
    for (UInt32 f = 0; f < inFrames; f++) {
        for (int c = 0; c < kChannels; c++) {
            buffer[f * kChannels + c] = Sample(inStart + f, c);
        }
    }
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    cycle.mOutputTime.mSampleTime = (Float64)inStart;
    OSStatus status = (*gDriver)->DoIOOperation(gDriver, kDevice, kOutput, 1, kAudioServerPlugInIOOperationWriteMix, inFrames, &cycle, buffer, NULL);
    CHECK(status == 0, "write status %d", (int)status);
}

// Reads frames and returns how many differ from what is expected. Frames in
// [inWrittenStart, inWrittenEnd) hold the written signal, all others silence.
static int ReadAndCompare(SInt64 inStart, UInt32 inFrames, SInt64 inWrittenStart, SInt64 inWrittenEnd)
{
    static float buffer[4096 * kChannels];
    for (UInt32 i = 0; i < inFrames * kChannels; i++) {
        buffer[i] = 12345.0f;
    }
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    cycle.mInputTime.mSampleTime = (Float64)inStart;
    OSStatus status = (*gDriver)->DoIOOperation(gDriver, kDevice, kInput, 1, kAudioServerPlugInIOOperationReadInput, inFrames, &cycle, buffer, NULL);
    CHECK(status == 0, "read status %d", (int)status);
    int wrong = 0;
    for (UInt32 f = 0; f < inFrames; f++) {
        SInt64 frame = inStart + f;
        bool written = frame >= inWrittenStart && frame < inWrittenEnd;
        for (int c = 0; c < kChannels; c++) {
            float expected = written ? Sample(frame, c) : 0.0f;
            if (buffer[f * kChannels + c] != expected) {
                wrong++;
            }
        }
    }
    return wrong;
}

static void CheckLoopback(void)
{
    OSStatus status = (*gDriver)->StartIO(gDriver, kDevice, 1);
    CHECK(status == 0, "start IO");

    // Before anything is written the input is silent.
    CHECK(ReadAndCompare(0, kCycle, 0, 0) == 0, "silence before the first write");

    // Simulated IO cycles as the HAL runs them: output a cycle ahead of now, input a
    // cycle behind. Three trips around the ring cover the wrap.
    SInt64 written = -1;
    int wrong = 0;
    for (SInt64 now = kCycle; now < 3 * kRing; now += kCycle) {
        SInt64 outputTime = now + kCycle;
        SInt64 inputTime = now - kCycle;
        if (written < 0) {
            written = outputTime;
        }
        Write(outputTime, kCycle);
        wrong += ReadAndCompare(inputTime, kCycle, written, outputTime + kCycle);
    }
    CHECK(wrong == 0, "loopback across the ring: %d wrong samples", wrong);

    // An odd sized buffer that straddles the end of the ring.
    SInt64 straddle = 4 * kRing - 100;
    Write(straddle, 300);
    CHECK(ReadAndCompare(straddle, 300, straddle, straddle + 300) == 0, "copy across the wrap");

    // Playback stops. Frames past the last write read as silence, not as old audio.
    SInt64 lastEnd = straddle + 300;
    CHECK(ReadAndCompare(lastEnd, kCycle, 0, 0) == 0, "silence after playback stops");
    CHECK(ReadAndCompare(lastEnd + 2 * kRing, kCycle, 0, 0) == 0, "silence long after playback stops");

    // Playback resumes after a gap shorter than the ring. The gap reads as silence.
    SInt64 resume = lastEnd + 3000;
    Write(resume, kCycle);
    CHECK(ReadAndCompare(lastEnd, 3000, 0, 0) == 0, "the gap is silent");
    CHECK(ReadAndCompare(resume, kCycle, resume, resume + kCycle) == 0, "audio after the gap");

    // Audio older than one trip around the ring is gone.
    Write(resume + kCycle + kRing, kCycle);
    CHECK(ReadAndCompare(resume, kCycle, 0, 0) == 0, "audio older than the ring reads as silence");

    // Zero time stamps: sample times on the period, host times not in the future.
    Float64 sampleTime = -1;
    UInt64 hostTime = 0, seed = 0;
    status = (*gDriver)->GetZeroTimeStamp(gDriver, kDevice, 1, &sampleTime, &hostTime, &seed);
    CHECK(status == 0 && seed == 1, "zero time stamp");
    CHECK(sampleTime >= 0 && (UInt64)sampleTime % kRing == 0, "sample time on the period");
    CHECK(hostTime <= mach_absolute_time(), "host time not in the future");

    CHECK((*gDriver)->StopIO(gDriver, kDevice, 1) == 0, "stop IO");
    CHECK((*gDriver)->StopIO(gDriver, kDevice, 1) == kAudioHardwareIllegalOperationError, "stop without start");
}

int main(int argc, const char* argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s path/to/OrraMicrophone.driver\n", argv[0]);
        return 2;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], (CFIndex)strlen(argv[1]), true);
    CFPlugInRef plugIn = url != NULL ? CFPlugInCreate(NULL, url) : NULL;
    if (plugIn == NULL) {
        fprintf(stderr, "FAIL: cannot open %s as a CFPlugIn\n", argv[1]);
        return 1;
    }
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInType(kAudioServerPlugInTypeUUID);
    if (factories == NULL || CFArrayGetCount(factories) != 1) {
        fprintf(stderr, "FAIL: expected one Audio Server plug in factory\n");
        return 1;
    }
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    IUnknownVTbl** unknown = (IUnknownVTbl**)CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    if (unknown == NULL) {
        fprintf(stderr, "FAIL: the factory returned no driver\n");
        return 1;
    }
    void* driver = NULL;
    HRESULT result = (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &driver);
    if (result != S_OK || driver == NULL) {
        fprintf(stderr, "FAIL: no driver interface\n");
        return 1;
    }
    gDriver = (AudioServerPlugInDriverRef)driver;
    CHECK((*gDriver)->Initialize(gDriver, &gHost) == 0, "initialize");

    CheckProperties();
    CheckLoopback();

    (*gDriver)->Release(gDriver);
    CFRelease(factories);
    if (gFailures > 0) {
        fprintf(stderr, "%d checks failed\n", gFailures);
        return 1;
    }
    printf("loopback_test: all checks passed\n");
    return 0;
}
