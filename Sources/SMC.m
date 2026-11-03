// SMC.m - minimal read-only SMC client (AppleSMC user client, struct method 2).
// Struct layout follows the long-standing smcFanControl / Stats definitions.
#import "SMC.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} TBSMCVersion;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} TBSMCPLimit;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} TBSMCKeyInfo;

typedef struct {
    UInt32 key;
    TBSMCVersion vers;
    TBSMCPLimit pLimitData;
    TBSMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    unsigned char bytes[32];
} TBSMCKeyData;

_Static_assert(sizeof(TBSMCKeyData) == 80, "SMC key data must be 80 bytes");

enum {
    kTBSMCMethod = 2,
    kTBSMCReadBytes = 5,
    kTBSMCReadIndex = 8,
    kTBSMCReadKeyInfo = 9,
};

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t gConn = 0;
static int gOpenFailed = 0;

unsigned int tb_smc_fourcc(const char *s) {
    if (!s || strlen(s) < 4) return 0;
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16) |
           ((UInt32)(unsigned char)s[2] << 8) | (UInt32)(unsigned char)s[3];
}

// Caller holds gLock.
static int ensureOpen(void) {
    if (gConn) return 1;
    if (gOpenFailed) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) {
        gOpenFailed = 1;
        return 0;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        gConn = 0;
        gOpenFailed = 1;
        return 0;
    }
    return 1;
}

// Caller holds gLock and an open connection.
static int call(TBSMCKeyData *in, TBSMCKeyData *out) {
    size_t outSize = sizeof(TBSMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod(gConn, kTBSMCMethod, in, sizeof(TBSMCKeyData), out, &outSize);
    return kr == KERN_SUCCESS && out->result == 0;
}

// Caller holds gLock.
static int keyInfoLocked(UInt32 key, UInt32 *type, UInt32 *size) {
    if (!ensureOpen()) return 0;
    TBSMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = kTBSMCReadKeyInfo;
    if (!call(&in, &out)) return 0;
    if (out.keyInfo.dataSize == 0 || out.keyInfo.dataSize > 32) return 0;
    *type = out.keyInfo.dataType;
    *size = out.keyInfo.dataSize;
    return 1;
}

// Caller holds gLock.
static int readBytesLocked(UInt32 key, UInt32 size, unsigned char bytes[32]) {
    if (!ensureOpen()) return 0;
    TBSMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = kTBSMCReadBytes;
    if (!call(&in, &out)) return 0;
    memcpy(bytes, out.bytes, 32);
    return 1;
}

// Decodes the numeric SMC types used by temperature, power and fan keys.
static double decode(UInt32 type, UInt32 size, const unsigned char b[32]) {
    if (type == tb_smc_fourcc("flt ") && size == 4) {
        float f;
        memcpy(&f, b, 4);  // little-endian on Apple Silicon
        return (double)f;
    }
    if (type == tb_smc_fourcc("fpe2") && size == 2) return (double)(((int)b[0] << 6) + ((int)b[1] >> 2));
    if (type == tb_smc_fourcc("sp78") && size == 2) {
        int16_t v = (int16_t)(((uint16_t)b[0] << 8) | b[1]);
        return v / 256.0;
    }
    if (type == tb_smc_fourcc("ui8 ") && size == 1) return (double)b[0];
    if (type == tb_smc_fourcc("ui16") && size == 2) return (double)(((uint16_t)b[0] << 8) | b[1]);
    if (type == tb_smc_fourcc("ui32") && size == 4) {
        return (double)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | (UInt32)b[3]);
    }
    return NAN;
}

int tb_smc_open(void) {
    pthread_mutex_lock(&gLock);
    int ok = ensureOpen();
    pthread_mutex_unlock(&gLock);
    return ok;
}

int tb_smc_key_count(void) {
    double n = tb_smc_read("#KEY");
    if (isnan(n) || n < 0 || n > 100000) return 0;
    return (int)n;
}

int tb_smc_key_at(int index, char out[5]) {
    if (index < 0 || !out) return 0;
    pthread_mutex_lock(&gLock);
    int ok = 0;
    if (ensureOpen()) {
        TBSMCKeyData in, res;
        memset(&in, 0, sizeof in);
        memset(&res, 0, sizeof res);
        in.data8 = kTBSMCReadIndex;
        in.data32 = (UInt32)index;
        if (call(&in, &res)) {
            out[0] = (char)(res.key >> 24);
            out[1] = (char)(res.key >> 16);
            out[2] = (char)(res.key >> 8);
            out[3] = (char)res.key;
            out[4] = 0;
            ok = 1;
        }
    }
    pthread_mutex_unlock(&gLock);
    return ok;
}

int tb_smc_key_info(const char *key, unsigned int *type, unsigned int *size) {
    UInt32 code = tb_smc_fourcc(key);
    if (!code || !type || !size) return 0;
    pthread_mutex_lock(&gLock);
    UInt32 t = 0, s = 0;
    int ok = keyInfoLocked(code, &t, &s);
    pthread_mutex_unlock(&gLock);
    if (ok) {
        *type = t;
        *size = s;
    }
    return ok;
}

double tb_smc_read_known(const char *key, unsigned int type, unsigned int size) {
    UInt32 code = tb_smc_fourcc(key);
    if (!code || size == 0 || size > 32) return NAN;
    unsigned char bytes[32];
    pthread_mutex_lock(&gLock);
    int ok = readBytesLocked(code, size, bytes);
    pthread_mutex_unlock(&gLock);
    return ok ? decode(type, size, bytes) : NAN;
}

double tb_smc_read(const char *key) {
    unsigned int type = 0, size = 0;
    if (!tb_smc_key_info(key, &type, &size)) return NAN;
    return tb_smc_read_known(key, type, size);
}

void tb_smc_close(void) {
    pthread_mutex_lock(&gLock);
    if (gConn) {
        IOServiceClose(gConn);
        gConn = 0;
    }
    pthread_mutex_unlock(&gLock);
}
