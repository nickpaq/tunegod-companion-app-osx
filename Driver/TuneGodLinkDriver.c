// TuneGod Link driver: a Core Audio server plug-in that publishes one device, "TuneGod iPhone", with 2 output channels (played on the
// phone's speaker) and 2 input channels (the phone's mic). It talks to the TuneGod Companion helper over loopback TCP
// (docs/link-protocol.md, "Driver"):
//   - the helper sends the phone's clock (CLOCK, once per phone packet), CONFIG, START/STOP and the mic (AUDIO_UP, by phone frame);
//   - the driver sends what Mac apps play (AUDIO_DOWN, by phone frame).
// The device's clock follows the phone (GetZeroTimeStamp maps the device's sample time to host time through the helper's clock), so
// Mac apps run at exactly the phone's rate and nothing is resampled. With no phone it free-runs at 48 kHz and is silent.
//
// Real-time rules: the IO callbacks only read a seqlock-protected clock and copy to and from two rings with atomic positions. All socket
// work happens on the driver's own two threads.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// MARK: - Constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Input = 3,
    kObjectID_Stream_Output = 4,
};

#define kPlugInBundleID "app.tunegod.companion.driver"
#define kDeviceName "TuneGod iPhone"
#define kManufacturer "TuneGod"
#define kDeviceUID "TuneGodLink:iPhone"
#define kDeviceModelUID "TuneGodLink:Model"
#define kSampleRate 48000.0
#define kChannels 2
#define kBytesPerFrame (kChannels * sizeof(Float32))
#define kZeroTimeStampPeriod 4096
#define kRingFrames 16384u            // power of two
#define kRingMask (kRingFrames - 1u)
#define kHelperPort 47821
// How far ahead of the phone's "now" Mac apps write (frames): covers the helper's lead to the phone plus a margin.
#define kOutputSafetyOffset 256
// How far behind the phone's "now" Mac apps read the mic (frames): one phone packet and the hop through the helper.
#define kInputSafetyOffset 128
// Rough latencies past the safety offsets (frames): the phone's own audio IO each way. Refined once measured on the phone.
#define kOutputLatency 192
#define kInputLatency 128

// Link message types (LinkProtocol.swift).
enum {
    kMsgConfig = 0x02, kMsgStart = 0x03, kMsgStop = 0x04,
    kMsgAudioUp = 0x10, kMsgAudioDown = 0x11, kMsgClock = 0x50,
};

// MARK: - State

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static UInt64 gIOCount = 0;
static bool gStreamInputActive = true;
static bool gStreamOutputActive = true;
static double gTicksPerSecond = 0;

// The device clock: device sample S plays at host seconds aHost + (S - aSample) / rate; phone frame = S + offset.
// Written by the helper thread (and StartIO) under gClockWriteMutex, read lock-free by the IO thread through the sequence number.
typedef struct {
    double aSample;
    double aHost;
    double rate;
    int64_t offset;
} ClockMap;
static ClockMap gClock;
static _Atomic UInt32 gClockSeq = 0;
static pthread_mutex_t gClockWriteMutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool gPhoneLocked = false;
static _Atomic UInt32 gSeed = 1;

// Rings by phone frame (interleaved stereo). Positions are phone frames.
static Float32 gInRing[kRingFrames * kChannels];
static _Atomic UInt64 gInWrittenUpTo = 0;
static _Atomic UInt64 gInValidFrom = 0;
static Float32 gOutRing[kRingFrames * kChannels];
static _Atomic UInt64 gOutWrittenUpTo = 0;
static _Atomic bool gOutReset = true;

static _Atomic int gSocket = -1;
static semaphore_t gSendSemaphore;
static int gUpChannels = 2;

// MARK: - Clock helpers

static double HostSeconds(UInt64 ticks) { return (double)ticks / gTicksPerSecond; }
static double NowSeconds(void) { return HostSeconds(mach_absolute_time()); }

static ClockMap ReadClock(void) {
    ClockMap c;
    UInt32 s1, s2;
    do {
        s1 = atomic_load_explicit(&gClockSeq, memory_order_acquire);
        c = gClock;
        atomic_thread_fence(memory_order_acquire);
        s2 = atomic_load_explicit(&gClockSeq, memory_order_relaxed);
    } while ((s1 & 1u) || s1 != s2);
    return c;
}

