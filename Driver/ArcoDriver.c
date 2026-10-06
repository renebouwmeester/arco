// Arco — the virtual output. An AudioServerPlugIn with one stereo output and one stereo input: what an app plays to the
// output comes back, sample for sample, from the input, on the same clock. Arco's menu bar app reads that input and sends
// it to Roon. Nothing else happens here: no volume, no processing, no network.
//
// Written from AudioServerPlugIn.h (not derived from BlackHole). One file, as small as it can be: every change here
// costs an install with an administrator password and a restart of coreaudiod.
//
// Objects: 1 = the plug-in, 2 = the device, 3 = the output stream, 4 = the input stream. No controls (the Music app has
// its own volume). The device may be the default output (for Music), never the system sound output, never the default
// input.
//
// The loopback: a ring buffer indexed by sample time. The output writes its mix at its sample time; the input reads at its
// own. What was never written (or is too old) reads as silence — no echo of a stale ring when the music stops.
//
// Copyright 2026 René Bouwmeester. Licensed under the Apache License, Version 2.0.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>

enum { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStream = 3, kObjStreamIn = 4 };
#define kDeviceUID   "nl.renebouwmeester.arco.device"
#define kModelUID    "nl.renebouwmeester.arco.model"
#define kPeriod      16384u

static const Float64 kRates[] = { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000 };
#define kRateCount (sizeof(kRates) / sizeof(kRates[0]))

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32  gRefCount = 0;
static Float64 gRate = 44100;
static UInt32  gIOCount = 0;
static bool    gOutputActive = true, gInputActive = true;
// The loopback ring (stereo, interleaved) and how far it has been written, in sample time. Only the IO thread touches it
// (WriteMix and ReadInput run one after the other in the same cycle); a rate change clears it, under the lock, with IO
// stopped.
#define kRing 65536u
static Float32 gRing[kRing * 2];
static Float64 gWriteEnd = 0;
// The clock: timestamps from an anchor, at the host clock's pace.
static Float64 gTicksPerSecond = 0;
static Float64 gTicksPerFrame = 0;
static UInt64  gAnchorHost = 0;
static UInt64  gTick = 0;

static bool rateIsValid(Float64 r) { for (UInt32 i = 0; i < kRateCount; i++) if (kRates[i] == r) return true; return false; }
static void recompute(void) { gTicksPerFrame = gTicksPerSecond / gRate; }
static void anchor(void) { gAnchorHost = mach_absolute_time(); gTick = 0; recompute(); memset(gRing, 0, sizeof(gRing)); gWriteEnd = 0; }

static void format(AudioStreamBasicDescription *f, Float64 r) {
    memset(f, 0, sizeof(*f));
    f->mSampleRate = r; f->mFormatID = kAudioFormatLinearPCM; f->mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    f->mBytesPerPacket = 8; f->mFramesPerPacket = 1; f->mBytesPerFrame = 8; f->mChannelsPerFrame = 2; f->mBitsPerChannel = 32;
}

// MARK: - COM

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *out);
static ULONG AddRef(void *driver);
static ULONG Release(void *driver);
static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef d, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return noErr; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return noErr; }
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt64 action, void *info);
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt64 action, void *info) { return noErr; }
static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 space, UInt32 *size, void *out);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 size, const void *in);
static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client);
static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client, Float64 *sample, UInt64 *host, UInt64 *seed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client, UInt32 op, Boolean *will, Boolean *inPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *c) { return noErr; }
static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID o, AudioObjectID s, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *c, void *main, void *secondary);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *c) { return noErr; }

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformConfigChange, AbortConfigChange, HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData,
    SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePtr;

// The factory (Info.plist: CFPlugInFactories).
void *Arco_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *out) {
    if (driver != gDriver || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef asked = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(asked, IUnknownUUID) || CFEqual(asked, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gLock); gRefCount++; pthread_mutex_unlock(&gLock);
        *out = gDriver; result = S_OK;
    }
    CFRelease(asked);
    return result;
}
static ULONG AddRef(void *driver) { pthread_mutex_lock(&gLock); ULONG r = ++gRefCount; pthread_mutex_unlock(&gLock); return r; }
static ULONG Release(void *driver) { pthread_mutex_lock(&gLock); if (gRefCount > 0) gRefCount--; ULONG r = gRefCount; pthread_mutex_unlock(&gLock); return r; }

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gHost = host;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    gTicksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    pthread_mutex_lock(&gLock); recompute(); pthread_mutex_unlock(&gLock);
    return noErr;
}

// MARK: - Properties
// One function for size and content: without `out` only the size (GetPropertyDataSize, HasProperty).

#define SCALAR(type, value) do { *size = sizeof(type); if (out) { if (space < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)out = (value); } return noErr; } while (0)
#define LIST(type, source, count) do { UInt32 n_ = (UInt32)(count); if (out) { UInt32 k_ = space / sizeof(type); if (k_ < n_) n_ = k_; memcpy(out, (source), n_ * sizeof(type)); } *size = n_ * sizeof(type); return noErr; } while (0)

