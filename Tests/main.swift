// Tests/main.swift - dependency-free test runner for the pure ThermalBar logic.
// Build and run: ./build.sh test (or swiftc ... Tests/main.swift, see build.sh).
import Foundation

var checks = 0
var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String = "",
           file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(file):\(line) \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL \(file):\(line) \(message) - got \(actual), expected \(expected)")
    }
}

func expectNear(_ actual: Double?, _ expected: Double, tolerance: Double = 1e-9, _ message: String = "",
                file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    guard let a = actual, abs(a - expected) <= tolerance else {
        failures += 1
        print("FAIL \(file):\(line) \(message) - got \(String(describing: actual)), expected \(expected)")
        return
    }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    return c
}()

func snap(at time: Date = t0, cpu: Double? = nil, gpu: Double? = nil, power: Double? = nil,
          freq: Double? = nil, active: Double? = nil, memPercent: Double? = nil,
          mem: MemoryPressure = .normal, thermal: ThermalPressure = .nominal,
          fans: [FanReading] = [], lowPower: Bool = false) -> Snapshot {
    var s = Snapshot.empty(at: time)
    s.cpuTemp = cpu
    s.gpuTemp = gpu
    s.power = power
    s.gpuFreqMHz = freq
    s.gpuActive = active
    s.memPressurePercent = memPercent
    s.memPressure = mem
    s.thermal = thermal
    s.fans = fans
    s.lowPowerMode = lowPower
    return s
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("thermalbar-tests-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        print("FAIL cannot create temp dir: \(error)")
        failures += 1
    }
    return url
}

func files(in dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
}

// MARK: - Levels

func testLevels() {
    let t = Thresholds(warn: 70, high: 85, critical: 95)
    expectEqual(t.level(for: nil), .normal)
    expectEqual(t.level(for: .nan), .normal, "NaN is normal")
    expectEqual(t.level(for: .infinity), .normal, "infinity is not finite")
    expectEqual(t.level(for: 69.9), .normal)
    expectEqual(t.level(for: 70), .warn, "boundary is inclusive")
    expectEqual(t.level(for: 85), .high)
    expectEqual(t.level(for: 95), .critical)
    expectEqual(t.level(for: -40), .normal)

    let messy = Thresholds(warn: 200, high: 10, critical: 5).normalized(in: Thresholds.temperatureRange)
    expectEqual(messy, Thresholds(warn: 113, high: 114, critical: 115))
    let low = Thresholds(warn: 0, high: 0, critical: 0).normalized(in: Thresholds.temperatureRange)
    expectEqual(low, Thresholds(warn: 40, high: 41, critical: 42))
    let nan = Thresholds(warn: .nan, high: 80, critical: 90).normalized(in: Thresholds.temperatureRange)
    expectEqual(nan.warn, 40, "NaN falls to the bottom of the range")
    expectEqual(Thresholds.temperatureDefaults.normalized(in: Thresholds.temperatureRange),
                Thresholds.temperatureDefaults, "defaults are already valid")
    check(Level.normal < .warn && Level.high < .critical)

    expectEqual(ChipClass(chipName: "Apple M4 Max"), .max)
    expectEqual(ChipClass(chipName: "Apple M2 Ultra"), .ultra)
    expectEqual(ChipClass(chipName: "Apple M3 Pro"), .pro)
    expectEqual(ChipClass(chipName: "Apple M1"), .base)
    expectEqual(ChipClass(chipName: ""), .base)
    expectEqual(ChipClass.max.powerDefaults, Thresholds(warn: 60, high: 100, critical: 130))
    for chip in [ChipClass.base, .pro, .max, .ultra] {
        let p = chip.powerDefaults
        check(p.warn < p.high && p.high < p.critical, "power defaults ascending for \(chip)")
    }

    expectEqual(MemoryPressure(kernelLevel: 1), .normal)
    expectEqual(MemoryPressure(kernelLevel: 0), .normal)
    expectEqual(MemoryPressure(kernelLevel: -3), .normal)
    expectEqual(MemoryPressure(kernelLevel: 2), .warn)
    expectEqual(MemoryPressure(kernelLevel: 4), .critical)
    expectEqual(MemoryPressure(kernelLevel: 99), .critical)
    expectEqual(MemoryPressure.warn.level, .warn)
    expectEqual(MemoryPressure.critical.level, .critical)

    expectEqual(ThermalPressure(rawState: 0), .nominal)
    expectEqual(ThermalPressure(rawState: 2), .heavy)
    expectEqual(ThermalPressure(rawState: 1000), .sleeping, "out of range clamps to the last level")
    check(!ThermalPressure.moderate.isThrottling)
    check(ThermalPressure.heavy.isThrottling)
    expectEqual(ThermalPressure.trapping.level, .critical)
    expectEqual(ThermalPressure.moderate.level, .warn)
}

