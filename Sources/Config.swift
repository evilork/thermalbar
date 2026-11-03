// Config.swift - user settings, stored at ~/.config/thermalbar/config.json.
// Reads both the v2 format and the v1 format (per-metric "enabled" + normal/warn/high) and migrates.
import Foundation

enum BarLayout: String, Codable, CaseIterable {
    case singleLine
    case twoLines
}

enum ColorMode: String, Codable, CaseIterable {
    /// Numbers stay neutral until a reading needs attention.
    case whenHot
    /// Numbers are always tinted (green when fine), like v1.
    case always
}

enum LanguagePref: String, Codable, CaseIterable {
    case system
    case russian
    case english
}

struct Config: Codable, Equatable {
    static let currentVersion = 2
    static let intervalChoices: [Double] = [1, 2, 3, 5]
    static let transparencyRange: ClosedRange<Double> = 0...0.85

    var version: Int
    var showCPU: Bool
    var showGPU: Bool
    var showPower: Bool
    var showMemory: Bool
    var showFans: Bool
    var showLabels: Bool
    var layout: BarLayout
    var colorMode: ColorMode
    var cpuTemp: Thresholds
    var gpuTemp: Thresholds
    var power: Thresholds
    var intervalSeconds: Double
    var notifyMemory: Bool
    var notifyThrottle: Bool
    var notifyGPUStuck: Bool
    var language: LanguagePref
    /// 0 = solid panel, higher = more of the glass shows through.
    var panelTransparency: Double

    static func defaults(for chip: ChipClass) -> Config {
        Config(version: currentVersion,
               showCPU: true, showGPU: true, showPower: true, showMemory: true, showFans: false,
               showLabels: true, layout: .singleLine, colorMode: .whenHot,
               cpuTemp: Thresholds.temperatureDefaults, gpuTemp: Thresholds.temperatureDefaults,
               power: chip.powerDefaults, intervalSeconds: 2,
               notifyMemory: true, notifyThrottle: true, notifyGPUStuck: true,
               language: .system, panelTransparency: 0.35)
    }

    /// Returns a copy with every value inside its allowed range.
    func sanitized() -> Config {
        var c = self
        c.version = Config.currentVersion
        c.cpuTemp = cpuTemp.normalized(in: Thresholds.temperatureRange)
        c.gpuTemp = gpuTemp.normalized(in: Thresholds.temperatureRange)
        c.power = power.normalized(in: Thresholds.powerRange)
        let interval = intervalSeconds.isFinite ? intervalSeconds : 2
        c.intervalSeconds = min(max(interval.rounded(), 1), 10)
        let t = panelTransparency.isFinite ? panelTransparency : 0.35
        c.panelTransparency = min(max(t, Config.transparencyRange.lowerBound), Config.transparencyRange.upperBound)
        return c
    }
}

// MARK: - Lenient file format (v1 and v2)

private struct V1Thresholds: Decodable {
    var normal: Double?
    var warn: Double?
    var high: Double?
}

private struct V1Metric: Decodable {
    var enabled: Bool?
    var thresholds: V1Thresholds?
}

/// A metric entry is either v2 thresholds or a v1 {enabled, thresholds} object.
private enum MetricEntry: Decodable {
    case v2(Thresholds)
    case v1(V1Metric)

    init(from decoder: Decoder) throws {
        if let t = try? Thresholds(from: decoder) {
            self = .v2(t)
        } else {
            self = .v1(try V1Metric(from: decoder))
        }
    }
}

private struct ConfigFile: Decodable {
    var version: Int?
    var showCPU: Bool?
    var showGPU: Bool?
    var showPower: Bool?
    var showMemory: Bool?
    var showFans: Bool?
    var showLabels: Bool?
    var layout: String?
    var colorMode: String?
    var cpuTemp: MetricEntry?
    var gpuTemp: MetricEntry?
    var power: MetricEntry?
    var ram: MetricEntry?
    var intervalSeconds: Double?
    var notifyMemory: Bool?
    var notifyThrottle: Bool?
    var notifyGPUStuck: Bool?
    var language: String?
    var panelTransparency: Double?
}

enum ConfigError: Error, Equatable {
    case unreadable(String)
}

