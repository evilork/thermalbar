// Games.swift - recognises games and turns GPU load into game sessions.
// Pure Foundation: the app feeds it the frontmost app; the test runner feeds it fixtures.
import Foundation

struct FrontApp: Equatable {
    var name: String
    var bundleID: String?
    var bundlePath: String?
    /// LSApplicationCategoryType is a games category.
    var categoryIsGame: Bool
    var pid: Int32
}

enum GameClassifier {
    /// Bundle ids that are games (or run Windows games) when they appear in front.
    static let knownPrefixes: [String] = [
        "com.blizzard.", "com.riotgames.", "com.epicgames.", "com.feralinteractive.", "com.aspyr.",
        "unity.", "com.codeweavers.crossover", "com.isaacmarovitz.whisky", "com.apple.gameportingtoolkit",
    ]
    /// Matched exactly or with a "." suffix, so launchers with a longer id stay out.
    static let exactIDs: [String] = ["com.gaijinent.warthunder"]

    static func isKnownGame(_ app: FrontApp) -> Bool {
        if app.categoryIsGame { return true }
        if let path = app.bundlePath, path.contains("/steamapps/common/") { return true }
        guard let id = app.bundleID?.lowercased(), !id.isEmpty else { return false }
        if exactIDs.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
        return knownPrefixes.contains { id.hasPrefix($0) }
    }
}

/// Starts, feeds and ends game sessions. O(1) per update.
struct GameTracker {
    static let knownGameMinActive = 0.25
    static let knownGameHold: TimeInterval = 15
    static let heavyMinActive = 0.75
    static let heavyHold: TimeInterval = 60
    static let idleBelow = 0.25
    static let endHold: TimeInterval = 120
    static let minDuration: TimeInterval = 120

    private(set) var current: GameSession?
    private(set) var currentPID: Int32?
    private var candidatePID: Int32?
    private var knownSustain = Sustain()
    private var heavySustain = Sustain()
    private var idleSustain = Sustain()

    init() {}

    /// Feed every tick. Returns the session that just ended when it lasted at least `minDuration`.
    mutating func update(front: FrontApp?, sessionAppRunning: Bool, snapshot: Snapshot,
                         interval: TimeInterval, gpuStuck: Bool, now: Date) -> GameSession? {
        let active = snapshot.gpuActive.flatMap { $0.isFinite ? $0 : nil } ?? 0

        if var session = current {
            guard sessionAppRunning else { return finish() }
            let idle = front?.pid != currentPID || active < GameTracker.idleBelow
            let idleFor = idleSustain.update(idle, now: now)
            if !idle {
                session.absorb(snapshot, interval: interval, gpuStuck: gpuStuck)
                current = session
            }
            return idleFor >= GameTracker.endHold ? finish() : nil
        }

        if front?.pid != candidatePID {
            candidatePID = front?.pid
            knownSustain = Sustain()
            heavySustain = Sustain()
        }
        guard let app = front else { return nil }
        let knownCondition = GameClassifier.isKnownGame(app) && active >= GameTracker.knownGameMinActive
        let heavyCondition = active >= GameTracker.heavyMinActive
        let knownHeld = knownSustain.update(knownCondition, now: now)
        let heavyHeld = heavySustain.update(heavyCondition, now: now)

        let startedAt: Date?
        if knownCondition, knownHeld >= GameTracker.knownGameHold {
            startedAt = knownSustain.since
        } else if heavyCondition, heavyHeld >= GameTracker.heavyHold {
            startedAt = heavySustain.since
        } else {
            startedAt = nil
        }
        guard let start = startedAt else { return nil }

        var session = GameSession(name: app.name, bundleID: app.bundleID, start: start)
        session.absorb(snapshot, interval: interval, gpuStuck: gpuStuck)
        current = session
        currentPID = app.pid
        idleSustain = Sustain()
        knownSustain = Sustain()
        heavySustain = Sustain()
        return nil
    }

    private mutating func finish() -> GameSession? {
        let ended = current
        current = nil
        currentPID = nil
        candidatePID = nil
        idleSustain = Sustain()
        knownSustain = Sustain()
        heavySustain = Sustain()
        guard let session = ended, session.duration >= GameTracker.minDuration else { return nil }
        return session
    }
}