// MARK: - Config

let v1Defaults = """
{"cpuTemp":{"enabled":true,"thresholds":{"high":90,"normal":60,"warn":75}},
 "gpuTemp":{"enabled":true,"thresholds":{"high":90,"normal":60,"warn":75}},
 "intervalSeconds":3,
 "power":{"enabled":true,"thresholds":{"high":80,"normal":30,"warn":55}},
 "ram":{"enabled":true,"thresholds":{"high":95,"normal":70,"warn":85}},
 "showLabels":true}
"""

func decodeConfig(_ json: String, chip: ChipClass = .max) -> (Config, Bool)? {
    do {
        let r = try ConfigStore.decode(Data(json.utf8), chip: chip)
        return (r.config, r.migrated)
    } catch {
        print("FAIL decode threw: \(error)")
        failures += 1
        return nil
    }
}

func testConfig() {
    if let (c, migrated) = decodeConfig(v1Defaults) {
        check(migrated, "v1 is migrated")
        var expected = Config.defaults(for: .max)
        expected.intervalSeconds = 3
        expectEqual(c, expected, "v1 defaults become v2 defaults")
        expectEqual(c.power, ChipClass.max.powerDefaults)
        expectEqual(c.version, Config.currentVersion)
    }

    let custom = """
    {"cpuTemp":{"enabled":false,"thresholds":{"normal":65,"warn":80,"high":92}},
     "power":{"enabled":true,"thresholds":{"normal":40,"warn":70,"high":110}},
     "ram":{"enabled":false,"thresholds":{"normal":70,"warn":85,"high":95}},
     "showLabels":false}
    """
    if let (c, migrated) = decodeConfig(custom, chip: .pro) {
        check(migrated)
        expectEqual(c.cpuTemp, Thresholds(warn: 65, high: 80, critical: 92), "normal/warn/high -> warn/high/critical")
        expectEqual(c.power, Thresholds(warn: 40, high: 70, critical: 110))
        expectEqual(c.gpuTemp, Thresholds.temperatureDefaults, "missing metric keeps the default")
        check(!c.showCPU, "v1 enabled=false carried")
        check(!c.showMemory, "v1 ram.enabled=false -> showMemory=false")
        check(c.showGPU && c.showPower)
        check(!c.showLabels)
    }

    var v2 = Config.defaults(for: .pro)
    v2.showFans = true
    v2.layout = .twoLines
    v2.colorMode = .always
    v2.language = .english
    v2.panelTransparency = 0.5
    v2.intervalSeconds = 5
    v2.notifyGPUStuck = false
    v2.cpuTemp = Thresholds(warn: 72, high: 88, critical: 99)
    do {
        let data = try ConfigStore.encode(v2)
        let (back, migrated) = try ConfigStore.decode(data, chip: .base)
        expectEqual(back, v2, "v2 round trip")
        check(!migrated, "current format is not migrated")
    } catch {
        check(false, "v2 round trip threw \(error)")
    }

    for garbage in ["not json", "[1, 2]", "", "{\"cpuTemp\": 5}"] {
        var threw = false
        do {
            _ = try ConfigStore.decode(Data(garbage.utf8), chip: .max)
        } catch {
            threw = true
        }
        // A number where an object is expected must fail; the others are not JSON objects at all.
        check(threw, "garbage throws: \(garbage)")
    }

    let wild = """
    {"version":2,"intervalSeconds":0.2,"panelTransparency":5,
     "cpuTemp":{"warn":200,"high":10,"critical":5},"power":{"warn":-5,"high":1000,"critical":2000},
     "layout":"diagonal","language":"klingon","colorMode":"always"}
    """
    if let (c, migrated) = decodeConfig(wild) {
        check(migrated, "sanitizing counts as a change")
        expectEqual(c.intervalSeconds, 1)
        expectEqual(c.panelTransparency, Config.transparencyRange.upperBound)
        expectEqual(c.cpuTemp, Thresholds(warn: 113, high: 114, critical: 115))
        expectEqual(c.power, Thresholds(warn: 5, high: 399, critical: 400))
        expectEqual(c.layout, .singleLine, "unknown enum falls back")
        expectEqual(c.language, .system)
        expectEqual(c.colorMode, .always)
    }
    if let (c, _) = decodeConfig("{\"intervalSeconds\": 100, \"panelTransparency\": -1}") {
        expectEqual(c.intervalSeconds, 10)
        expectEqual(c.panelTransparency, 0)
    }

    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    var logs: [String] = []
    let missing = ConfigStore.load(from: url, chip: .max) { logs.append($0) }
    expectEqual(missing.config, Config.defaults(for: .max))
    check(missing.needsSave)
    check(logs.isEmpty, "a missing file is not an error")

    do {
        try Data("{{{".utf8).write(to: url)
    } catch {
        check(false, "write corrupt config: \(error)")
    }
    let corrupt = ConfigStore.load(from: url, chip: .max) { logs.append($0) }
    expectEqual(corrupt.config, Config.defaults(for: .max))
    check(corrupt.needsSave)
    check(!FileManager.default.fileExists(atPath: url.path), "corrupt file moved away")
    check(files(in: dir).contains { $0.hasPrefix("config.broken-") }, "corrupt file kept aside")
    check(logs.count == 1, "corrupt file logged once")

    do {
        try ConfigStore.save(v2, to: url)
        let loaded = ConfigStore.load(from: url, chip: .base) { logs.append($0) }
        expectEqual(loaded.config, v2)
        check(!loaded.needsSave)
    } catch {
        check(false, "save threw \(error)")
    }
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - L10n

func testL10n() {
    expectEqual(Lang.resolve(.system, preferred: ["ru-RU", "en"]), .ru)
    expectEqual(Lang.resolve(.system, preferred: ["RU"]), .ru)
    expectEqual(Lang.resolve(.system, preferred: ["en-US", "ru"]), .en)
    expectEqual(Lang.resolve(.system, preferred: ["uk-UA"]), .en)
    expectEqual(Lang.resolve(.system, preferred: []), .en)
    expectEqual(Lang.resolve(.russian, preferred: ["en"]), .ru)
    expectEqual(Lang.resolve(.english, preferred: ["ru"]), .en)

    let ru = Strings(lang: .ru)
    let en = Strings(lang: .en)
    expectEqual(ru.number(1.5, decimals: 1), "1,5", "ru uses a comma")
    expectEqual(en.number(1.5, decimals: 1), "1.5")
    expectEqual(ru.number(1234), "1234", "no grouping")
    expectEqual(ru.number(.nan), "—")
    expectEqual(ru.temperature(66.4), "66°")
    expectEqual(ru.temperature(nil), "—")
    expectEqual(en.percent(0.38), "38%")
    expectEqual(en.percent(nil), "—")
    let gib: Double = 1_073_741_824
    expectEqual(ru.gigabytes(UInt64(gib * 35.24)), "35")
    expectEqual(ru.gigabytes(UInt64(gib * 1.5)), "1,5")
    expectEqual(en.gigabytes(UInt64(gib * 1.5)), "1.5")
    expectEqual(en.gigabytes(nil), "—")
    expectEqual(ru.duration(59), ru.t(.durLessMinute))
    expectEqual(ru.duration(.infinity), ru.t(.durLessMinute))
    expectEqual(ru.duration(-10), ru.t(.durLessMinute))
    expectEqual(ru.duration(300), "5 мин")
    expectEqual(ru.duration(3600 + 12 * 60), "1 ч 12 мин")
    expectEqual(en.duration(3600 + 12 * 60), "1h 12m")
    expectEqual(ru.f(.todayMax, "92°"), "сегодня до 92°")

    func placeholders(_ s: String) -> [String] {
        ["%@", "%d"].map { token in "\(token)x\(s.components(separatedBy: token).count - 1)" }
    }
    for key in K.allCases {
        check(!ru.t(key).isEmpty, "ru text for \(key)")
        check(!en.t(key).isEmpty, "en text for \(key)")
        expectEqual(placeholders(ru.t(key)), placeholders(en.t(key)), "same placeholders for \(key)")
    }
}

// MARK: - History

func testHistory() {
    var s = Series(capacity: 3)
    for v in [1.0, 2, .nan, .infinity, 3, 4] { s.append(v) }
    s.append(nil)
    expectEqual(s.values, [2, 3, 4], "capacity kept, NaN/inf/nil ignored")
    expectEqual(s.last, 4)
    expectEqual(s.minValue, 2)
    expectEqual(s.maxValue, 4)
    var tiny = Series(capacity: 0)
    tiny.append(5)
    tiny.append(6)
    expectEqual(tiny.values, [6], "capacity is at least 1")
    expectEqual(Series(capacity: 5).last, nil)

    var trends = Trends()
    trends.absorb(snap(cpu: 50, power: 20, memPercent: 40))
    expectEqual(trends.cpu.last, 50)
    expectEqual(trends.memory.last, 40)
    check(trends.gpu.values.isEmpty, "missing GPU leaves no point")
    expectEqual(trends.cpu.capacity, Trends.capacity)

    expectEqual(DayPeaks.key(for: Date(timeIntervalSince1970: 0), calendar: utc), "1970-01-01")
    let day1 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13 UTC
    let day2 = day1.addingTimeInterval(3 * 3600)              // 2023-11-15
    var peaks = DayPeaks(day: "")
    peaks.absorb(snap(at: day1, cpu: 60, memPercent: 30, fans: [FanReading(rpm: 2000, maxRPM: 4000)]), calendar: utc)
    peaks.absorb(snap(at: day1, cpu: 70, gpu: .nan), calendar: utc)
    peaks.absorb(snap(at: day1, cpu: 65, gpu: 55), calendar: utc)
    expectEqual(peaks.day, "2023-11-14")
    expectEqual(peaks.cpu, 70)
    expectEqual(peaks.gpu, 55, "NaN ignored")
    expectEqual(peaks.memory, 30)
    expectEqual(peaks.fan, 50)
    peaks.absorb(snap(at: day2, cpu: 50), calendar: utc)
    expectEqual(peaks.day, "2023-11-15", "new day")
    expectEqual(peaks.cpu, 50)
    expectEqual(peaks.gpu, nil, "reset on a new day")

    var game = GameSession(name: "War Thunder", bundleID: "com.gaijinent.WarThunder", start: t0)
    expectEqual(game.duration, 0)
    game.absorb(snap(at: t0.addingTimeInterval(10), cpu: 70, gpu: 80, power: 90, mem: .warn, thermal: .heavy),
                interval: 2, gpuStuck: true)
    game.absorb(snap(at: t0.addingTimeInterval(12), cpu: 60, gpu: 70, power: 50), interval: 2, gpuStuck: false)
    game.absorb(snap(at: t0.addingTimeInterval(5), cpu: 99, thermal: .heavy), interval: -3, gpuStuck: true)
    expectEqual(game.maxCPU, 99)
    expectEqual(game.maxGPU, 80)
    expectEqual(game.maxPower, 90)
    expectEqual(game.throttledSeconds, 2, "negative interval adds nothing")
    expectEqual(game.gpuStuckSeconds, 2)
    expectEqual(game.worstMemory, .warn)
    expectEqual(game.end, t0.addingTimeInterval(12), "end never moves back")
    expectEqual(game.duration, 12)

    let dir = tempDir()
    let store = StateStore(url: dir.appendingPathComponent("sub/state.json"))
    var logs: [String] = []
    expectEqual(store.load { logs.append($0) }, PersistedState(), "missing file -> empty")
    check(logs.isEmpty)
    var state = PersistedState()
    state.today = peaks
    state.lastGame = game
    do {
        try store.save(state)
        expectEqual(store.load { logs.append($0) }, state, "state round trip")
        try Data("xx".utf8).write(to: store.url)
    } catch {
        check(false, "state store threw \(error)")
    }
    expectEqual(store.load { logs.append($0) }, PersistedState(), "corrupt -> empty")
    check(!FileManager.default.fileExists(atPath: store.url.path), "corrupt state moved away")
    check(files(in: store.url.deletingLastPathComponent()).contains { $0.hasPrefix("state.broken-") })
    expectEqual(logs.count, 1)
    check(StateStore.defaultURL.path.hasSuffix("Application Support/ThermalBar/state.json"))
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Detectors

func testDetectors() {
    var sustain = Sustain()
    expectEqual(sustain.update(true, now: t0), 0)
    expectEqual(sustain.update(true, now: t0.addingTimeInterval(5)), 5)
    expectEqual(sustain.update(false, now: t0.addingTimeInterval(6)), 0)
    expectEqual(sustain.since, nil)
    expectEqual(sustain.update(true, now: t0.addingTimeInterval(7)), 0)
    expectEqual(sustain.update(true, now: t0.addingTimeInterval(6)), 0, "clock going back never goes negative")

    let maxMHz = 1578.0
    let stuck = snap(gpu: 70, freq: 338, active: 0.95)
    check(GPUStuck.looksStuck(stuck, maxMHz: maxMHz), "busy GPU at 338 MHz is stuck")
    var moderate = stuck
    moderate.thermal = .moderate
    check(GPUStuck.looksStuck(moderate, maxMHz: maxMHz), "moderate heat does not explain it")
    var s = stuck
    s.gpuActive = 0.5
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "not busy")
    s = stuck
    s.gpuFreqMHz = 1400
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "high clock")
    s = stuck
    s.thermal = .heavy
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "throttling explains it")
    s = stuck
    s.gpuTemp = 90
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "hot GPU explains it")
    s = stuck
    s.lowPowerMode = true
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "Low Power Mode explains it")
    check(!GPUStuck.looksStuck(stuck, maxMHz: 0), "unknown max clock")
    check(!GPUStuck.looksStuck(stuck, maxMHz: .nan), "NaN max clock")
    s = stuck
    s.gpuFreqMHz = nil
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "missing clock")
    s = stuck
    s.gpuActive = nil
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "missing load")
    s = stuck
    s.gpuFreqMHz = 0
    check(!GPUStuck.looksStuck(s, maxMHz: maxMHz), "zero clock is a glitch, not stuck")
    s = stuck
    s.gpuTemp = nil
    check(GPUStuck.looksStuck(s, maxMHz: maxMHz), "missing temperature does not block")

    var engine = AlertEngine()
    let all = Set(AlertKind.allCases)
    let mem: [AlertKind: Bool] = [.memory: true]
    expectEqual(engine.evaluate(conditions: mem, enabled: all, now: t0), [])
    expectEqual(engine.evaluate(conditions: mem, enabled: all, now: t0.addingTimeInterval(10)), [])
    expectEqual(engine.evaluate(conditions: mem, enabled: all, now: t0.addingTimeInterval(20)), [.memory])
    expectEqual(engine.evaluate(conditions: mem, enabled: all, now: t0.addingTimeInterval(22)), [], "once per streak")
    expectNear(engine.heldFor(.memory, now: t0.addingTimeInterval(22)), 22)
    expectEqual(engine.evaluate(conditions: [:], enabled: all, now: t0.addingTimeInterval(30)), [])
    expectEqual(engine.heldFor(.memory, now: t0.addingTimeInterval(30)), 0)
    _ = engine.evaluate(conditions: mem, enabled: all, now: t0.addingTimeInterval(40))
    expectEqual(engine.evaluate(conditions: mem, enabled: all, now: t0.addingTimeInterval(60)), [], "cooldown")
    expectEqual(engine.evaluate(conditions: mem, enabled: all, now: t0.addingTimeInterval(20 + 1800)),
                [.memory], "fires once the cooldown is over")

    var engine2 = AlertEngine()
    let noThrottle = all.subtracting([.throttle])
    let thr: [AlertKind: Bool] = [.throttle: true]
    _ = engine2.evaluate(conditions: thr, enabled: noThrottle, now: t0)
    expectEqual(engine2.evaluate(conditions: thr, enabled: noThrottle, now: t0.addingTimeInterval(15)), [],
                "disabled kind stays quiet")
    expectNear(engine2.heldFor(.throttle, now: t0.addingTimeInterval(15)), 15, "still tracked while disabled")
    expectEqual(engine2.evaluate(conditions: thr, enabled: all, now: t0.addingTimeInterval(16)), [.throttle],
                "enabling mid-streak fires")
    let both: [AlertKind: Bool] = [.memory: true, .gpuStuck: true]
    var engine3 = AlertEngine()
    _ = engine3.evaluate(conditions: both, enabled: all, now: t0)
    expectEqual(engine3.evaluate(conditions: both, enabled: all, now: t0.addingTimeInterval(44)), [.memory])
    expectEqual(engine3.evaluate(conditions: both, enabled: all, now: t0.addingTimeInterval(45)), [.gpuStuck])
    expectEqual(AlertKind.throttle.holdSeconds, 10)
    expectEqual(AlertKind.gpuStuck.cooldown, 7200)

    let cfg = Config.defaults(for: .max)
    expectEqual(PanelStatus.evaluate(snapshot: nil, config: cfg, gpuStuck: true), .starting)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 99, mem: .critical, thermal: .heavy), config: cfg,
                                     gpuStuck: true), .gpuStuck)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 99, mem: .critical, thermal: .heavy), config: cfg,
                                     gpuStuck: false), .throttling)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 99, mem: .warn), config: cfg, gpuStuck: false), .memory)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 90), config: cfg, gpuStuck: false), .hot)
    expectEqual(PanelStatus.evaluate(snapshot: snap(power: 140), config: cfg, gpuStuck: false), .hot)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 75), config: cfg, gpuStuck: false), .warm)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 40, thermal: .moderate), config: cfg, gpuStuck: false), .warm)
    expectEqual(PanelStatus.evaluate(snapshot: snap(cpu: 40, gpu: 45, power: 20), config: cfg, gpuStuck: false), .calm)
    expectEqual(PanelStatus.evaluate(snapshot: snap(), config: cfg, gpuStuck: false), .calm, "no readings is calm")
    expectEqual(PanelStatus.gpuStuck.level, .high)
    expectEqual(PanelStatus.calm.key, .statusCalm)
    expectEqual(PanelStatus.starting.key, .statusStarting)
}