static OSStatus property(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 space, UInt32 *size, void *out) {
    const AudioObjectID device = kObjDevice, stream = kObjStream, streamIn = kObjStreamIn;
    const AudioObjectID both[2] = { kObjStream, kObjStreamIn };
    switch (o) {
    case kObjPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: SCALAR(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: SCALAR(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: SCALAR(CFStringRef, CFSTR("Arco"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: LIST(AudioObjectID, &device, 1);
        case kAudioPlugInPropertyBoxList: LIST(AudioObjectID, &device, 0);
        case kAudioPlugInPropertyTranslateUIDToBox: SCALAR(AudioObjectID, kAudioObjectUnknown);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (out && qs == sizeof(CFStringRef) && q && CFStringCompare(*(const CFStringRef *)q, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) found = kObjDevice;
            SCALAR(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: SCALAR(CFStringRef, CFSTR(""));
        }
        break;

    case kObjDevice: {
        const bool input = a->mScope == kAudioObjectPropertyScopeInput, output = a->mScope == kAudioObjectPropertyScopeOutput;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: SCALAR(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: SCALAR(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName: SCALAR(CFStringRef, CFSTR("Arco"));
        case kAudioObjectPropertyManufacturer: SCALAR(CFStringRef, CFSTR("Arco"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (input) LIST(AudioObjectID, &streamIn, 1);
            if (output) LIST(AudioObjectID, &stream, 1);
            LIST(AudioObjectID, both, 2);
        case kAudioObjectPropertyControlList: LIST(AudioObjectID, &stream, 0);
        case kAudioDevicePropertyDeviceUID: SCALAR(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID: SCALAR(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: LIST(AudioObjectID, &device, 1);
        case kAudioDevicePropertyClockDomain: SCALAR(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: SCALAR(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: { pthread_mutex_lock(&gLock); UInt32 r = gIOCount > 0; pthread_mutex_unlock(&gLock); SCALAR(UInt32, r); }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: SCALAR(UInt32, input ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: SCALAR(UInt32, 0);
        case kAudioDevicePropertyLatency: SCALAR(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: SCALAR(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: { pthread_mutex_lock(&gLock); Float64 r = gRate; pthread_mutex_unlock(&gLock); SCALAR(Float64, r); }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange list[kRateCount];
            for (UInt32 i = 0; i < kRateCount; i++) { list[i].mMinimum = kRates[i]; list[i].mMaximum = kRates[i]; }
            LIST(AudioValueRange, list, kRateCount);
        }
        case kAudioDevicePropertyIsHidden: SCALAR(UInt32, 0);
        case kAudioDevicePropertyPreferredChannelsForStereo: { UInt32 channels[2] = { 1, 2 }; LIST(UInt32, channels, 2); }
        case kAudioDevicePropertyZeroTimeStampPeriod: SCALAR(UInt32, kPeriod);
        case kAudioDevicePropertyClockIsStable: SCALAR(UInt32, 1);
        }
        break;
    }

    case kObjStream:
    case kObjStreamIn: {
        const bool in = o == kObjStreamIn;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: SCALAR(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: SCALAR(AudioObjectID, kObjDevice);
        case kAudioObjectPropertyOwnedObjects: LIST(AudioObjectID, &stream, 0);
        case kAudioStreamPropertyIsActive: { pthread_mutex_lock(&gLock); UInt32 r = in ? gInputActive : gOutputActive; pthread_mutex_unlock(&gLock); SCALAR(UInt32, r); }
        case kAudioStreamPropertyDirection: SCALAR(UInt32, in ? 1 : 0);   // 0 = output, 1 = input
        case kAudioStreamPropertyTerminalType: SCALAR(UInt32, kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: SCALAR(UInt32, 1);
        case kAudioStreamPropertyLatency: SCALAR(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f; pthread_mutex_lock(&gLock); format(&f, gRate); pthread_mutex_unlock(&gLock);
            SCALAR(AudioStreamBasicDescription, f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription list[kRateCount];
            for (UInt32 i = 0; i < kRateCount; i++) {
                format(&list[i].mFormat, kRates[i]);
                list[i].mSampleRateRange.mMinimum = kRates[i]; list[i].mSampleRateRange.mMaximum = kRates[i];
            }
            LIST(AudioStreamRangedDescription, list, kRateCount);
        }
        }
        break;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    UInt32 size = 0;
    return a && property(o, a, 0, NULL, 0, &size, NULL) == noErr;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (!a || !out) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(driver, o, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioDevicePropertyNominalSampleRate: *out = o == kObjDevice; break;
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: *out = o == kObjStream || o == kObjStreamIn; break;
    default: *out = false;
    }
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size) {
    if (!a || !size) return kAudioHardwareIllegalOperationError;
    return property(o, a, qs, q, 0, size, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 space, UInt32 *size, void *out) {
    if (!a || !size || !out) return kAudioHardwareIllegalOperationError;
    return property(o, a, qs, q, space, size, out);
}

// A rate change always goes through the host (RequestDeviceConfigurationChange → PerformConfigChange), never directly.
static OSStatus requestRate(Float64 r) {
    if (!rateIsValid(r)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gLock); Float64 now = gRate; pthread_mutex_unlock(&gLock);
    if (r == now) return noErr;
    return gHost ? gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, (UInt64)r, NULL) : kAudioHardwareNotRunningError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 size, const void *in) {
    if (!a || !in) return kAudioHardwareIllegalOperationError;
    if (o == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return requestRate(*(const Float64 *)in);
    }
    if ((o == kObjStream || o == kObjStreamIn) && a->mSelector == kAudioStreamPropertyIsActive) {
        if (size < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gLock);
        if (o == kObjStreamIn) gInputActive = *(const UInt32 *)in != 0; else gOutputActive = *(const UInt32 *)in != 0;
        pthread_mutex_unlock(&gLock);
        return noErr;
    }
    if ((o == kObjStream || o == kObjStreamIn) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = in;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != 2 || f->mBitsPerChannel != 32) return kAudioDeviceUnsupportedFormatError;
        return requestRate(f->mSampleRate);
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus PerformConfigChange(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt64 action, void *info) {
    Float64 r = (Float64)action;
    if (!rateIsValid(r)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gLock); gRate = r; anchor(); pthread_mutex_unlock(&gLock);
    return noErr;
}

// MARK: - IO: the clock

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client) {
    pthread_mutex_lock(&gLock);
    if (gIOCount == 0) anchor();
    gIOCount++;
    pthread_mutex_unlock(&gLock);
    return noErr;
}
static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client) {
    pthread_mutex_lock(&gLock); if (gIOCount > 0) gIOCount--; pthread_mutex_unlock(&gLock);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client, Float64 *sample, UInt64 *host, UInt64 *seed) {
    pthread_mutex_lock(&gLock);
    Float64 ticksPerPeriod = gTicksPerFrame * kPeriod;
    UInt64 now = mach_absolute_time();
    if ((Float64)now >= (Float64)gAnchorHost + (Float64)(gTick + 1) * ticksPerPeriod) gTick++;
    *sample = (Float64)gTick * kPeriod;
    *host = gAnchorHost + (UInt64)((Float64)gTick * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&gLock);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID o, UInt32 client, UInt32 op, Boolean *will, Boolean *inPlace) {
    // Take the mix (into the ring) and deliver the input (from the ring); nothing else.
    *will = op == kAudioServerPlugInIOOperationWriteMix || op == kAudioServerPlugInIOOperationReadInput;
    *inPlace = true;
    return noErr;
}

// The loopback. Write: this cycle's mix at its output sample time into the ring. Read: at the input sample time; only
// frames in [writeEnd − ring, writeEnd) are real, the rest is silence.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID o, AudioObjectID s, UInt32 client, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *c, void *main, void *secondary) {
    if (!main || n == 0) return noErr;
    Float32 *buffer = main;
    if (op == kAudioServerPlugInIOOperationWriteMix && s == kObjStream) {
        Float64 t0 = c->mOutputTime.mSampleTime;
        UInt64 position = (UInt64)t0 % kRing;
        UInt32 first = n < kRing - position ? n : (UInt32)(kRing - position);
        memcpy(&gRing[position * 2], buffer, first * 2 * sizeof(Float32));
        if (first < n) memcpy(&gRing[0], buffer + first * 2, (n - first) * 2 * sizeof(Float32));
        if (t0 + n > gWriteEnd) gWriteEnd = t0 + n;
    } else if (op == kAudioServerPlugInIOOperationReadInput && s == kObjStreamIn) {
        Float64 t0 = c->mInputTime.mSampleTime;
        for (UInt32 i = 0; i < n; ) {
            Float64 t = t0 + i;
            UInt64 position = (UInt64)t % kRing;
            UInt32 piece = n - i; if (piece > kRing - position) piece = (UInt32)(kRing - position);
            if (t >= gWriteEnd || t < gWriteEnd - kRing) {
                // Never written or already overwritten: silence (up to where the valid part starts).
                UInt32 silent = piece;
                if (t < gWriteEnd - kRing && gWriteEnd - kRing - t < silent) silent = (UInt32)(gWriteEnd - kRing - t);
                memset(buffer + i * 2, 0, silent * 2 * sizeof(Float32)); i += silent; continue;
            }
            if (t + piece > gWriteEnd) piece = (UInt32)(gWriteEnd - t);
            memcpy(buffer + i * 2, &gRing[position * 2], piece * 2 * sizeof(Float32)); i += piece;
        }
    }
    return noErr;
}
