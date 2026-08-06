// Sources/Sensors.m - native HID temperature sensor reading via private IOKit API.
// Works without sudo on Apple Silicon (M1-M5). No ARC required.
// On Intel (x86_64) the HID path is compiled out (no sensor services exist there);
// CPU/GPU temperatures are read via SMC instead (see SMC.m).
#import "Sensors.h"
#import <Foundation/Foundation.h>

#if defined(__arm64__)

// --- Private IOKit HID declarations (not in public headers) ---
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      *IOHIDServiceClientRef;
typedef struct __IOHIDEvent              *IOHIDEventRef;
typedef double IOHIDFloat;

#ifdef __LP64__
typedef uint64_t IOHIDEventField;
#else
typedef uint32_t IOHIDEventField;
#endif

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, IOHIDEventField field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((IOHIDEventField)(type) << 16)

static CFDictionaryRef matchingTemperature(void) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int page = 0xff00;   // kHIDPage_AppleVendor
    int usage = 0x0005;  // kHIDUsage_AppleVendor_TemperatureSensor
    CFNumberRef pageNum  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    CFDictionarySetValue(dict, CFSTR("PrimaryUsagePage"), pageNum);
    CFDictionarySetValue(dict, CFSTR("PrimaryUsage"), usageNum);
    CFRelease(pageNum);
    CFRelease(usageNum);
    return dict;
}

NSDictionary<NSString *, NSNumber *> * readTemperatureSensors(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return nil;

    CFDictionaryRef match = matchingTemperature();
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) { CFRelease(client); return nil; }

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);

        CFTypeRef nameRef = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        if (!nameRef) continue;
        if (CFGetTypeID(nameRef) != CFStringGetTypeID()) { CFRelease(nameRef); continue; }
        NSString *name = (__bridge NSString *)nameRef;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) { CFRelease(nameRef); continue; }
        IOHIDFloat temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(event);

        result[name] = @(temp);
        CFRelease(nameRef);   // release manually (no ARC), no leak
    }
    CFRelease(services);
    CFRelease(client);
    return result.count > 0 ? result : nil;
}

#else // !__arm64__ (Intel): no HID temperature services, use SMC.m instead.

NSDictionary<NSString *, NSNumber *> * readTemperatureSensors(void) {
    return nil;
}

#endif // __arm64__
