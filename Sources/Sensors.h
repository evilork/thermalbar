// Sensors.h - native temperature sensor reading via private IOKit HID (Apple Silicon).
#ifndef SENSORS_H
#define SENSORS_H

#import <Foundation/Foundation.h>

// Returns { sensorName(NSString) : temperature(NSNumber, Celsius) }.
// No sudo. Works on Apple Silicon (M1-M5).
NSDictionary<NSString *, NSNumber *> * _Nullable readTemperatureSensors(void);

#endif
