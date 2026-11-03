// Snapshot.swift - one reading of every sensor. Missing values are nil, never NaN.
import Foundation

struct FanReading: Codable, Equatable {
    var rpm: Double
    var maxRPM: Double

    /// Share of the maximum speed, 0...100.
    var percent: Double {
        guard maxRPM > 0 else { return 0 }
        return min(100, max(0, rpm / maxRPM * 100))
    }
}

struct Snapshot: Equatable {
    var time: Date
    /// Celsius.
    var cpuTemp: Double?
    var gpuTemp: Double?
    /// Whole-system power, watts.
    var power: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    /// Average GPU clock while active, MHz.
    var gpuFreqMHz: Double?
    /// Share of time the GPU was busy, 0...1.
    var gpuActive: Double?
    var memUsed: UInt64?
    var memTotal: UInt64?
    var swapUsed: UInt64?
    /// 100 minus the free-memory percentage macOS reports.
    var memPressurePercent: Double?
    var memPressure: MemoryPressure
    var thermal: ThermalPressure
    var fans: [FanReading]
    var lowPowerMode: Bool

    static func empty(at time: Date) -> Snapshot {
        Snapshot(time: time, cpuTemp: nil, gpuTemp: nil, power: nil, cpuPower: nil, gpuPower: nil,
                 gpuFreqMHz: nil, gpuActive: nil, memUsed: nil, memTotal: nil, swapUsed: nil,
                 memPressurePercent: nil, memPressure: .normal, thermal: .nominal, fans: [],
                 lowPowerMode: false)
    }

    /// Fastest fan as a share of its maximum, or nil on fanless Macs.
    var fanPercent: Double? { fans.isEmpty ? nil : fans.map(\.percent).max() }

    var hasAnyReading: Bool {
        cpuTemp != nil || gpuTemp != nil || power != nil || memPressurePercent != nil
    }
}
