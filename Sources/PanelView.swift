// PanelView.swift - the popover shown when the menu bar item is clicked.
// Calm, native look: neutral numbers, colour only where a reading needs attention.
import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    @State private var topByMemory = false

    init(model: AppModel, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            tiles
            if let snap = model.snapshot {
                details(snap)
            }
            ForEach(hints) { hint in
                HintCard(hint: hint)
            }
            topAppsCard
            gameCard
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor).opacity(1 - model.config.panelTransparency))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.chipName)
                    .font(.headline)
                    .lineLimit(1)
                Text("ThermalBar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusCapsule(text: s.t(model.status.key), tint: statusTint)
        }
    }

    private var statusTint: Color {
        if model.status == .starting { return .gray }
        if model.status == .memory, model.snapshot?.memPressure == .critical { return .red }
        return PanelPalette.tint(model.status.level) ?? .green
    }

    // MARK: Tiles

    private var tiles: some View {
        let snap = model.snapshot
        let cfg = model.config
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                MetricTile(title: s.t(.tileCPU), badge: nil,
                           value: temperatureValue(snap?.cpuTemp), unit: nil,
                           level: cfg.cpuTemp.level(for: snap?.cpuTemp),
                           series: model.trends.cpu.values, minSpan: 6,
                           footnote: todayText(model.today.cpu.map { s.temperature($0) }))
                MetricTile(title: s.t(.tileGPU), badge: nil,
                           value: temperatureValue(snap?.gpuTemp), unit: nil,
                           level: cfg.gpuTemp.level(for: snap?.gpuTemp),
                           series: model.trends.gpu.values, minSpan: 6,
                           footnote: todayText(model.today.gpu.map { s.temperature($0) }))
            }
            HStack(spacing: 8) {
                MetricTile(title: s.t(.tilePower), badge: nil,
                           value: powerValue(snap?.power), unit: snap?.power == nil ? nil : s.t(.unitW),
                           level: cfg.power.level(for: snap?.power),
                           series: model.trends.power.values, minSpan: 8,
                           footnote: todayText(model.today.power.map { s.number($0) + " " + s.t(.unitW) }))
                MetricTile(title: s.t(.tileMemory), badge: s.t(.pressure),
                           value: snap?.memPressurePercent.map { s.number($0) } ?? "—",
                           unit: snap?.memPressurePercent == nil ? nil : "%",
                           level: snap?.memPressure.level ?? .normal,
                           series: model.trends.memory.values, minSpan: 10,
                           footnote: todayText(model.today.memory.map { s.number($0) + "%" }))
            }
        }
    }

    private func temperatureValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        return s.number(v) + "°"
    }

    private func powerValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        return s.number(v, decimals: v < 10 ? 1 : 0)
    }

    private func todayText(_ value: String?) -> String? {
        value.map { s.f(.todayMax, $0) }
    }

    // MARK: Details

    private func details(_ snap: Snapshot) -> some View {
        Card {
            VStack(spacing: 9) {
                if !snap.fans.isEmpty {
                    let pct = snap.fanPercent ?? 0
                    DetailRow(icon: "fan", label: s.t(.rowFans),
                              value: snap.fans.map { s.number($0.rpm) }.joined(separator: " · ") + " " + s.t(.unitRPM),
                              valueColor: .primary,
                              progress: pct / 100,
                              progressTint: PanelPalette.accent(Thresholds.fan.level(for: pct)))
                }
                if model.gpuMaxMHz > 0, let freq = snap.gpuFreqMHz {
                    DetailRow(icon: "speedometer", label: s.t(.rowGPUClock),
                              value: s.f(.gpuClockValue, s.number(freq), s.number(model.gpuMaxMHz),
                                         s.percent(snap.gpuActive)),
                              valueColor: model.gpuStuck ? .red : .primary,
                              progress: min(1, max(0, freq / model.gpuMaxMHz)),
                              progressTint: model.gpuStuck ? .red : .accentColor)
                }
                if let split = powerSplit(snap) {
                    DetailRow(icon: "bolt", label: s.t(.rowPowerSplit), value: split, valueColor: .primary)
                }
                DetailRow(icon: "thermometer.medium", label: s.t(.rowHeat), value: thermalText(snap.thermal),
                          valueColor: PanelPalette.value(snap.thermal.level))
                if let used = snap.memUsed, let total = snap.memTotal {
                    let swap = (snap.swapUsed ?? 0) > 0
                        ? s.gigabytes(snap.swapUsed) + " " + s.t(.unitGB)
                        : s.t(.swapNone)
                    DetailRow(icon: "memorychip", label: s.t(.rowMemory),
                              value: s.f(.memoryValue, s.gigabytes(used), s.gigabytes(total), swap),
                              valueColor: PanelPalette.value(snap.memPressure.level))
                }
            }
        }
    }

    private func powerSplit(_ snap: Snapshot) -> String? {
        var parts: [String] = []
        if let c = snap.cpuPower {
            parts.append("\(s.t(.capCPU)) \(s.number(c, decimals: c < 10 ? 1 : 0)) \(s.t(.unitW))")
        }
        if let g = snap.gpuPower {
            parts.append("\(s.t(.capGPU)) \(s.number(g, decimals: g < 10 ? 1 : 0)) \(s.t(.unitW))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func thermalText(_ t: ThermalPressure) -> String {
        switch t {
        case .nominal: return s.t(.thermalNominal)
        case .moderate: return s.t(.thermalModerate)
        case .heavy: return s.t(.thermalHeavy)
        case .trapping, .sleeping: return s.t(.thermalCritical)
        }
    }

    // MARK: Hints

    private var hints: [Hint] {
        guard let snap = model.snapshot else { return [] }
        var list: [Hint] = []
        if model.gpuStuck {
            list.append(Hint(id: "gpu", icon: "exclamationmark.triangle.fill", text: s.t(.hintGPUStuck), tint: .red))
        }
        if snap.thermal.isThrottling {
            list.append(Hint(id: "heat", icon: "thermometer.high", text: s.t(.hintThrottle), tint: .orange))
        }
        if snap.memPressure >= .warn {
            let text = model.topMemory.first.map { s.f(.hintMemory, $0.name) } ?? s.t(.hintMemoryNoApp)
            list.append(Hint(id: "mem", icon: "memorychip", text: text,
                             tint: snap.memPressure == .critical ? .red : .orange))
        }
        if snap.lowPowerMode {
            list.append(Hint(id: "lpm", icon: "battery.25", text: s.t(.lowPower), tint: .gray))
        }
        return list
    }

    // MARK: Top apps

    private var topAppsCard: some View {
        let apps = Array((topByMemory ? model.topMemory : model.topCPU).prefix(3))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.t(.topApps))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Picker("", selection: $topByMemory) {
                    Text(s.t(.byCPU)).tag(false)
                    Text(s.t(.byMemory)).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                if apps.isEmpty {
                    Text(s.t(.noData))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: model.icon(forAppPath: app.appPath))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                            Text(app.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(topByMemory
                                 ? s.gigabytes(app.memoryBytes) + " " + s.t(.unitGB)
                                 : s.number(app.cpuPercent, decimals: app.cpuPercent < 10 ? 1 : 0) + "%")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: Games

    private var gameCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                if let game = model.currentGame {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text([s.t(.gameNow), game.name, s.duration(game.duration)].joined(separator: " · "))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(gameStats(game))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if let game = model.lastGame {
                    cardTitle(s.t(.lastGame))
                    Text([game.name, s.duration(game.duration)].joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(gameStats(game))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(gameOutcome(game))
                        .font(.system(size: 12))
                        .foregroundStyle(game.throttledSeconds > 0 || game.gpuStuckSeconds > 0
                                         ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    cardTitle(s.t(.lastGame))
                    Text(s.t(.noGameYet))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cardTitle(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func gameStats(_ g: GameSession) -> String {
        s.f(.gameStats, s.temperature(g.maxCPU), s.temperature(g.maxGPU), g.maxPower.map { s.number($0) } ?? "—")
    }

    private func gameOutcome(_ g: GameSession) -> String {
        var parts: [String] = [g.throttledSeconds > 0
                               ? s.f(.gameThrottled, s.duration(g.throttledSeconds))
                               : s.t(.gameNoThrottle)]
        if g.gpuStuckSeconds > 0 {
            parts.append(s.f(.gameGPUStuck, s.duration(g.gpuStuckSeconds)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(s.t(.settings), action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: 4)
            Text("v" + model.appVersion)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(s.t(.quit), action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
    }
}

// MARK: - Building blocks

enum PanelPalette {
    /// Attention colour of a level, or nil when the reading is fine.
    static func tint(_ level: Level) -> Color? {
        switch level {
        case .normal: return nil
        case .warn: return .orange
        case .high, .critical: return .red
        }
    }

    static func value(_ level: Level) -> Color { tint(level) ?? .primary }

    static func accent(_ level: Level) -> Color { tint(level) ?? .accentColor }
}

private struct Hint: Identifiable {
    let id: String
    let icon: String
    let text: String
    let tint: Color
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct StatusCapsule: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

private struct MetricTile: View {
    let title: String
    let badge: String?
    let value: String
    let unit: String?
    let level: Level
    let series: [Double]
    let minSpan: Double
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PanelPalette.value(level))
                    .modifier(NumericTransition())
                    .animation(.easeInOut(duration: 0.35), value: value)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            Sparkline(values: series, tint: PanelPalette.accent(level), minSpan: minSpan)
                .frame(height: 24)
            Text(footnote ?? " ")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct NumericTransition: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentTransition(.numericText())
        } else {
            content
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let tint: Color
    /// Smallest vertical range drawn, so sensor noise does not look like spikes.
    let minSpan: Double

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2, let first = pts.first, let last = pts.last {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: first)
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2, size.width > 0, size.height > 0,
              let lo = finite.min(), let hi = finite.max() else { return [] }
        let span = max(hi - lo, minSpan)
        let base = (lo + hi) / 2 - span / 2
        let pad: CGFloat = 2
        let h = size.height - pad * 2
        let step = size.width / CGFloat(finite.count - 1)
        return finite.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: pad + (1 - CGFloat((v - base) / span)) * h)
        }
    }
}

private struct DetailRow: View {
    let icon: String
    let label: String
    let value: String
    let valueColor: Color
    var progress: Double?
    var progressTint: Color = .accentColor

    private var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 16)
    }

    private var labelView: some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var valueView: some View {
        Text(value)
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .fixedSize()
    }

    var body: some View {
        VStack(spacing: 5) {
            // One line when it fits; otherwise the value moves under the label at full size.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    iconView
                    labelView
                    Spacer(minLength: 8)
                    valueView
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    iconView
                    VStack(alignment: .leading, spacing: 2) {
                        labelView
                        valueView
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(progressTint)
                            .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, progress)))))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 24)
            }
        }
    }
}

private struct HintCard: View {
    let hint: Hint

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hint.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hint.tint)
                .frame(width: 16)
            Text(hint.text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hint.tint.opacity(0.12)))
    }
}
