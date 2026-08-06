// SMC.h - temperature reading via AppleSMC (Intel Macs / hackintosh with VirtualSMC).
#ifndef SMC_H
#define SMC_H

#import <Foundation/Foundation.h>

// Returns temperature in Celsius for the given SMC key (e.g. "TC0P"),
// or NaN if the key is missing or unreadable. No sudo required.
double readSMCTemperature(NSString * _Nonnull key);

#endif
