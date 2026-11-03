// Detectors.swift - "held for N seconds" logic, the stuck-GPU rule, alert gating and panel status.
// Pure Foundation: compiled into both the app and the test runner.
import Foundation

/// Tracks how long a condition has held without a break.
struct Sustain {
    private(set) var since: Date?

    init() {
        since = nil
    }

    /// Returns how long the condition has been active, 0 when it is not (or just became) active.
    mutating func update(_ active: Bool, now: Date) -> TimeInterval {
        guard active else {
            since = nil
            return 0
        }
        guard let start = since else {
            since = now
            return 0
        }
        return max(0, now.timeIntervalSince(start))
    }
}

/// A GPU that is fully busy yet stays at a low clock without heat or Low Power Mode to explain it.
/// Known Apple Silicon glitch; a restart clears it.
enum GPUStuck {
    static let minActive = 0.85
    static let maxClockShare = 0.55
    static let maxTemp = 88.0
    static let holdSeconds: TimeInterval = 45

    static func looksStuck(_ s: Snapshot, maxMHz: Double) -> Bool {
        guard maxMHz.isFinite, maxMHz > 0,
              let freq = s.gpuFreqMHz, freq.isFinite, freq > 0,
              let active = s.gpuActive, active.isFinite else { return false }
        guard active >= minActive, freq <= maxMHz * maxClockShare else { return false }
        if s.thermal.isThrottling { return false }
        if let t = s.gpuTemp, t >= maxTemp { return false }
        if s.lowPowerMode { return false }
        return true
    }
}

enum AlertKind: String, CaseIterable, Codable {
    case memory
    case throttle
    case gpuStuck

    /// How long the condition must hold before a notification.
    var holdSeconds: TimeInterval {
        switch self {
        case .memory: return 20
        case .throttle: return 10
        case .gpuStuck: return 45
        }
    }

    /// Minimum time between two notifications of this kind.
    var cooldown: TimeInterval {
        switch self {
        case .memory: return 1800
        case .throttle: return 1200
        case .gpuStuck: return 7200
        }
    }
}

/// Decides when a notification is due: after the hold, once per streak, outside the cooldown.
struct AlertEngine {
    private var sustains: [AlertKind: Sustain] = [:]
    private var lastFired: [AlertKind: Date] = [:]
    private var firedThisStreak: Set<AlertKind> = []

    init() {}

    mutating func evaluate(conditions: [AlertKind: Bool], enabled: Set<AlertKind>, now: Date) -> [AlertKind] {
        var fired: [AlertKind] = []
        for kind in AlertKind.allCases {
            let active = conditions[kind] ?? false
            var sustain = sustains[kind] ?? Sustain()
            let held = sustain.update(active, now: now)
            sustains[kind] = sustain
            guard active else {
                firedThisStreak.remove(kind)
                continue
            }
            guard held >= kind.holdSeconds, enabled.contains(kind), !firedThisStreak.contains(kind) else {
                continue
            }
            if let last = lastFired[kind], now.timeIntervalSince(last) < kind.cooldown {
                continue
            }
            lastFired[kind] = now
            firedThisStreak.insert(kind)
            fired.append(kind)
        }
        return fired
    }

    func heldFor(_ kind: AlertKind, now: Date) -> TimeInterval {
        guard let since = sustains[kind]?.since else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }
}

/// One-line verdict in the panel header.
enum PanelStatus: Equatable {
    case starting
    case calm
    case warm
    case hot
    case throttling
    case memory
    case gpuStuck

    var level: Level {
        switch self {
        case .starting, .calm: return .normal
        case .warm, .memory: return .warn
        case .hot, .throttling, .gpuStuck: return .high
        }
    }

    var key: K {
        switch self {
        case .starting: return .statusStarting
        case .calm: return .statusCalm
        case .warm: return .statusWarm
        case .hot: return .statusHot
        case .throttling: return .statusThrottling
        case .memory: return .statusMemory
        case .gpuStuck: return .statusGPUStuck
        }
    }

    static func evaluate(snapshot: Snapshot?, config: Config, gpuStuck: Bool) -> PanelStatus {
        guard let s = snapshot else { return .starting }
        if gpuStuck { return .gpuStuck }
        if s.thermal.isThrottling { return .throttling }
        if s.memPressure >= .warn { return .memory }
        let worst = [
            config.cpuTemp.level(for: s.cpuTemp),
            config.gpuTemp.level(for: s.gpuTemp),
            config.power.level(for: s.power),
        ].max() ?? .normal
        if worst >= .high { return .hot }
        if s.thermal == .moderate || worst == .warn { return .warm }
        return .calm
    }
}
