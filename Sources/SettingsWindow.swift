// SettingsWindow.swift - native settings panel: SwiftUI form hosted in an NSWindow.
// Edits a copy of Config; Save persists to config.json and applies immediately.
import Cocoa
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var config: Config
    init(_ config: Config) { self.config = config }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let onSave: (Config) -> Void
    let onCancel: () -> Void

    @State private var showError = false
    @State private var validationError = ""

    private static let metricPaths: [(String, WritableKeyPath<Config, MetricConfig>)] = [
        ("CPU temperature", \.cpuTemp),
        ("GPU temperature", \.gpuTemp),
        ("Power (W)", \.power),
        ("RAM usage (%)", \.ram),
    ]

    private func enabledBinding(_ kp: WritableKeyPath<Config, MetricConfig>) -> Binding<Bool> {
        Binding<Bool>(
            get: { model.config[keyPath: kp].enabled },
            set: { model.config[keyPath: kp].enabled = $0 }
        )
    }

    private func thresholdBinding(_ kp: WritableKeyPath<Config, MetricConfig>,
                                  _ tkp: WritableKeyPath<Thresholds, Double>) -> Binding<Double> {
        Binding<Double>(
            get: { model.config[keyPath: kp].thresholds[keyPath: tkp] },
            set: { model.config[keyPath: kp].thresholds[keyPath: tkp] = $0 }
        )
    }

    private func valueBinding(_ kp: WritableKeyPath<Config, Double>) -> Binding<Double> {
        Binding<Double>(
            get: { model.config[keyPath: kp] },
            set: { model.config[keyPath: kp] = $0 }
        )
    }

    private func boolBinding(_ kp: WritableKeyPath<Config, Bool>) -> Binding<Bool> {
        Binding<Bool>(
            get: { model.config[keyPath: kp] },
            set: { model.config[keyPath: kp] = $0 }
        )
    }

    private func thresholdField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
    }

    private func metricContent(_ kp: WritableKeyPath<Config, MetricConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show in menu bar", isOn: enabledBinding(kp))
            HStack(spacing: 6) {
                Text("green <")
                thresholdField(thresholdBinding(kp, \.normal))
                Text("≤ orange <")
                thresholdField(thresholdBinding(kp, \.warn))
                Text("≤ red <")
                thresholdField(thresholdBinding(kp, \.high))
            }
            .font(.callout)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("CPU temperature") { metricContent(\.cpuTemp) }
                Section("GPU temperature") { metricContent(\.gpuTemp) }
                Section("Power (W)") { metricContent(\.power) }
                Section("RAM usage (%)") { metricContent(\.ram) }
                Section("General") {
                    HStack {
                        Text("Refresh interval, seconds")
                        Spacer()
                        thresholdField(valueBinding(\.intervalSeconds))
                    }
                    Toggle("Show labels (C/G/R)", isOn: boolBinding(\.showLabels))
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Reset to Defaults") { model.config = Config.defaultConfig }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 460, height: 640)
        .alert("Invalid thresholds", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError)
        }
    }

    private func save() {
        var c = model.config
        if !(c.intervalSeconds >= 0.5) { c.intervalSeconds = 0.5 }
        for (name, kp) in Self.metricPaths {
            let t = c[keyPath: kp].thresholds
            guard t.normal < t.warn, t.warn < t.high else {
                validationError = "\(name): values must increase (green < orange < red)."
                showError = true
                return
            }
        }
        model.config = c
        onSave(c)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: ((Config) -> Void)?
    var onClose: (() -> Void)?

    init(config: Config) {
        let model = SettingsModel(config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ThermalBar Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = SettingsView(
            model: model,
            onSave: { [weak self] cfg in
                self?.onSave?(cfg)
                self?.close()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}
