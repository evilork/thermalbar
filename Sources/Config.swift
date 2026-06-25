// Config.swift - configuration with per-metric toggles and color thresholds.
// Stored at ~/.config/thermalbar/config.json.
import Foundation

struct Thresholds: Codable {
    var normal: Double
    var warn: Double
    var high: Double
}

struct MetricConfig: Codable {
    var enabled: Bool
    var thresholds: Thresholds
}

struct Config: Codable {
    var cpuTemp: MetricConfig
    var gpuTemp: MetricConfig
    var power: MetricConfig
    var ram: MetricConfig
    var intervalSeconds: Double
    var showLabels: Bool

    init(cpuTemp: MetricConfig, gpuTemp: MetricConfig, power: MetricConfig,
         ram: MetricConfig, intervalSeconds: Double, showLabels: Bool) {
        self.cpuTemp = cpuTemp; self.gpuTemp = gpuTemp; self.power = power
        self.ram = ram; self.intervalSeconds = intervalSeconds; self.showLabels = showLabels
    }

    // Tolerant decoder: missing fields fall back to defaults so an older
    // config.json (e.g. without "ram") still loads instead of being discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaultConfig
        cpuTemp = (try? c.decode(MetricConfig.self, forKey: .cpuTemp)) ?? d.cpuTemp
        gpuTemp = (try? c.decode(MetricConfig.self, forKey: .gpuTemp)) ?? d.gpuTemp
        power   = (try? c.decode(MetricConfig.self, forKey: .power))   ?? d.power
        ram     = (try? c.decode(MetricConfig.self, forKey: .ram))     ?? d.ram
        intervalSeconds = (try? c.decode(Double.self, forKey: .intervalSeconds)) ?? d.intervalSeconds
        showLabels      = (try? c.decode(Bool.self,   forKey: .showLabels))      ?? d.showLabels
    }

    // CPU is read natively (always available). GPU/power/RAM come from the macmon
    // HTTP helper; if it isn't running, those metrics simply hide.
    // RAM is usage percent, so thresholds are higher (memory is often heavily used).
    static let defaultConfig = Config(
        cpuTemp: MetricConfig(enabled: true, thresholds: Thresholds(normal: 60, warn: 75, high: 90)),
        gpuTemp: MetricConfig(enabled: true, thresholds: Thresholds(normal: 60, warn: 75, high: 90)),
        power:   MetricConfig(enabled: true, thresholds: Thresholds(normal: 30, warn: 55, high: 80)),
        ram:     MetricConfig(enabled: true, thresholds: Thresholds(normal: 70, warn: 85, high: 95)),
        intervalSeconds: 3,
        showLabels: true
    )

    static var path: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/thermalbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        guard
            let data = try? Data(contentsOf: path),
            let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else {
            let def = defaultConfig
            def.save()
            return def
        }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.path)
        }
    }
}