// MARK: - Processes

func testProcesses() {
    let ps = """
      123   5.3  45678 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
     456 0,5 100 /usr/sbin/cfprefsd
    junk line
     -1 2.0 10 /bin/x
     789 abc 10 /bin/y
     10 1.0 20

      42 12.0 2048 kernel_task  \t
     77 3.0 99999999999999999999 /bin/huge
    """
    let samples = ProcessParser.parse(ps)
    expectEqual(samples.count, 3, "junk, bad pid, bad cpu, missing path and overflowing rss skipped")
    if samples.count == 3 {
        expectEqual(samples[0], ProcessSample(pid: 123, cpuPercent: 5.3, rssBytes: 45678 * 1024,
                                              path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
        expectEqual(samples[1].cpuPercent, 0.5, "comma decimal accepted")
        expectEqual(samples[1].rssBytes, 100 * 1024)
        expectEqual(samples[2].path, "kernel_task", "trailing whitespace trimmed")
    }
    expectEqual(ProcessParser.parse(""), [])

    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
        + "Versions/131.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    let chrome = ProcessParser.appIdentity(forExecutable: helper)
    expectEqual(chrome.name, "Google Chrome", "helper folds into the outer app")
    expectEqual(chrome.appPath, "/Applications/Google Chrome.app")
    expectEqual(chrome.id, "/Applications/Google Chrome.app")
    let wt = ProcessParser.appIdentity(
        forExecutable: "/Applications/WarThunderLauncher.app/Contents/WarThunder.app/Contents/MacOS/aces")
    expectEqual(wt.name, "WarThunder", "app placed in Contents is its own app")
    expectEqual(wt.appPath, "/Applications/WarThunderLauncher.app/Contents/WarThunder.app")
    let sim = ProcessParser.appIdentity(
        forExecutable: "/Applications/Xcode.app/Contents/Applications/Simulator.app/Contents/MacOS/Simulator")
    expectEqual(sim.name, "Simulator")
    let login = ProcessParser.appIdentity(
        forExecutable: "/Applications/Slack.app/Contents/Library/LoginItems/Slack Login.app/Contents/MacOS/x")
    expectEqual(login.name, "Slack", "login items fold in")
    let plain = ProcessParser.appIdentity(forExecutable: "/usr/sbin/cfprefsd")
    expectEqual(plain.name, "cfprefsd")
    expectEqual(plain.appPath, nil)
    expectEqual(plain.id, "/usr/sbin/cfprefsd")
    expectEqual(ProcessParser.appIdentity(forExecutable: "kernel_task").name, "kernel_task")
    expectEqual(ProcessParser.appIdentity(forExecutable: "/tmp/.app/x").appPath, nil, "bare .app is not a bundle")

    let grouped = ProcessParser.group([
        ProcessSample(pid: 1, cpuPercent: 5, rssBytes: 500, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ProcessSample(pid: 2, cpuPercent: 10, rssBytes: 700, path: helper),
        ProcessSample(pid: 3, cpuPercent: 0, rssBytes: 300, path: "/usr/sbin/cfprefsd"),
        ProcessSample(pid: 4, cpuPercent: 30, rssBytes: 0, path: "/Applications/WarThunderLauncher.app/Contents/WarThunder.app/Contents/MacOS/aces"),
    ]) { pid in pid == 1 ? 1000 : nil }
    expectEqual(grouped.count, 3)
    let chromeUsage = grouped.first { $0.name == "Google Chrome" }
    expectEqual(chromeUsage?.cpuPercent, 15, "CPU summed over helpers")
    expectEqual(chromeUsage?.memoryBytes, 1700, "footprint where readable, RSS otherwise")
    let overflow = ProcessParser.group([
        ProcessSample(pid: 1, cpuPercent: 1, rssBytes: UInt64.max, path: "/a"),
        ProcessSample(pid: 2, cpuPercent: 1, rssBytes: 10, path: "/a"),
    ]) { _ in nil }
    expectEqual(overflow.first?.memoryBytes, UInt64.max, "memory sum saturates")

    let byCPU = ProcessParser.top(grouped, byMemory: false, count: 2)
    expectEqual(byCPU.map(\.name), ["WarThunder", "Google Chrome"])
    let byMem = ProcessParser.top(grouped, byMemory: true, count: 5)
    expectEqual(byMem.map(\.name), ["Google Chrome", "cfprefsd"], "zero memory left out")
    expectEqual(ProcessParser.top(grouped, byMemory: false, count: 0), [])
    expectEqual(ProcessParser.top(grouped, byMemory: false, count: -1), [])
    expectEqual(ProcessParser.top([], byMemory: true, count: 3), [])
    let ties = [AppUsage(id: "b", name: "Beta", appPath: nil, cpuPercent: 5, memoryBytes: 1),
                AppUsage(id: "a", name: "alpha", appPath: nil, cpuPercent: 5, memoryBytes: 1)]
    expectEqual(ProcessParser.top(ties, byMemory: false, count: 2).map(\.name), ["alpha", "Beta"], "ties by name")
}

// MARK: - Games

func testGames() {
    let wt = FrontApp(name: "War Thunder", bundleID: "com.gaijinent.WarThunder",
                      bundlePath: "/Applications/WarThunderLauncher.app/Contents/WarThunder.app",
                      categoryIsGame: false, pid: 100)
    check(GameClassifier.isKnownGame(wt), "War Thunder is a game")
    var launcher = wt
    launcher.bundleID = "com.gaijinent.WarThunderDL"
    launcher.bundlePath = "/Applications/WarThunderLauncher.app"
    check(!GameClassifier.isKnownGame(launcher), "the launcher is not a game")
    let steam = FrontApp(name: "Hades", bundleID: "com.supergiant.hades",
                         bundlePath: "/Users/x/Library/Application Support/Steam/steamapps/common/Hades/Hades.app",
                         categoryIsGame: false, pid: 5)
    check(GameClassifier.isKnownGame(steam), "Steam library path")
    let category = FrontApp(name: "Chess", bundleID: "com.apple.Chess", bundlePath: nil, categoryIsGame: true, pid: 6)
    check(GameClassifier.isKnownGame(category))
    let crossover = FrontApp(name: "CrossOver", bundleID: "com.codeweavers.CrossOver", bundlePath: nil,
                             categoryIsGame: false, pid: 7)
    check(GameClassifier.isKnownGame(crossover), "case-insensitive prefix")
    let safari = FrontApp(name: "Safari", bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app",
                          categoryIsGame: false, pid: 8)
    check(!GameClassifier.isKnownGame(safari))
    let bare = FrontApp(name: "x", bundleID: nil, bundlePath: nil, categoryIsGame: false, pid: 9)
    check(!GameClassifier.isKnownGame(bare))
    let empty = FrontApp(name: "x", bundleID: "", bundlePath: nil, categoryIsGame: false, pid: 9)
    check(!GameClassifier.isKnownGame(empty))

    // Start by a known game, end when it quits.
    var tracker = GameTracker()
    var finished: GameSession?
    func tick(_ t: inout GameTracker, _ second: Double, front: FrontApp?, active: Double?,
              running: Bool = true, stuck: Bool = false, cpu: Double? = 60) -> GameSession? {
        let time = t0.addingTimeInterval(second)
        return t.update(front: front, sessionAppRunning: running, snapshot: snap(at: time, cpu: cpu, active: active),
                        interval: 5, gpuStuck: stuck, now: time)
    }
    for sec in stride(from: 0.0, through: 10, by: 5) {
        expectEqual(tick(&tracker, sec, front: wt, active: 0.3), nil)
    }
    check(tracker.current == nil, "not started before 15 s")
    _ = tick(&tracker, 15, front: wt, active: 0.3)
    expectEqual(tracker.current?.name, "War Thunder", "known game starts after 15 s")
    expectEqual(tracker.current?.start, t0, "start = when the condition began")
    expectEqual(tracker.currentPID, 100)
    for sec in stride(from: 20.0, through: 200, by: 5) {
        expectEqual(tick(&tracker, sec, front: wt, active: 0.9, stuck: sec >= 100, cpu: sec == 150 ? 95 : 70), nil)
    }
    finished = tick(&tracker, 205, front: nil, active: 0, running: false)
    expectEqual(finished?.duration, 200, "ends at the last active reading when the app quits")
    expectEqual(finished?.maxCPU, 95)
    expectEqual(finished?.gpuStuckSeconds, 105, "21 stuck ticks of 5 s")
    check(tracker.current == nil && tracker.currentPID == nil, "tracker reset")

    // Start by heavy GPU in any app, end after 120 s of idle.
    var heavy = GameTracker()
    let fcp = FrontApp(name: "Final Cut Pro", bundleID: "com.apple.FinalCut", bundlePath: nil,
                       categoryIsGame: false, pid: 200)
    for sec in stride(from: 0.0, through: 55, by: 5) {
        _ = tick(&heavy, sec, front: fcp, active: 0.3)
    }
    check(heavy.current == nil, "low load in a non-game never starts")
    for sec in stride(from: 60.0, through: 115, by: 5) {
        _ = tick(&heavy, sec, front: fcp, active: 0.8)
    }
    check(heavy.current == nil, "heavy load needs 60 s")
    _ = tick(&heavy, 120, front: fcp, active: 0.8)
    expectEqual(heavy.current?.name, "Final Cut Pro", "heavy GPU starts after 60 s")
    expectEqual(heavy.current?.start, t0.addingTimeInterval(60))
    for sec in stride(from: 125.0, through: 300, by: 5) {
        _ = tick(&heavy, sec, front: fcp, active: 0.8)
    }
    var ended: GameSession?
    for sec in stride(from: 305.0, through: 420, by: 5) {
        if let s = tick(&heavy, sec, front: fcp, active: 0.1) { ended = s }
    }
    expectEqual(ended, nil, "still within the 120 s grace")
    ended = tick(&heavy, 425, front: fcp, active: 0.1)
    expectEqual(ended?.end, t0.addingTimeInterval(300), "end = last active reading")
    expectEqual(ended?.duration, 240)
    check(heavy.current == nil)

    // Alt-tab away and back inside the grace keeps the session.
    var altTab = GameTracker()
    for sec in stride(from: 0.0, through: 15, by: 5) { _ = tick(&altTab, sec, front: wt, active: 0.5) }
    check(altTab.current != nil)
    for sec in stride(from: 20.0, through: 100, by: 5) { _ = tick(&altTab, sec, front: safari, active: 0.5) }
    _ = tick(&altTab, 105, front: wt, active: 0.5)
    check(altTab.current != nil, "coming back within 120 s keeps the session")
    expectEqual(altTab.current?.end, t0.addingTimeInterval(105))

    // Too short to keep.
    var short = GameTracker()
    for sec in stride(from: 0.0, through: 55, by: 5) { _ = tick(&short, sec, front: wt, active: 0.5) }
    check(short.current != nil)
    expectEqual(tick(&short, 60, front: nil, active: 0, running: false), nil, "sessions under 120 s are dropped")
    check(short.current == nil)

    // Switching apps during the warm-up restarts the count.
    var flip = GameTracker()
    var other = wt
    other.pid = 101
    for (i, sec) in stride(from: 0.0, through: 40, by: 5).enumerated() {
        _ = tick(&flip, sec, front: i % 2 == 0 ? wt : other, active: 0.5)
    }
    check(flip.current == nil, "a different pid restarts the warm-up")
    _ = tick(&flip, 45, front: nil, active: 0.9)
    check(flip.current == nil, "no front app never starts")
}

testLevels()
testConfig()
testL10n()
testHistory()
testDetectors()
testProcesses()
testGames()

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
