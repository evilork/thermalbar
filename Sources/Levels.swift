// Levels.swift - severity levels, thresholds and the chip-dependent defaults.
// Pure Foundation: compiled into both the app and the test runner.
import Foundation

/// How alarming a reading is. Drives colours in the menu bar and the panel.
enum Level: Int, Comparable, Codable {
    case normal = 0
    case warn
    case high
    case critical

    static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Values at which a reading turns orange (`warn`), red (`high`) and a red badge (`critical`).
struct Thresholds: Codable, Equatable {
    var warn: Double
    var high: Double
    var critical: Double

    func level(for value: Double?) -> Level {
        guard let v = value, v.isFinite else { return .normal }
        if v >= critical { return .critical }
        if v >= high { return .high }
        if v >= warn { return .warn }
        return .normal
    }

    /// Clamps every value into `range` and keeps them strictly ascending (at least 1 apart).
    func normalized(in range: ClosedRange<Double>) -> Thresholds {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            guard v.isFinite else { return lo }
            return min(max(v, lo), hi)
        }
        let w = clamp(warn.rounded(), range.lowerBound, range.upperBound - 2)
        let h = clamp(high.rounded(), w + 1, range.upperBound - 1)
        let c = clamp(critical.rounded(), h + 1, range.upperBound)
        return Thresholds(warn: w, high: h, critical: c)
    }

    static let temperatureRange: ClosedRange<Double> = 40...115
    static let powerRange: ClosedRange<Double> = 5...400
    static let temperatureDefaults = Thresholds(warn: 70, high: 85, critical: 95)
    /// Fans are judged by share of their maximum speed, in percent.
    static let fan = Thresholds(warn: 70, high: 90, critical: 101)
}

/// Chip family, used to pick sensible power thresholds.
enum ChipClass: String, Codable, Equatable {
    case base
    case pro
    case max
    case ultra

    init(chipName: String) {
        let n = chipName.lowercased()
        if n.contains("ultra") {
            self = .ultra
        } else if n.contains("max") {
            self = .max
        } else if n.contains("pro") {
            self = .pro
        } else {
            self = .base
        }
    }

    /// Whole-system power in watts. A MacBook Air idles at 3-5 W; an M4 Max in a game draws 90-120 W.
    var powerDefaults: Thresholds {
        switch self {
        case .base: return Thresholds(warn: 15, high: 30, critical: 45)
        case .pro: return Thresholds(warn: 40, high: 70, critical: 90)
        case .max: return Thresholds(warn: 60, high: 100, critical: 130)
        case .ultra: return Thresholds(warn: 90, high: 150, critical: 200)
        }
    }
}

/// Memory pressure as macOS itself rates it (kern.memorystatus_vm_pressure_level).
enum MemoryPressure: Int, Codable, Comparable {
    case normal = 1
    case warn = 2
    case critical = 4

    init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2, 3: self = .warn
        default: self = .normal
        }
    }

    var level: Level {
        switch self {
        case .normal: return .normal
        case .warn: return .warn
        case .critical: return .critical
        }
    }

    static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// System thermal pressure (com.apple.system.thermalpressurelevel).
enum ThermalPressure: Int, Codable, Comparable {
    case nominal = 0
    case moderate = 1
    case heavy = 2
    case trapping = 3
    case sleeping = 4

    init(rawState: UInt64) {
        self = ThermalPressure(rawValue: Int(min(rawState, 4))) ?? .nominal
    }

    var level: Level {
        switch self {
        case .nominal: return .normal
        case .moderate: return .warn
        case .heavy: return .high
        case .trapping, .sleeping: return .critical
        }
    }

    /// From .heavy on, macOS lowers CPU and GPU clocks to cool down.
    var isThrottling: Bool { self >= .heavy }

    static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool { lhs.rawValue < rhs.rawValue }
}
