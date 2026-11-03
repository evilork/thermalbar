// SettingsView.swift - the settings window. Every control binds straight to the model,
// which sanitizes, saves and applies the change at once (no Save button).
import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case menuBar
    case thresholds
    case alerts
    case general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: SettingsTab

    private static let projectURL = URL(string: "https://github.com/evilork/thermalbar")

    init(model: AppModel, initialTab: SettingsTab = .menuBar) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    private var s: Strings { model.strings }

    var body: some View {
        TabView(selection: $tab) {
            menuBarTab
                .tabItem { Label(s.t(.tabMenuBar), systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menuBar)
            thresholdsTab
                .tabItem { Label(s.t(.tabThresholds), systemImage: "thermometer.medium") }
                .tag(SettingsTab.thresholds)
            alertsTab
                .tabItem { Label(s.t(.tabAlerts), systemImage: "bell") }
                .tag(SettingsTab.alerts)
            generalTab
                .tabItem { Label(s.t(.tabGeneral), systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .padding(.top, 8)
        .frame(width: 460, height: 520)
    }

    // MARK: Menu bar

    private var menuBarTab: some View {
        Form {
            Section {
                Toggle(s.t(.showCPU), isOn: $model.config.showCPU)
                Toggle(s.t(.showGPU), isOn: $model.config.showGPU)
                Toggle(s.t(.showPower), isOn: $model.config.showPower)
                Toggle(s.t(.showMemory), isOn: $model.config.showMemory)
                Toggle(s.t(.showFans), isOn: $model.config.showFans)
            }
            Section {
                Toggle(s.t(.showLabels), isOn: $model.config.showLabels)
                    .disabled(model.config.layout == .twoLines)
                Picker(s.t(.layout), selection: $model.config.layout) {
                    Text(s.t(.layoutSingle)).tag(BarLayout.singleLine)
                    Text(s.t(.layoutTwo)).tag(BarLayout.twoLines)
                }
                Picker(s.t(.colorMode), selection: $model.config.colorMode) {
                    Text(s.t(.colorWhenHot)).tag(ColorMode.whenHot)
                    Text(s.t(.colorAlways)).tag(ColorMode.always)
                }
            } footer: {
                Footnote(text: s.t(.menuBarPreviewNote))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Thresholds

    private var thresholdsTab: some View {
        Form {
            Section {
                thresholdRows($model.config.cpuTemp, step: 1, range: Thresholds.temperatureRange, unit: "°")
            } header: {
                Text(s.t(.sectionCPU))
            } footer: {
                Footnote(text: s.t(.thresholdsNote))
            }
            Section {
                thresholdRows($model.config.gpuTemp, step: 1, range: Thresholds.temperatureRange, unit: "°")
            } header: {
                Text(s.t(.sectionGPU))
            }
            Section {
                thresholdRows($model.config.power, step: 5, range: Thresholds.powerRange, unit: " " + s.t(.unitW))
            } header: {
                Text(s.t(.sectionPower))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Footnote(text: s.t(.memoryNote))
                    Footnote(text: s.t(.fanNote))
                }
            }
            Section {
                Button(s.f(.resetDefaults, model.chipName)) {
                    model.resetThresholdsToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func thresholdRows(_ binding: Binding<Thresholds>, step: Double,
                               range: ClosedRange<Double>, unit: String) -> some View {
        ThresholdStepper(label: s.t(.warnFrom), swatch: .warn, value: binding.warn,
                         step: step, range: range, unit: unit, strings: s)
        ThresholdStepper(label: s.t(.highFrom), swatch: .high, value: binding.high,
                         step: step, range: range, unit: unit, strings: s)
        ThresholdStepper(label: s.t(.criticalFrom), swatch: .critical, value: binding.critical,
                         step: step, range: range, unit: unit, strings: s)
    }

    // MARK: Notifications

    private var alertsTab: some View {
        Form {
            Section {
                Toggle(s.t(.notifyMemory), isOn: $model.config.notifyMemory)
                Toggle(s.t(.notifyThrottle), isOn: $model.config.notifyThrottle)
                Toggle(s.t(.notifyGPUStuck), isOn: $model.config.notifyGPUStuck)
            } footer: {
                Footnote(text: s.t(.notifyNote))
            }
            Section {
                Button(s.t(.notifyTest)) {
                    model.sendTestNotification()
                }
                if model.notificationsDenied {
                    Text(s.t(.notifyDenied))
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: General

    private var intervalChoices: [Double] {
        var list = Config.intervalChoices
        if !list.contains(model.config.intervalSeconds) {
            list.append(model.config.intervalSeconds)
            list.sort()
        }
        return list
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker(s.t(.language), selection: $model.config.language) {
                    Text(s.t(.langSystem)).tag(LanguagePref.system)
                    Text("Русский").tag(LanguagePref.russian)
                    Text("English").tag(LanguagePref.english)
                }
                Picker(s.t(.interval), selection: $model.config.intervalSeconds) {
                    ForEach(intervalChoices, id: \.self) { seconds in
                        Text(s.f(.intervalValue, Int(seconds))).tag(seconds)
                    }
                }
                HStack(spacing: 10) {
                    Text(s.t(.transparency))
                    Slider(value: $model.config.panelTransparency, in: Config.transparencyRange)
                    Text(s.percent(model.config.panelTransparency))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle(s.t(.launchAtLogin), isOn: $model.launchAtLogin)
            }
            Section {
                HStack {
                    Text(s.f(.version, model.appVersion))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let url = Self.projectURL {
                        Link(s.t(.projectPage), destination: url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Building blocks

private struct Footnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ThresholdStepper: View {
    let label: String
    let swatch: Level
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let unit: String
    let strings: Strings

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(spacing: 8) {
                LevelSwatch(level: swatch)
                Text(label)
                Spacer(minLength: 8)
                Text(strings.number(value) + unit)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A small sample of how the menu bar shows a level: orange text, red text, red badge.
private struct LevelSwatch: View {
    let level: Level

    var body: some View {
        Group {
            if level == .critical {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.red)
                    .frame(width: 16, height: 11)
            } else {
                Circle()
                    .fill(level == .warn ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
                    .frame(width: 16)
            }
        }
    }
}
