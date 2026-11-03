// Perf.m - IOReport sampling (the same private API Activity Monitor and powermetrics use).
// GPU: "GPU Stats" / "GPU Performance States" / "GPUPH" residencies weighted by the
// frequency table from the "pmgr" device. Power: "Energy Model" CPU and GPU energy.
#import "Perf.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>

typedef struct IOReportSubscriptionCF *IOReportSubscriptionRef;

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup,
                                                           uint64_t a, uint64_t b, uint64_t c);
extern void IOReportMergeChannels(CFMutableDictionaryRef into, CFDictionaryRef from, CFTypeRef unused);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desired,
                                                          CFMutableDictionaryRef *subscribed,
                                                          uint64_t channelId, CFTypeRef unused2);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef channels,
                                             CFTypeRef unused);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current,
                                                  CFTypeRef unused);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
extern int32_t IOReportStateGetCount(CFDictionaryRef channel);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef channel, int32_t index);
extern int64_t IOReportStateGetResidency(CFDictionaryRef channel, int32_t index);

enum { kTBMaxFreqs = 64 };

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static IOReportSubscriptionRef gSub = NULL;
static CFMutableDictionaryRef gChannels = NULL;
static CFDictionaryRef gPrev = NULL;
static uint64_t gPrevTime = 0;
static double gFreqs[kTBMaxFreqs];  // active GPU states, MHz, ascending
static int gFreqCount = 0;

// Reads the GPU DVFS table ("voltage-states9": pairs of uint32 frequency, voltage).
static void loadGPUFrequencies(void) {
    gFreqCount = 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) != KERN_SUCCESS) {
        return;
    }
    io_object_t entry;
    while ((entry = IOIteratorNext(iter))) {
        io_name_t name;
        if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS && strcmp(name, "pmgr") == 0) {
            CFTypeRef prop = IORegistryEntryCreateCFProperty(entry, CFSTR("voltage-states9"), kCFAllocatorDefault, 0);
            if (prop && CFGetTypeID(prop) == CFDataGetTypeID()) {
                CFDataRef data = (CFDataRef)prop;
                CFIndex len = CFDataGetLength(data);
                const UInt8 *bytes = CFDataGetBytePtr(data);
                double raw[kTBMaxFreqs];
                int n = 0;
                double maxRaw = 0;
                for (CFIndex off = 0; off + 8 <= len && n < kTBMaxFreqs; off += 8) {
                    UInt32 f = 0;
                    memcpy(&f, bytes + off, 4);  // little-endian
                    if (f == 0) continue;        // the "off" state
                    raw[n++] = (double)f;
                    if (f > maxRaw) maxRaw = f;
                }
                // Tables are in Hz on most chips and in kHz on some; normalise to MHz.
                double scale = maxRaw > 1e8 ? 1e6 : (maxRaw > 1e5 ? 1e3 : 1.0);
                for (int i = 0; i < n; i++) gFreqs[i] = raw[i] / scale;
                gFreqCount = n;
            }
            if (prop) CFRelease(prop);
        }
        IOObjectRelease(entry);
        if (gFreqCount > 0) break;
    }
    IOObjectRelease(iter);
}

static int isIdleState(CFStringRef name) {
    if (!name) return 1;
    return CFStringCompare(name, CFSTR("OFF"), 0) == kCFCompareEqualTo ||
           CFStringCompare(name, CFSTR("IDLE"), 0) == kCFCompareEqualTo ||
           CFStringCompare(name, CFSTR("DOWN"), 0) == kCFCompareEqualTo;
}

static double energyToJoules(int64_t value, CFStringRef unit) {
    if (!unit) return -1;
    if (CFStringCompare(unit, CFSTR("mJ"), 0) == kCFCompareEqualTo) return value / 1e3;
    if (CFStringCompare(unit, CFSTR("uJ"), 0) == kCFCompareEqualTo) return value / 1e6;
    if (CFStringCompare(unit, CFSTR("nJ"), 0) == kCFCompareEqualTo) return value / 1e9;
    return -1;
}

static double machToSeconds(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)ticks * tb.numer / tb.denom / 1e9;
}

int tb_perf_open(void) {
    pthread_mutex_lock(&gLock);
    if (gSub) {
        pthread_mutex_unlock(&gLock);
        return 1;
    }
    loadGPUFrequencies();
    CFMutableDictionaryRef energy = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFMutableDictionaryRef gpu = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    CFMutableDictionaryRef merged = energy ? energy : gpu;
    if (energy && gpu) IOReportMergeChannels(energy, gpu, NULL);
    if (!merged) {
        pthread_mutex_unlock(&gLock);
        return 0;
    }
    gChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(merged), merged);
    if (energy) CFRelease(energy);
    if (gpu) CFRelease(gpu);
    if (!gChannels) {
        pthread_mutex_unlock(&gLock);
        return 0;
    }
    CFMutableDictionaryRef subscribed = NULL;
    gSub = IOReportCreateSubscription(NULL, gChannels, &subscribed, 0, NULL);
    if (!gSub) {
        CFRelease(gChannels);
        gChannels = NULL;
        pthread_mutex_unlock(&gLock);
        return 0;
    }
    pthread_mutex_unlock(&gLock);
    return 1;
}