// Callers hold gClockWriteMutex.
static void WriteClock(ClockMap c) {
    atomic_fetch_add_explicit(&gClockSeq, 1, memory_order_acq_rel);
    gClock = c;
    atomic_fetch_add_explicit(&gClockSeq, 1, memory_order_release);
}

static double SampleAtHost(ClockMap c, double host) { return c.aSample + (host - c.aHost) * c.rate; }

// MARK: - Helper link threads

static bool WriteAll(int fd, const void* buf, size_t n) {
    const UInt8* p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += w;
        n -= (size_t)w;
    }
    return true;
}

static bool ReadAll(int fd, void* buf, size_t n) {
    UInt8* p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        p += r;
        n -= (size_t)r;
    }
    return true;
}

static UInt16 LE16(const UInt8* p) { return (UInt16)(p[0] | p[1] << 8); }
static UInt32 LE32(const UInt8* p) { return (UInt32)p[0] | (UInt32)p[1] << 8 | (UInt32)p[2] << 16 | (UInt32)p[3] << 24; }
static UInt64 LE64(const UInt8* p) { return (UInt64)LE32(p) | (UInt64)LE32(p + 4) << 32; }
static void PutLE16(UInt8* p, UInt16 v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static void PutLE32(UInt8* p, UInt32 v) { for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xFF; }
static void PutLE64(UInt8* p, UInt64 v) { for (int i = 0; i < 8; i++) p[i] = (v >> (8 * i)) & 0xFF; }

static void HandleClock(UInt64 phoneSample, UInt64 hostTicks, double rate) {
    if (!(rate > 40000 && rate < 56000)) return;
    double host = HostSeconds(hostTicks);
    pthread_mutex_lock(&gClockWriteMutex);
    ClockMap c = gClock;
    if (!atomic_load(&gPhoneLocked)) {
        // Lock on: keep the device's timeline continuous, so the phone frame now maps onto the device frame now.
        double s = SampleAtHost(c, host);
        c.offset = (int64_t)phoneSample - (int64_t)llround(s);
        atomic_store(&gPhoneLocked, true);
    }
    c.aSample = (double)((int64_t)phoneSample - c.offset);
    c.aHost = host;
    c.rate = rate;
    WriteClock(c);
    pthread_mutex_unlock(&gClockWriteMutex);
}

static void HandleAudioUp(UInt64 t, UInt16 frames, const UInt8* samples, size_t bytes) {
    if (frames == 0) return;
    size_t channels = bytes / (frames * 4u);
    if (channels == 0) return;
    UInt64 written = atomic_load_explicit(&gInWrittenUpTo, memory_order_relaxed);
    if (t < written || t > written + kRingFrames) {
        atomic_store_explicit(&gInValidFrom, t, memory_order_relaxed);
    } else {
        for (UInt64 g = written; g < t; g++) {  // a short gap is silence
            gInRing[(g & kRingMask) * kChannels] = 0;
            gInRing[(g & kRingMask) * kChannels + 1] = 0;
        }
    }
    for (UInt16 f = 0; f < frames; f++) {
        UInt32 i = (UInt32)((t + f) & kRingMask) * kChannels;
        for (int ch = 0; ch < kChannels; ch++) {
            size_t src = (size_t)ch < channels ? (size_t)ch : channels - 1;
            UInt32 bits = LE32(samples + (f * channels + src) * 4);
            Float32 v;
            memcpy(&v, &bits, 4);
            gInRing[i + ch] = v;
        }
    }
    UInt64 end = t + frames;
    UInt64 from = atomic_load_explicit(&gInValidFrom, memory_order_relaxed);
    if (end - from > kRingFrames) atomic_store_explicit(&gInValidFrom, end - kRingFrames, memory_order_relaxed);
    atomic_store_explicit(&gInWrittenUpTo, end, memory_order_release);
}

static void PhoneGone(void) {
    pthread_mutex_lock(&gClockWriteMutex);
    atomic_store(&gPhoneLocked, false);  // the clock free-runs on from its last mapping
    pthread_mutex_unlock(&gClockWriteMutex);
    atomic_store(&gInWrittenUpTo, 0);
    atomic_store(&gInValidFrom, 0);
}

static void* ReceiveThread(void* arg) {
    (void)arg;
    UInt8* payload = malloc(1 << 20);
    for (;;) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in addr = {0};
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kHelperPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (fd < 0 || connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
            if (fd >= 0) close(fd);
            usleep(500000);
            continue;
        }
        int on = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        atomic_store(&gOutReset, true);
        atomic_store(&gSocket, fd);
        UInt8 header[8];
        while (ReadAll(fd, header, 8)) {
            UInt32 length = LE32(header + 4);
            if (length > (1 << 20) || !ReadAll(fd, payload, length)) break;
            switch (header[0]) {
            case kMsgClock:
                if (length >= 24) {
                    UInt64 bits = LE64(payload + 16);
                    double rate;
                    memcpy(&rate, &bits, 8);
                    HandleClock(LE64(payload), LE64(payload + 8), rate);
                }
                break;
            case kMsgAudioUp:
                if (length >= 12) HandleAudioUp(LE64(payload), LE16(payload + 8), payload + 12, length - 12);
                break;
            case kMsgConfig:
                if (length >= 8) gUpChannels = payload[7];
                break;
            case kMsgStart:
            case kMsgStop:
                PhoneGone();  // a new timeline (or none): lock on again from the next CLOCK
                break;
            default:
                break;
            }
        }
        atomic_store(&gSocket, -1);
        close(fd);
        PhoneGone();
        usleep(200000);
    }
    return NULL;
}

