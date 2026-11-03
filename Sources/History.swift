// History.swift - short trends for sparklines, today's peaks, game sessions and their storage.
// Pure Foundation: compiled into both the app and the test runner.
import Foundation

/// Fixed-size series of recent values, oldest first.
struct Series: Equatable {
    let capacity: Int
    private(set) var values: [Double]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        values = []
        values.reserveCapacity(self.capacity)
    }

    /// Appends a value; nil and non-finite values are ignored. O(capacity) when full.
    mutating func append(_ value: Double?) {
        guard let v = value, v.isFinite else { return }
        values.append(v)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    var last: Double? { values.last }
    var minValue: Double? { values.min() }
    var maxValue: Double? { values.max() }
}

/// Recent history of the four main readings, for the panel's sparklines.
struct Trends: Equatable {
    /// About 5 minutes at a 2 s interval.
    static let capacity = 150

    var cpu: Series
    var gpu: Series
    var power: Series
    var memory: Series

    init() {
        cpu = Series(capacity: Trends.capacity)
        gpu = Series(capacity: Trends.capacity)
        power = Series(capacity: Trends.capacity)
        memory = Series(capacity: Trends.capacity)
    }

    mutating func absorb(_ s: Snapshot) {
        cpu.append(s.cpuTemp)
        gpu.append(s.gpuTemp)
        power.append(s.power)
        memory.append(s.memPressurePercent)
    }
}

/// Larger of two optional readings; non-finite values count as missing.
private func maxReading(_ a: Double?, _ b: Double?) -> Double? {
    let x = a.flatMap { $0.isFinite ? $0 : nil }
    let y = b.flatMap { $0.isFinite ? $0 : nil }
    switch (x, y) {
    case let (p?, q?): return max(p, q)
    case let (p?, nil): return p
    case let (nil, q?): return q
    case (nil, nil): return nil
    }
}

/// Highest readings of the current local day.
struct DayPeaks: Codable, Equatable {
    var day: String
    var cpu: Double?
    var gpu: Double?
    var power: Double?
    var memory: Double?
    var fan: Double?

    init(day: String) {
        self.day = day
    }

    /// "yyyy-MM-dd" in the given calendar (local by default).
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Folds a reading in; starts over when the reading belongs to another day.
    mutating func absorb(_ s: Snapshot, calendar: Calendar = .current) {
        let k = DayPeaks.key(for: s.time, calendar: calendar)
        if k != day {
            self = DayPeaks(day: k)
        }
        cpu = maxReading(cpu, s.cpuTemp)
        gpu = maxReading(gpu, s.gpuTemp)
        power = maxReading(power, s.power)
        memory = maxReading(memory, s.memPressurePercent)
        fan = maxReading(fan, s.fanPercent)
    }
}

/// One game (or heavy GPU) session.
struct GameSession: Codable, Equatable {
    var name: String
    var bundleID: String?
    var start: Date
    var end: Date
    var maxCPU: Double?
    var maxGPU: Double?
    var maxPower: Double?
    var throttledSeconds: Double
    var gpuStuckSeconds: Double
    var worstMemory: MemoryPressure

    init(name: String, bundleID: String?, start: Date) {
        self.name = name
        self.bundleID = bundleID
        self.start = start
        end = start
        throttledSeconds = 0
        gpuStuckSeconds = 0
        worstMemory = .normal
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Folds one reading in. `interval` is the time this reading stands for (ignored when negative).
    mutating func absorb(_ s: Snapshot, interval: TimeInterval, gpuStuck: Bool) {
        maxCPU = maxReading(maxCPU, s.cpuTemp)
        maxGPU = maxReading(maxGPU, s.gpuTemp)
        maxPower = maxReading(maxPower, s.power)
        if interval.isFinite, interval > 0 {
            if s.thermal.isThrottling { throttledSeconds += interval }
            if gpuStuck { gpuStuckSeconds += interval }
        }
        worstMemory = max(worstMemory, s.memPressure)
        if s.time > end { end = s.time }
    }
}

/// What survives a restart: today's peaks and the last finished game.
struct PersistedState: Codable, Equatable {
    var today: DayPeaks?
    var lastGame: GameSession?

    init() {}
}

/// Reads and writes PersistedState as JSON.
struct StateStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ThermalBar", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// Missing file gives an empty state; an unreadable one is moved aside and an empty state returned.
    func load(log: (String) -> Void) -> PersistedState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                log("state: cannot read \(url.path): \(error)")
            }
            return PersistedState()
        }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("state.broken-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                log("state: unreadable, moved to \(aside.lastPathComponent): \(error)")
            } catch let moveError {
                log("state: unreadable and could not be moved aside: \(moveError)")
            }
            return PersistedState()
        }
    }

    func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: url, options: .atomic)
    }
}
