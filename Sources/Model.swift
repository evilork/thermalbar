// Model.swift - the app state. Sensors are read on a background queue; everything published
// here changes on the main queue only.
import AppKit
import Combine
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var trends = Trends()
    @Published private(set) var today: DayPeaks
    @Published private(set) var lastGame: GameSession?
    @Published private(set) var currentGame: GameSession?
    @Published private(set) var topCPU: [AppUsage] = []
    @Published private(set) var topMemory: [AppUsage] = []
    @Published private(set) var status: PanelStatus = .starting
    @Published private(set) var gpuStuck = false
    @Published private(set) var strings: Strings
    @Published private(set) var notificationsDenied = false
    /// 0 until the first reading (and when the chip does not report a GPU frequency table).
    @Published private(set) var gpuMaxMHz: Double = 0
    @Published var config: Config {
        didSet { configDidChange(from: oldValue) }
    }
    @Published var launchAtLogin: Bool {
        didSet { launchAtLoginDidChange(from: oldValue) }
    }

    let chipName: String
    let chipClass: ChipClass
    let appVersion: String

    /// Called on the main queue after every reading and settings change (the menu bar redraws).
    var onUpdate: (() -> Void)?

    /// Top apps are sampled only while the panel is visible.
    var panelOpen = false {
        didSet { if panelOpen, !oldValue { refreshTopApps() } }
    }

    private let log: (String) -> Void
    private let configURL: URL
    private let stateStore: StateStore
    private let notifier: Notifier
    private let processSampler = ProcessSampler()
    private let sensorQueue = DispatchQueue(label: "com.evilork.thermalbar.sensors", qos: .utility)
    private let processQueue = DispatchQueue(label: "com.evilork.thermalbar.processes", qos: .utility)
    /// Created, read and closed only on `sensorQueue`.
    private var probe: SystemProbe?
    private var timer: Timer?
    private var alertEngine = AlertEngine()
    private var stuckSustain = Sustain()
    private var tracker = GameTracker()
    private var categoryCache: [String: Bool] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var lastStateSave = Date.distantPast
    private var lastReading: Date?
    private var sampleInFlight = false
    private var processesInFlight = false
    private var applyingConfig = false
    private var applyingLogin = false
    /// README preview mode: only system processes in the top lists (no personal app names).
    private let systemAppsOnly: Bool

    init(log: @escaping (String) -> Void = Log.sink,
         configURL: URL = ConfigStore.defaultURL,
         stateStore: StateStore = StateStore(url: StateStore.defaultURL),
         previewMode: Bool = false) {
        self.log = log
        self.configURL = configURL
        self.stateStore = stateStore
        systemAppsOnly = previewMode
        chipName = SystemProbe.chipName()
        chipClass = ChipClass(chipName: chipName)
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"

        let firstRun = !FileManager.default.fileExists(atPath: configURL.path)
        let loaded = ConfigStore.load(from: configURL, chip: chipClass, log: log)
        config = loaded.config
        strings = Strings(lang: Lang.resolve(loaded.config.language))

        let state = stateStore.load(log: log)
        let todayKey = DayPeaks.key(for: Date())
        if let saved = state.today, saved.day == todayKey {
            today = saved
        } else {
            today = DayPeaks(day: todayKey)
        }
        lastGame = state.lastGame
        notifier = Notifier(log: log)
        launchAtLogin = LoginItem.isEnabled()

        if loaded.needsSave { saveConfig() }
        // A fresh install from the zip should behave like install.sh: start with the Mac.
        if firstRun, !previewMode, !launchAtLogin, Bundle.main.bundlePath.hasPrefix("/Applications/") {
            launchAtLogin = true
            launchAtLoginDidChange(from: false)
        }
        notifier.onDeniedChange = { [weak self] denied in
            guard let self, self.notificationsDenied != denied else { return }
            self.notificationsDenied = denied
        }
    }

    // MARK: - Lifecycle

    func start(requestNotifications: Bool = true) {
        if requestNotifications { notifier.requestAuthorization() }
        scheduleTimer()
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        saveState()
        sensorQueue.sync {
            probe?.close()
            probe = nil
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = config.intervalSeconds
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while a menu is open
        timer = t
    }

    private func tick() {
        if panelOpen { refreshTopApps() }
        guard !sampleInFlight else { return }
        sampleInFlight = true
        let log = self.log
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let probe: SystemProbe
            if let existing = self.probe {
                probe = existing
            } else {
                probe = SystemProbe(log: log)
                self.probe = probe
            }
            let reading = probe.read()
            let maxMHz = probe.gpuMaxMHz
            DispatchQueue.main.async {
                self.sampleInFlight = false
                self.process(reading, gpuMaxMHz: maxMHz)
            }
        }
    }

    // MARK: - Processing (main queue)

    private func process(_ s: Snapshot, gpuMaxMHz maxMHz: Double) {
        let now = s.time
        let interval = lastReading.map { min(max(now.timeIntervalSince($0), 0), 30) } ?? config.intervalSeconds
        lastReading = now
        if gpuMaxMHz != maxMHz { gpuMaxMHz = maxMHz }

        var newTrends = trends
        newTrends.absorb(s)
        trends = newTrends
        var peaks = today
        peaks.absorb(s)
        today = peaks

        let looksStuck = GPUStuck.looksStuck(s, maxMHz: maxMHz)
        let stuck = stuckSustain.update(looksStuck, now: now) >= GPUStuck.holdSeconds
        if gpuStuck != stuck { gpuStuck = stuck }

        let running = tracker.currentPID.map(isRunning(pid:)) ?? true
        if let finished = tracker.update(front: frontApp(), sessionAppRunning: running, snapshot: s,
                                         interval: interval, gpuStuck: stuck, now: now) {
            lastGame = finished
            log("game: finished \(finished.name) after \(Int(finished.duration)) s")
            saveState()
        }
        if currentGame != tracker.current { currentGame = tracker.current }

        let newStatus = PanelStatus.evaluate(snapshot: s, config: config, gpuStuck: stuck)
        if status != newStatus { status = newStatus }
        snapshot = s

        var enabled = Set<AlertKind>()
        if config.notifyMemory { enabled.insert(.memory) }
        if config.notifyThrottle { enabled.insert(.throttle) }
        if config.notifyGPUStuck { enabled.insert(.gpuStuck) }
        let conditions: [AlertKind: Bool] = [
            .memory: s.memPressure >= .warn,
            .throttle: s.thermal.isThrottling,
            .gpuStuck: looksStuck,
        ]
        for kind in alertEngine.evaluate(conditions: conditions, enabled: enabled, now: now) {
            notify(kind, snapshot: s, maxMHz: maxMHz)
        }

        if now.timeIntervalSince(lastStateSave) >= 60 { saveState() }
        onUpdate?()
    }

    private func notify(_ kind: AlertKind, snapshot s: Snapshot, maxMHz: Double) {
        log("alert: \(kind.rawValue)")
        let t = strings
        switch kind {
        case .memory:
            processQueue.async { [weak self] in
                guard let self else { return }
                let top = ProcessParser.top(self.processSampler.sample(), byMemory: true, count: 1).first
                DispatchQueue.main.async {
                    let body = top.map { t.f(.nMemoryBody, $0.name) } ?? t.t(.nMemoryBodyNoApp)
                    self.notifier.post(id: kind.rawValue, title: t.t(.nMemoryTitle), body: body)
                }
            }
        case .throttle:
            notifier.post(id: kind.rawValue, title: t.t(.nThrottleTitle),
                          body: t.f(.nThrottleBody, t.temperature(s.cpuTemp), t.temperature(s.gpuTemp)))
        case .gpuStuck:
            notifier.post(id: kind.rawValue, title: t.t(.nGPUStuckTitle),
                          body: t.f(.nGPUStuckBody, t.number(s.gpuFreqMHz ?? 0), t.number(maxMHz)))
        }
    }

    private func refreshTopApps() {
        guard !processesInFlight else { return }
        processesInFlight = true
        processQueue.async { [weak self] in
            guard let self else { return }
            var apps = self.processSampler.sample()
            if self.systemAppsOnly { apps = apps.filter(AppModel.isSystemApp) }
            let cpu = ProcessParser.top(apps, byMemory: false, count: 3)
            let memory = ProcessParser.top(apps, byMemory: true, count: 3)
            DispatchQueue.main.async {
                self.processesInFlight = false
                let readableCPU = cpu.map(self.readable)
                let readableMemory = memory.map(self.readable)
                if self.topCPU != readableCPU { self.topCPU = readableCPU }
                if self.topMemory != readableMemory { self.topMemory = readableMemory }
            }
        }
    }

    /// ps counts one core as 100%; the panel shows a share of the whole processor instead.
    private let coreCount = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    /// Friendlier names for processes without an app bundle, CPU as a share of all cores.
    private func readable(_ app: AppUsage) -> AppUsage {
        var name = app.name
        if app.name == "com.apple.WebKit.WebContent" {
            name = strings.t(.webPages)  // Safari and every app that shows web pages
        } else if app.id.contains("/Android/sdk/emulator/") {
            name = strings.t(.androidEmulator)
        } else if app.name.hasPrefix("com.apple.DriverKit-"), app.name.count > 20 {
            name = String(app.name.dropFirst(20))
        }
        let share = min(max(app.cpuPercent / coreCount, 0), 100)
        return AppUsage(id: app.id, name: name, appPath: app.appPath,
                        cpuPercent: share, memoryBytes: app.memoryBytes)
    }

    private static func isSystemApp(_ app: AppUsage) -> Bool {
        let path = app.appPath ?? app.id
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path == "kernel_task" || path.hasPrefix("/Applications/Safari.app")
    }

    // MARK: - Front app / games

    private func frontApp() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let path = app.bundleURL?.path
        return FrontApp(name: app.localizedName ?? app.bundleIdentifier ?? "App",
                        bundleID: app.bundleIdentifier,
                        bundlePath: path,
                        categoryIsGame: path.map(isGameCategory(bundlePath:)) ?? false,
                        pid: app.processIdentifier)
    }

    private func isGameCategory(bundlePath: String) -> Bool {
        if let cached = categoryCache[bundlePath] { return cached }
        let category = Bundle(path: bundlePath)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
        let isGame = category.hasPrefix("public.app-category.") && category.contains("games")
        if categoryCache.count > 256 { categoryCache.removeAll() }
        categoryCache[bundlePath] = isGame
        return isGame
    }

    private func isRunning(pid: Int32) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) { return !app.isTerminated }
        return kill(pid, 0) == 0
    }

    // MARK: - Settings

    private func configDidChange(from old: Config) {
        guard !applyingConfig else { return }
        let clean = config.sanitized()
        if clean != config {
            applyingConfig = true
            config = clean
            applyingConfig = false
        }
        guard config != old else { return }
        saveConfig()
        if config.language != old.language { strings = Strings(lang: Lang.resolve(config.language)) }
        if config.intervalSeconds != old.intervalSeconds, timer != nil { scheduleTimer() }
        if let s = snapshot {
            let newStatus = PanelStatus.evaluate(snapshot: s, config: config, gpuStuck: gpuStuck)
            if status != newStatus { status = newStatus }
        }
        onUpdate?()
    }

    private func launchAtLoginDidChange(from old: Bool) {
        guard !applyingLogin, launchAtLogin != old else { return }
        do {
            try LoginItem.setEnabled(launchAtLogin, appPath: Bundle.main.bundlePath)
            log("login item: \(launchAtLogin ? "on" : "off")")
        } catch {
            log("login item: cannot change: \(error.localizedDescription)")
            applyingLogin = true
            launchAtLogin = old
            applyingLogin = false
        }
    }

    func resetThresholdsToDefaults() {
        let d = Config.defaults(for: chipClass)
        var c = config
        c.cpuTemp = d.cpuTemp
        c.gpuTemp = d.gpuTemp
        c.power = d.power
        config = c
    }

    func sendTestNotification() {
        notifier.requestAuthorization()
        notifier.post(id: "test", title: strings.t(.nTestTitle), body: strings.t(.nTestBody))
    }

    func icon(forAppPath path: String?) -> NSImage {
        let key = path ?? ""
        if let cached = iconCache[key] { return cached }
        let source: NSImage
        if let path, FileManager.default.fileExists(atPath: path) {
            source = NSWorkspace.shared.icon(forFile: path)
        } else {
            source = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 32, height: 32)
        if iconCache.count > 64 { iconCache.removeAll() }
        iconCache[key] = image
        return image
    }

    // MARK: - Persistence

    private func saveConfig() {
        do {
            try ConfigStore.save(config, to: configURL)
        } catch {
            log("config: cannot save: \(error.localizedDescription)")
        }
    }

    private func saveState() {
        var state = PersistedState()
        state.today = today
        state.lastGame = lastGame
        do {
            try stateStore.save(state)
            lastStateSave = Date()
        } catch {
            log("state: cannot save: \(error.localizedDescription)")
        }
    }
}