enum ConfigStore {
    /// v1 shipped these values; a config that still holds them gets the new defaults.
    static let v1TemperatureDefaults = (normal: 60.0, warn: 75.0, high: 90.0)
    static let v1PowerDefaults = (normal: 30.0, warn: 55.0, high: 80.0)

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/thermalbar", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Decodes a config file. `migrated` is true when the data was not already in the current format.
    static func decode(_ data: Data, chip: ChipClass) throws -> (config: Config, migrated: Bool) {
        let file: ConfigFile
        do {
            file = try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            throw ConfigError.unreadable(String(describing: error))
        }
        let d = Config.defaults(for: chip)
        var c = d
        var migrated = (file.version ?? 1) < Config.currentVersion

        func thresholds(_ entry: MetricEntry?, fallback: Thresholds,
                        v1Defaults: (normal: Double, warn: Double, high: Double)) -> (Thresholds, Bool?) {
            switch entry {
            case .none:
                return (fallback, nil)
            case .v2(let t):
                return (t, nil)
            case .v1(let m):
                migrated = true
                guard let t = m.thresholds, let n = t.normal, let w = t.warn, let h = t.high else {
                    return (fallback, m.enabled)
                }
                if n == v1Defaults.normal && w == v1Defaults.warn && h == v1Defaults.high {
                    return (fallback, m.enabled)
                }
                // v1: green below `normal`, orange below `warn`, red below `high`, dark red above.
                return (Thresholds(warn: n, high: w, critical: h), m.enabled)
            }
        }

        let (cpu, cpuOn) = thresholds(file.cpuTemp, fallback: d.cpuTemp, v1Defaults: v1TemperatureDefaults)
        let (gpu, gpuOn) = thresholds(file.gpuTemp, fallback: d.gpuTemp, v1Defaults: v1TemperatureDefaults)
        let (pwr, pwrOn) = thresholds(file.power, fallback: d.power, v1Defaults: v1PowerDefaults)
        c.cpuTemp = cpu
        c.gpuTemp = gpu
        c.power = pwr
        var ramOn: Bool?
        if case .v1(let m)? = file.ram {
            migrated = true
            ramOn = m.enabled
        }

        c.showCPU = file.showCPU ?? cpuOn ?? d.showCPU
        c.showGPU = file.showGPU ?? gpuOn ?? d.showGPU
        c.showPower = file.showPower ?? pwrOn ?? d.showPower
        c.showMemory = file.showMemory ?? ramOn ?? d.showMemory
        c.showFans = file.showFans ?? d.showFans
        c.showLabels = file.showLabels ?? d.showLabels
        c.layout = file.layout.flatMap(BarLayout.init(rawValue:)) ?? d.layout
        c.colorMode = file.colorMode.flatMap(ColorMode.init(rawValue:)) ?? d.colorMode
        c.intervalSeconds = file.intervalSeconds ?? d.intervalSeconds
        c.notifyMemory = file.notifyMemory ?? d.notifyMemory
        c.notifyThrottle = file.notifyThrottle ?? d.notifyThrottle
        c.notifyGPUStuck = file.notifyGPUStuck ?? d.notifyGPUStuck
        c.language = file.language.flatMap(LanguagePref.init(rawValue:)) ?? d.language
        c.panelTransparency = file.panelTransparency ?? d.panelTransparency

        let clean = c.sanitized()
        if clean != c { migrated = true }
        return (clean, migrated)
    }

    static func encode(_ config: Config) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(config.sanitized())
    }

    /// Loads the config. A missing file gives defaults; an unreadable one is set aside (never lost).
    static func load(from url: URL, chip: ChipClass,
                     log: (String) -> Void) -> (config: Config, needsSave: Bool) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                log("config: cannot read \(url.path): \(error)")
            }
            return (Config.defaults(for: chip), true)
        }
        do {
            let (config, migrated) = try decode(data, chip: chip)
            if migrated { log("config: migrated to version \(Config.currentVersion)") }
            return (config, migrated)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("config.broken-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                log("config: unreadable, moved to \(aside.lastPathComponent): \(error)")
            } catch let moveError {
                log("config: unreadable and could not be moved aside: \(moveError)")
            }
            return (Config.defaults(for: chip), true)
        }
    }

    static func save(_ config: Config, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encode(config).write(to: url, options: .atomic)
    }
}