TBPerfSample tb_perf_sample(void) {
    TBPerfSample out = {0, 0, 0, -1, -1};
    pthread_mutex_lock(&gLock);
    if (!gSub || !gChannels) {
        pthread_mutex_unlock(&gLock);
        return out;
    }
    CFDictionaryRef now = IOReportCreateSamples(gSub, gChannels, NULL);
    uint64_t nowTime = mach_absolute_time();
    if (!now) {
        pthread_mutex_unlock(&gLock);
        return out;
    }
    if (!gPrev) {
        gPrev = now;
        gPrevTime = nowTime;
        pthread_mutex_unlock(&gLock);
        return out;
    }
    double dt = machToSeconds(nowTime - gPrevTime);
    CFDictionaryRef delta = IOReportCreateSamplesDelta(gPrev, now, NULL);
    CFRelease(gPrev);
    gPrev = now;
    gPrevTime = nowTime;
    if (!delta || dt <= 0.05) {
        if (delta) CFRelease(delta);
        pthread_mutex_unlock(&gLock);
        return out;
    }

    double cpuJ = 0, gpuJ = 0;
    int cpuSeen = 0, gpuSeen = 0;
    CFArrayRef items = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (items && CFGetTypeID(items) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(items);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef ch = (CFDictionaryRef)CFArrayGetValueAtIndex(items, i);
            if (!ch || CFGetTypeID(ch) != CFDictionaryGetTypeID()) continue;
            CFStringRef group = IOReportChannelGetGroup(ch);
            CFStringRef name = IOReportChannelGetChannelName(ch);
            if (!group || !name) continue;

            if (CFStringCompare(group, CFSTR("Energy Model"), 0) == kCFCompareEqualTo) {
                // "CPU Energy" on most chips, "DIE_<n>_CPU Energy" on Ultra; same for GPU.
                int isCPU = CFStringHasSuffix(name, CFSTR("CPU Energy"));
                int isGPU = CFStringCompare(name, CFSTR("GPU Energy"), 0) == kCFCompareEqualTo ||
                            CFStringHasSuffix(name, CFSTR("_GPU Energy"));
                if (!isCPU && !isGPU) continue;
                double j = energyToJoules(IOReportSimpleGetIntegerValue(ch, 0), IOReportChannelGetUnitLabel(ch));
                if (j < 0) continue;
                if (isCPU) { cpuJ += j; cpuSeen = 1; }
                if (isGPU) { gpuJ += j; gpuSeen = 1; }
                continue;
            }

            CFStringRef sub = IOReportChannelGetSubGroup(ch);
            if (CFStringCompare(group, CFSTR("GPU Stats"), 0) != kCFCompareEqualTo || !sub ||
                CFStringCompare(sub, CFSTR("GPU Performance States"), 0) != kCFCompareEqualTo ||
                CFStringCompare(name, CFSTR("GPUPH"), 0) != kCFCompareEqualTo) {
                continue;
            }
            int32_t states = IOReportStateGetCount(ch);
            double total = 0, active = 0, weighted = 0;
            int activeIndex = 0;
            for (int32_t s = 0; s < states; s++) {
                double r = (double)IOReportStateGetResidency(ch, s);
                if (r < 0) r = 0;
                total += r;
                if (isIdleState(IOReportStateGetNameForIndex(ch, s))) continue;
                if (activeIndex < gFreqCount) {
                    active += r;
                    weighted += r * gFreqs[activeIndex];
                }
                activeIndex++;
            }
            if (total > 0) {
                out.gpuValid = 1;
                out.gpuActive = active / total;
                out.gpuFreqMHz = active > 0 ? weighted / active : 0;
            }
        }
    }
    // macOS 27 reports zero CPU energy on some chips; exactly zero over a whole interval means "unknown".
    if (cpuSeen && cpuJ > 0) out.cpuPowerW = cpuJ / dt;
    if (gpuSeen) out.gpuPowerW = gpuJ / dt;
    CFRelease(delta);
    pthread_mutex_unlock(&gLock);
    return out;
}

double tb_perf_gpu_max_mhz(void) {
    pthread_mutex_lock(&gLock);
    double m = gFreqCount > 0 ? gFreqs[gFreqCount - 1] : 0;
    for (int i = 0; i < gFreqCount; i++) {
        if (gFreqs[i] > m) m = gFreqs[i];
    }
    pthread_mutex_unlock(&gLock);
    return m;
}

void tb_perf_close(void) {
    pthread_mutex_lock(&gLock);
    if (gPrev) {
        CFRelease(gPrev);
        gPrev = NULL;
    }
    if (gChannels) {
        CFRelease(gChannels);
        gChannels = NULL;
    }
    // The subscription object has no documented release function; it lives until the process exits.
    gSub = NULL;
    pthread_mutex_unlock(&gLock);
}