// Sends what Mac apps wrote into the output ring, in blocks of up to 256 frames, as soon as the IO thread signals.
static void* SendThread(void* arg) {
    (void)arg;
    static UInt8 message[8 + 12 + 256 * kBytesPerFrame];
    UInt64 sent = 0;
    for (;;) {
        mach_timespec_t timeout = {0, 20 * 1000 * 1000};
        semaphore_timedwait(gSendSemaphore, timeout);
        int fd = atomic_load(&gSocket);
        UInt64 written = atomic_load_explicit(&gOutWrittenUpTo, memory_order_acquire);
        if (atomic_exchange(&gOutReset, false) || written < sent || written - sent > kRingFrames / 2) sent = written;
        if (fd < 0) {
            sent = written;
            continue;
        }
        while (sent < written) {
            UInt32 n = (UInt32)(written - sent);
            if (n > 256) n = 256;
            UInt32 payloadBytes = 12 + n * (UInt32)kBytesPerFrame;
            message[0] = kMsgAudioDown;
            message[1] = 0;
            PutLE16(message + 2, 0);
            PutLE32(message + 4, payloadBytes);
            PutLE64(message + 8, sent);
            PutLE16(message + 16, (UInt16)n);
            PutLE16(message + 18, 0);
            for (UInt32 f = 0; f < n; f++) {
                UInt32 i = (UInt32)((sent + f) & kRingMask) * kChannels;
                for (int ch = 0; ch < kChannels; ch++) {
                    UInt32 bits;
                    memcpy(&bits, &gOutRing[i + ch], 4);
                    PutLE32(message + 20 + (f * kChannels + ch) * 4, bits);
                }
            }
            if (!WriteAll(fd, message, 8 + payloadBytes)) break;
            sent += n;
        }
    }
    return NULL;
}

// MARK: - Plug-in interface declarations

static HRESULT TG_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG TG_AddRef(void* inDriver);
static ULONG TG_Release(void* inDriver);
static OSStatus TG_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus TG_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus TG_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus TG_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus TG_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus TG_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus TG_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean TG_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus TG_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus TG_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32,
                                       const void*, UInt32*);
static OSStatus TG_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32,
                                   const void*, UInt32, UInt32*, void*);
static OSStatus TG_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32,
                                   const void*, UInt32, const void*);
static OSStatus TG_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus TG_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus TG_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus TG_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus TG_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus TG_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32,
                                 const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus TG_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    TG_QueryInterface, TG_AddRef, TG_Release,
    TG_Initialize, TG_CreateDevice, TG_DestroyDevice,
    TG_AddDeviceClient, TG_RemoveDeviceClient,
    TG_PerformDeviceConfigurationChange, TG_AbortDeviceConfigurationChange,
    TG_HasProperty, TG_IsPropertySettable, TG_GetPropertyDataSize, TG_GetPropertyData, TG_SetPropertyData,
    TG_StartIO, TG_StopIO, TG_GetZeroTimeStamp,
    TG_WillDoIOOperation, TG_BeginIOOperation, TG_DoIOOperation, TG_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory and COM basics

