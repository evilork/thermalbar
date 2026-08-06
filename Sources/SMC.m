// Sources/SMC.m - AppleSMC user client reader for Intel Macs (x86_64).
// Works on real Intel Macs and hackintoshes running VirtualSMC/FakeSMC.
// Classic smcFanControl-style implementation. No ARC required.
#import "SMC.h"
#import <IOKit/IOKitLib.h>
#import <math.h>
#import <string.h>

// --- SMC kernel interface constants ---
enum {
    kSMCUserClientOpen   = 0,
    kSMCUserClientClose  = 1,
    kSMCHandleYPCEvent   = 2
};

enum {
    kSMCReadKey          = 5,
    kSMCGetKeyInfo       = 9
};

#define kSMCSuccess 0

typedef struct {
    char    major;
    char    minor;
    char    build;
    char    reserved[1];
    UInt16  release;
} SMCKeyDescriptor_vers_t;

typedef struct {
    UInt16  version;
    UInt16  length;
    UInt32  cpuPLimit;
    UInt32  gpuPLimit;
    UInt32  memPLimit;
} SMCKeyDescriptor_pLimitData_t;

typedef struct {
    UInt32  dataSize;
    UInt32  dataType;
    UInt8   dataAttributes;
} SMCKeyDescriptor_keyInfo_t;

typedef unsigned char SMCBytes_t[32];

typedef struct {
    UInt32                        key;
    SMCKeyDescriptor_vers_t       vers;
    SMCKeyDescriptor_pLimitData_t pLimitData;
    SMCKeyDescriptor_keyInfo_t    keyInfo;
    char                          result;
    char                          status;
    UInt8                         data8;
    UInt32                        data32;
    SMCBytes_t                    bytes;
} SMCParamStruct;

static UInt32 fourCC(const char *s) {
    return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3];
}

static io_connect_t openSMC(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return IO_OBJECT_NULL;
    io_connect_t conn;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;
    return conn;
}

static kern_return_t smcCall(io_connect_t conn, SMCParamStruct *in, SMCParamStruct *out) {
    size_t inSize = sizeof(SMCParamStruct);
    size_t outSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent,
                                     in, inSize, out, &outSize);
}

static double decodeTemperature(const SMCParamStruct *s) {
    UInt32 dataType = s->keyInfo.dataType;
    if (dataType == fourCC("sp78")) {
        // Signed fixed-point 8.8, big-endian.
        int16_t raw = (int16_t)((s->bytes[0] << 8) | s->bytes[1]);
        return (double)raw / 256.0;
    }
    if (dataType == fourCC("flt ")) {
        // IEEE754 float, big-endian.
        uint8_t b[4] = { s->bytes[3], s->bytes[2], s->bytes[1], s->bytes[0] };
        float f;
        memcpy(&f, b, 4);
        return (double)f;
    }
    if (dataType == fourCC("fpe2")) {
        // Unsigned fixed-point 14.2, big-endian.
        uint16_t raw = (uint16_t)((s->bytes[0] << 8) | s->bytes[1]);
        return (double)raw / 4.0;
    }
    if (dataType == fourCC("ui8 ")) {
        return (double)s->bytes[0];
    }
    if (dataType == fourCC("ui16")) {
        return (double)((s->bytes[0] << 8) | s->bytes[1]);
    }
    return NAN;
}

double readSMCTemperature(NSString *keyName) {
    const char *k = [keyName UTF8String];
    if (!k || strlen(k) != 4) return NAN;

    io_connect_t conn = openSMC();
    if (conn == IO_OBJECT_NULL) return NAN;

    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));

    // 1. kSMCGetKeyInfo - learn the key's data type.
    in.key = fourCC(k);
    in.data8 = kSMCGetKeyInfo;
    kern_return_t kr = smcCall(conn, &in, &out);
    if (kr != KERN_SUCCESS || out.result != kSMCSuccess) {
        IOServiceClose(conn);
        return NAN;
    }
    const UInt32 dataSize = out.keyInfo.dataSize;
    const UInt32 dataType = out.keyInfo.dataType;

    // 2. kSMCReadKey - read the value.
    // NOTE: pass only keyInfo.dataSize, NOT the full keyInfo - VirtualSMC
    // rejects the read when keyInfo is zero/foreign (matches the behavior
    // of the official smcread tool). The read response does not carry the
    // data type, so decode with the type from kSMCGetKeyInfo.
    memset(&in, 0, sizeof(in));
    in.key = fourCC(k);
    in.keyInfo.dataSize = dataSize;
    in.data8 = kSMCReadKey;
    memset(&out, 0, sizeof(out));
    kr = smcCall(conn, &in, &out);
    IOServiceClose(conn);
    if (kr != KERN_SUCCESS || out.result != kSMCSuccess) return NAN;

    out.keyInfo.dataType = dataType;
    return decodeTemperature(&out);
}
