// StatusController.swift - AppDelegate, status item, colored segments, menu toggles.
import Cocoa

/// Wrapper to store a WritableKeyPath in a menu item's representedObject.
final class KeyPathBox {
    let keyPath: WritableKeyPath<Config, Bool>
    init(_ kp: WritableKeyPath<Config, Bool>) { keyPath = kp }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var config = Config.load()
    private var timer: Timer?

    private var lastCPU: Double = .nan
    private var lastGPU: Double = .nan
    private var lastPwr: Double = .nan
    private var lastRAM: Double = .nan

    // Status item is created here - after NSApplication is fully ready.
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ThermalBar"   // visible placeholder so the item isn't zero-width
        buildMenu()
        refresh()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.5, config.intervalSeconds),
                                     repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func color(_ value: Double, _ t: Thresholds) -> NSColor {
        switch value {
        case ..<t.normal: return .systemGreen
        case ..<t.warn:   return .systemOrange
        case ..<t.high:   return .systemRed
        default:          return NSColor(red: 0.55, green: 0.0, blue: 0.0, alpha: 1.0) // dark red
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sample = Sampler.read()
            DispatchQueue.main.async { self?.render(sample) }
        }
    }

    private func merge(_ new: Double, into last: inout Double) {
        if new.isFinite { last = new }
    }

    private func render(_ s: Sample?) {
        guard let item = item else { return }
        if let s = s {
            merge(s.cpuTemp, into: &lastCPU)
            merge(s.gpuTemp, into: &lastGPU)
            merge(s.power,   into: &lastPwr)
            merge(s.ramUsage, into: &lastRAM)
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        func seg(_ text: String, _ col: NSColor) {
            title.append(NSAttributedString(string: text,
                attributes: [.foregroundColor: col, .font: font]))
        }

        var parts: [(String, NSColor)] = []
        if config.cpuTemp.enabled, lastCPU.isFinite {
            let lbl = config.showLabels ? "C " : ""
            parts.append(("\(lbl)\(Int(lastCPU.rounded()))°", color(lastCPU, config.cpuTemp.thresholds)))
        }
        if config.gpuTemp.enabled, lastGPU.isFinite {
            let lbl = config.showLabels ? "G " : ""
            parts.append(("\(lbl)\(Int(lastGPU.rounded()))°", color(lastGPU, config.gpuTemp.thresholds)))
        }
        if config.power.enabled, lastPwr.isFinite {
            parts.append((String(format: "%.0fW", lastPwr), color(lastPwr, config.power.thresholds)))
        }
        if config.ram.enabled, lastRAM.isFinite {
            let lbl = config.showLabels ? "R " : ""
            parts.append(("\(lbl)\(Int(lastRAM.rounded()))%", color(lastRAM, config.ram.thresholds)))
        }

        if parts.isEmpty {
            item.button?.attributedTitle = NSAttributedString(string: "ThermalBar")
        } else {
            for (i, p) in parts.enumerated() {
                seg(p.0, p.1)
                if i < parts.count - 1 { seg("  ", .labelColor) }
            }
            item.button?.attributedTitle = title
        }
    }

    private func makeToggle(_ title: String, _ kp: WritableKeyPath<Config, Bool>) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
        mi.target = self
        mi.state = config[keyPath: kp] ? .on : .off
        mi.representedObject = KeyPathBox(kp)
        return mi
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statsItem = NSMenuItem(title: statsLine(), action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)
        menu.addItem(.separator())

        menu.addItem(makeToggle("CPU temperature", \.cpuTemp.enabled))
        menu.addItem(makeToggle("GPU temperature", \.gpuTemp.enabled))
        menu.addItem(makeToggle("Power (W)",       \.power.enabled))
        menu.addItem(makeToggle("RAM usage (%)",   \.ram.enabled))
        menu.addItem(makeToggle("Labels (C/G/R)",  \.showLabels))
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open config…", action: #selector(openConfig), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let reloadItem = NSMenuItem(title: "Reload config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    /// Reads ~/.thermal-log/thermal.csv (if a logger writes it) and shows max/avg.
    /// CSV: timestamp,cpu_temp,gpu_temp,cpu_power,gpu_power,sys_power,cpu_usage_pct
    private func statsLine() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thermal-log/thermal.csv")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return "History: no log"
        }
        var cMax = -Double.greatestFiniteMagnitude, cSum = 0.0
        var gMax = -Double.greatestFiniteMagnitude, gSum = 0.0
        var n = 0
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "\"", with: "") }
            guard f.count >= 3, let c = Double(f[1]), let g = Double(f[2]) else { continue }
            n += 1; cSum += c; gSum += g
            if c > cMax { cMax = c }
            if g > gMax { gMax = g }
        }
        guard n > 0 else { return "History: no data" }
        return String(format: "Peak/avg:  CPU %.0f°/%.0f°   GPU %.0f°/%.0f°  (n=%d)",
                      cMax, cSum/Double(n), gMax, gSum/Double(n), n)
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? KeyPathBox else { return }
        config[keyPath: box.keyPath].toggle()
        sender.state = config[keyPath: box.keyPath] ? .on : .off
        config.save()
        refresh()
    }

    @objc private func openConfig() { NSWorkspace.shared.open(Config.path) }

    @objc private func reloadConfig() {
        config = Config.load()
        buildMenu()
        scheduleTimer()
        refresh()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