__attribute__((visibility("default"))) void* TuneGodLink_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT TG_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG TG_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) gRefCount++;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG TG_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

// MARK: - Basic operations

static OSStatus TG_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksPerSecond = 1e9 * (double)tb.denom / (double)tb.numer;
    pthread_mutex_lock(&gClockWriteMutex);
    WriteClock((ClockMap){.aSample = 0, .aHost = NowSeconds(), .rate = kSampleRate, .offset = 0});
    pthread_mutex_unlock(&gClockWriteMutex);
    semaphore_create(mach_task_self(), &gSendSemaphore, SYNC_POLICY_FIFO, 0);
    pthread_t receiver, sender;
    pthread_create(&receiver, NULL, ReceiveThread, NULL);
    pthread_create(&sender, NULL, SendThread, NULL);
    pthread_detach(receiver);
    pthread_detach(sender);
    return kAudioHardwareNoError;
}

static OSStatus TG_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus TG_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus TG_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci) {
    (void)ci;
    return (d == gDriverRef && id == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus TG_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci) {
    (void)ci;
    return (d == gDriverRef && id == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus TG_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)a; (void)i;
    return (d == gDriverRef && id == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus TG_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)a; (void)i;
    return (d == gDriverRef && id == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// MARK: - Properties

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
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

static bool IsStream(AudioObjectID id) { return id == kObjectID_Stream_Input || id == kObjectID_Stream_Output; }

static Boolean TG_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (d != gDriverRef || a == NULL) return false;
    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyPreferredChannelsForStereo:
            return true;
        }
        return false;
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus TG_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                      Boolean* out) {
    if (d != gDriverRef || a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!TG_HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = IsStream(id) && (a->mSelector == kAudioStreamPropertyIsActive || a->mSelector == kAudioStreamPropertyVirtualFormat ||
                            a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return kAudioHardwareNoError;
}

static UInt32 DeviceStreamCount(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal ? 2 : 1;
}

static OSStatus TG_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                       UInt32 qs, const void* q, UInt32* out) {
    (void)qs; (void)q;
    if (d != gDriverRef || a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!TG_HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner: *out = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle:
        *out = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyOwnedObjects:
        if (id == kObjectID_PlugIn) *out = sizeof(AudioObjectID);
        else if (id == kObjectID_Device) *out = DeviceStreamCount(a->mScope) * sizeof(AudioObjectID);
        else *out = 0;
        return 0;
    case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioDevicePropertyRelatedDevices:
        *out = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyStreams: *out = DeviceStreamCount(a->mScope) * sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyControlList: *out = 0; return 0;
    case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates: *out = sizeof(AudioValueRange); return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        *out = sizeof(AudioStreamBasicDescription); return 0;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *out = sizeof(AudioStreamRangedDescription); return 0;
    default: *out = sizeof(UInt32); return 0;
    }
}

#define REQUIRE_SIZE(n) do { if (inDataSize < (n)) return kAudioHardwareBadPropertySizeError; *outDataSize = (n); } while (0)

static OSStatus TG_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qs, const void* q, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (d != gDriverRef || a == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!TG_HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: REQUIRE_SIZE(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioObjectClassID; return 0;
        case kAudioObjectPropertyClass: REQUIRE_SIZE(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioPlugInClassID; return 0;
        case kAudioObjectPropertyOwner: REQUIRE_SIZE(sizeof(AudioObjectID)); *(AudioObjectID*)outData = kAudioObjectUnknown; return 0;
        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kManufacturer); return 0;
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            *outDataSize = sizeof(AudioObjectID); *(AudioObjectID*)outData = kObjectID_Device; return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            REQUIRE_SIZE(sizeof(AudioObjectID));
            *(AudioObjectID*)outData = (qs == sizeof(CFStringRef) && q != NULL &&
                                        CFStringCompare(*(const CFStringRef*)q, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo)
                ? kObjectID_Device : kAudioObjectUnknown;
            return 0;
        case kAudioPlugInPropertyResourceBundle:
            REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(""); return 0;
        }
        break;

    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: REQUIRE_SIZE(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioObjectClassID; return 0;
        case kAudioObjectPropertyClass: REQUIRE_SIZE(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioDeviceClassID; return 0;
        case kAudioObjectPropertyOwner: REQUIRE_SIZE(sizeof(AudioObjectID)); *(AudioObjectID*)outData = kObjectID_PlugIn; return 0;
        case kAudioObjectPropertyName: REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kDeviceName); return 0;
        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kManufacturer); return 0;
        case kAudioDevicePropertyDeviceUID: REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kDeviceUID); return 0;
        case kAudioDevicePropertyModelUID:
            REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(kDeviceModelUID); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2];
            UInt32 n = 0;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput) ids[n++] = kObjectID_Stream_Input;
            if (a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput) ids[n++] = kObjectID_Stream_Output;
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (n > fit) n = fit;
            memcpy(outData, ids, n * sizeof(AudioObjectID));
            *outDataSize = n * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioDevicePropertyTransportType:
            REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; return 0;
        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            *outDataSize = sizeof(AudioObjectID); *(AudioObjectID*)outData = kObjectID_Device; return 0;
        case kAudioDevicePropertyClockDomain: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 0; return 0;
        case kAudioDevicePropertyDeviceIsAlive: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 1; return 0;
        case kAudioDevicePropertyDeviceIsRunning:
            REQUIRE_SIZE(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *(UInt32*)outData = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 1; return 0;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 0; return 0;
        case kAudioDevicePropertyLatency:
            REQUIRE_SIZE(sizeof(UInt32));
            *(UInt32*)outData = a->mScope == kAudioObjectPropertyScopeInput ? kInputLatency : kOutputLatency;
            return 0;
        case kAudioDevicePropertySafetyOffset:
            REQUIRE_SIZE(sizeof(UInt32));
            *(UInt32*)outData = a->mScope == kAudioObjectPropertyScopeInput ? kInputSafetyOffset : kOutputSafetyOffset;
            return 0;
        case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
        case kAudioDevicePropertyNominalSampleRate: REQUIRE_SIZE(sizeof(Float64)); *(Float64*)outData = kSampleRate; return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return 0; }
            *outDataSize = sizeof(AudioValueRange);
            ((AudioValueRange*)outData)->mMinimum = kSampleRate;
            ((AudioValueRange*)outData)->mMaximum = kSampleRate;
            return 0;
        case kAudioDevicePropertyIsHidden: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 0; return 0;
        case kAudioDevicePropertyZeroTimeStampPeriod: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = kZeroTimeStampPeriod; return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            REQUIRE_SIZE(2 * sizeof(UInt32)); ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2; return 0;
        }
        break;

    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output: {
        bool input = id == kObjectID_Stream_Input;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: REQUIRE_SIZE(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioObjectClassID; return 0;
        case kAudioObjectPropertyClass: REQUIRE_SIZE(sizeof(AudioClassID)); *(AudioClassID*)outData = kAudioStreamClassID; return 0;
        case kAudioObjectPropertyOwner: REQUIRE_SIZE(sizeof(AudioObjectID)); *(AudioObjectID*)outData = kObjectID_Device; return 0;
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return 0;
        case kAudioStreamPropertyIsActive:
            REQUIRE_SIZE(sizeof(UInt32));
            pthread_mutex_lock(&gStateMutex);
            *(UInt32*)outData = input ? gStreamInputActive : gStreamOutputActive;
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        case kAudioStreamPropertyDirection: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = input ? 1 : 0; return 0;
        case kAudioStreamPropertyTerminalType:
            REQUIRE_SIZE(sizeof(UInt32));
            *(UInt32*)outData = input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            return 0;
        case kAudioStreamPropertyStartingChannel: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 1; return 0;
        case kAudioStreamPropertyLatency: REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = 0; return 0;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            REQUIRE_SIZE(sizeof(AudioStreamBasicDescription));
            *(AudioStreamBasicDescription*)outData = StreamFormat();
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return 0; }
            *outDataSize = sizeof(AudioStreamRangedDescription);
            ((AudioStreamRangedDescription*)outData)->mFormat = StreamFormat();
            ((AudioStreamRangedDescription*)outData)->mSampleRateRange.mMinimum = kSampleRate;
            ((AudioStreamRangedDescription*)outData)->mSampleRateRange.mMaximum = kSampleRate;
            return 0;
        }
        break;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus TG_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qs, const void* q, UInt32 inDataSize, const void* inData) {
    (void)pid; (void)qs; (void)q;
    if (d != gDriverRef || a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!IsStream(id)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioStreamPropertyIsActive: {
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        bool active = *(const UInt32*)inData != 0;
        bool changed;
        pthread_mutex_lock(&gStateMutex);
        bool* target = id == kObjectID_Stream_Input ? &gStreamInputActive : &gStreamOutputActive;
        changed = *target != active;
        *target = active;
        pthread_mutex_unlock(&gStateMutex);
        if (changed && gHost) {
            AudioObjectPropertyAddress changedAddress = {kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                                                         kAudioObjectPropertyElementMain};
            gHost->PropertiesChanged(gHost, id, 1, &changedAddress);
        }
        return 0;
    }
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        // Only the one format exists; accept it, refuse anything else.
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = inData;
        AudioStreamBasicDescription mine = StreamFormat();
        if (f->mFormatID != mine.mFormatID || f->mChannelsPerFrame != mine.mChannelsPerFrame ||
            f->mBitsPerChannel != mine.mBitsPerChannel || (f->mSampleRate != 0 && f->mSampleRate != mine.mSampleRate))
            return kAudioDeviceUnsupportedFormatError;
        return 0;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus TG_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        // Start the device's timeline at 0 now, keeping the phone frame each device frame stands for.
        pthread_mutex_lock(&gClockWriteMutex);
        ClockMap c = gClock;
        double now = NowSeconds();
        double s = floor(SampleAtHost(c, now));
        // The same line through time, shifted down by s frames: device frame 0 is now, and phone frame = device frame + offset still.
        c.aSample -= s;
        c.offset += (int64_t)s;
        WriteClock(c);
        pthread_mutex_unlock(&gClockWriteMutex);
        atomic_store(&gOutReset, true);
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus TG_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus TG_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64* outSampleTime,
                                    UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    ClockMap c = ReadClock();
    double now = SampleAtHost(c, NowSeconds());
    double zero = floor(now / kZeroTimeStampPeriod) * kZeroTimeStampPeriod;
    double host = c.aHost + (zero - c.aSample) / c.rate;
    *outSampleTime = zero;
    *outHostTime = host > 0 ? (UInt64)(host * gTicksPerSecond) : 0;
    *outSeed = atomic_load(&gSeed);
    return kAudioHardwareNoError;
}

static OSStatus TG_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean* outWill,
                                     Boolean* outInPlace) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    bool will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWill) *outWill = will;
    if (outInPlace) *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus TG_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                    const AudioServerPlugInIOCycleInfo* info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus TG_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* main, void* secondary) {
    (void)client; (void)secondary;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (main == NULL || info == NULL) return kAudioHardwareNoError;
    Float32* buf = main;
    int64_t offset = ReadClock().offset;

    if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_Stream_Input) {
        int64_t start = (int64_t)llround(info->mInputTime.mSampleTime) + offset;
        UInt64 from = atomic_load_explicit(&gInValidFrom, memory_order_relaxed);
        UInt64 upTo = atomic_load_explicit(&gInWrittenUpTo, memory_order_acquire);
        for (UInt32 f = 0; f < frames; f++) {
            int64_t t = start + f;
            if (t >= 0 && (UInt64)t >= from && (UInt64)t < upTo) {
                UInt32 i = (UInt32)((UInt64)t & kRingMask) * kChannels;
                buf[f * kChannels] = gInRing[i];
                buf[f * kChannels + 1] = gInRing[i + 1];
            } else {
                buf[f * kChannels] = 0;
                buf[f * kChannels + 1] = 0;
            }
        }
    } else if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjectID_Stream_Output) {
        int64_t start = (int64_t)llround(info->mOutputTime.mSampleTime) + offset;
        if (start < 0) return kAudioHardwareNoError;
        for (UInt32 f = 0; f < frames; f++) {
            UInt32 i = (UInt32)(((UInt64)start + f) & kRingMask) * kChannels;
            gOutRing[i] = buf[f * kChannels];
            gOutRing[i + 1] = buf[f * kChannels + 1];
        }
        UInt64 end = (UInt64)start + frames;
        UInt64 previous = atomic_load_explicit(&gOutWrittenUpTo, memory_order_relaxed);
        if (end > previous || previous - end > kRingFrames) atomic_store_explicit(&gOutWrittenUpTo, end, memory_order_release);
        semaphore_signal(gSendSemaphore);
    }
    return kAudioHardwareNoError;
}

static OSStatus TG_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                  const AudioServerPlugInIOCycleInfo* info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
