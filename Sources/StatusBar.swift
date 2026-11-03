// StatusBar.swift - what the menu bar shows and the view that draws it.
// StatusBarContent is plain data built from a Snapshot; StatusBarView draws it with AppKit text,
// resolving colours at draw time so it looks right in light and dark menu bars.
import Cocoa

/// One reading in the menu bar, e.g. caption "ЦП" + value "66°".
struct BarSegment: Equatable {
    /// "ЦП" / "Вт"; nil when labels are off.
    var caption: String?
    /// "66°", "91", "38%".
    var value: String
    /// True for power: "91 Вт".
    var captionAfter: Bool
    var level: Level
    /// Widest usual value ("00°", "000", "00%"): the width never shrinks below it, so the item does not jitter.
    var template: String
}

enum BarAlert: Equatable {
    case none
    case memory
    case throttling
    case gpuStuck
}

struct StatusBarContent: Equatable {
    var segments: [BarSegment]
    var layout: BarLayout
    var colorMode: ColorMode
    var alert: BarAlert

    static let empty = StatusBarContent(segments: [], layout: .singleLine, colorMode: .whenHot, alert: .none)

    /// Builds the menu bar content. Order: CPU, GPU, power, memory, fans; disabled and missing readings are skipped.
    static func make(snapshot: Snapshot?, config: Config, strings: Strings, gpuStuck: Bool) -> StatusBarContent {
        var content = StatusBarContent(segments: [], layout: config.layout, colorMode: config.colorMode, alert: .none)
        guard let s = snapshot else {
            content.alert = gpuStuck ? .gpuStuck : .none
            return content
        }
        let captions = config.showLabels || config.layout == .twoLines

        func whole(_ v: Double) -> String { String(Int(v.rounded())) }

        if config.showCPU, let t = s.cpuTemp, t.isFinite {
            content.segments.append(BarSegment(caption: captions ? strings.t(.capCPU) : nil, value: whole(t) + "°",
                                               captionAfter: false, level: config.cpuTemp.level(for: t),
                                               template: "00°"))
        }
        if config.showGPU, let t = s.gpuTemp, t.isFinite {
            content.segments.append(BarSegment(caption: captions ? strings.t(.capGPU) : nil, value: whole(t) + "°",
                                               captionAfter: false, level: config.gpuTemp.level(for: t),
                                               template: "00°"))
        }
        if config.showPower, let p = s.power, p.isFinite, p >= 0 {
            // Three digits are common where the badge threshold is 100 W or more (Max, Ultra).
            let template = config.power.critical >= 100 ? "000" : "00"
            content.segments.append(BarSegment(caption: strings.t(.capWatt), value: whole(p),
                                               captionAfter: true, level: config.power.level(for: p),
                                               template: template))
        }
        if config.showMemory, let m = s.memPressurePercent, m.isFinite {
            content.segments.append(BarSegment(caption: captions ? strings.t(.capMem) : nil, value: whole(m) + "%",
                                               captionAfter: false, level: s.memPressure.level, template: "00%"))
        }
        if config.showFans, let f = s.fanPercent, f.isFinite {
            content.segments.append(BarSegment(caption: captions ? strings.t(.capFan) : nil, value: whole(f) + "%",
                                               captionAfter: false, level: Thresholds.fan.level(for: f),
                                               template: "00%"))
        }

        if gpuStuck {
            content.alert = .gpuStuck
        } else if s.thermal.isThrottling {
            content.alert = .throttling
        } else if s.memPressure == .critical {
            content.alert = .memory
        }
        return content
    }

    /// Spoken text for VoiceOver, e.g. "ЦП 54°, ГП 51°, 23 Вт, ПАМ 38%".
    var accessibilityText: String {
        segments.map { seg -> String in
            guard let c = seg.caption else { return seg.value }
            return seg.captionAfter ? "\(seg.value) \(c)" : "\(c) \(seg.value)"
        }.joined(separator: ", ")
    }
}

// MARK: - Drawing

private enum BarStyle {
    static let sidePadding: CGFloat = 4
    static let alertGap: CGFloat = 5

    // Single line
    static let captionFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    static let captionKern: CGFloat = 0.3
    static let captionGap: CGFloat = 3
    static let segmentGap: CGFloat = 8
    static let pillPadding: CGFloat = 4
    static let pillHeight: CGFloat = 15
    static let pillRadius: CGFloat = 4

    // Two lines
    static let smallCaptionFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    static let smallValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    static let columnGap: CGFloat = 7
    static let lineGap: CGFloat = 2.5
    static let smallPillPadding: CGFloat = 3
    static let smallPillRadius: CGFloat = 3

    static let alertPointSize: CGFloat = 11
    static let placeholderPointSize: CGFloat = 13
}

/// Position of one segment, relative to its own left edge.
private struct SegmentGeometry {
    var segment: BarSegment
    var width: CGFloat
    var captionX: CGFloat
    var captionWidth: CGFloat
    var boxX: CGFloat
    var boxWidth: CGFloat
    var valueWidth: CGFloat
    var pill: Bool
}

private struct BarGeometry {
    var width: CGFloat
    var alertWidth: CGFloat
    var segments: [SegmentGeometry]
    var placeholderWidth: CGFloat
}

final class StatusBarView: NSView {
    var content: StatusBarContent {
        didSet {
            guard content != oldValue else { return }
            geometry = StatusBarView.makeGeometry(for: content)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var geometry: BarGeometry

    /// The lead sets statusItem.length from this.
    var preferredWidth: CGFloat { geometry.width }

    init(content: StatusBarContent = .empty) {
        self.content = content
        self.geometry = StatusBarView.makeGeometry(for: content)
        super.init(frame: NSRect(x: 0, y: 0, width: geometry.width, height: NSStatusBar.system.thickness))
    }

    required init?(coder: NSCoder) {
        self.content = .empty
        self.geometry = StatusBarView.makeGeometry(for: .empty)
        super.init(coder: coder)
    }

    override var isFlipped: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: geometry.width, height: NSStatusBar.system.thickness)
    }

    /// Clicks go to the status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.drawContent(in: self.bounds)
        }
    }

    /// Draws into a bitmap over a plain menu-bar-like background (for previews and the README).
    func renderPNG(appearanceName: NSAppearance.Name, scale: CGFloat) -> Data? {
        guard let appearance = NSAppearance(named: appearanceName), scale > 0 else { return nil }
        let margin: CGFloat = 8
        let size = NSSize(width: ceil(geometry.width) + margin * 2, height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((size.width * scale).rounded()),
                                         pixelsHigh: Int((size.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Point size first, so the context draws at `scale` pixels per point.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        appearance.performAsCurrentDrawingAppearance {
            let background = isDark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
                                    : NSColor(white: 0.92, alpha: 1)
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            self.drawContent(in: NSRect(x: margin, y: 0, width: ceil(self.geometry.width), height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Geometry

    private static func textWidth(_ text: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
        // The kern after the last glyph is not visible; leave it out of the width.
        return ceil(NSAttributedString(string: text, attributes: attrs).size().width - kern)
    }

    private static func makeGeometry(for content: StatusBarContent) -> BarGeometry {
        var alertWidth: CGFloat = 0
        if let image = alertSymbol(content.alert, color: .labelColor) {
            alertWidth = ceil(image.size.width) + BarStyle.alertGap
        }
        if content.segments.isEmpty {
            let symbolWidth = placeholderSymbol(color: .labelColor).map { ceil($0.size.width) } ?? 14
            let width = BarStyle.sidePadding * 2 + alertWidth + symbolWidth
            return BarGeometry(width: width, alertWidth: alertWidth, segments: [], placeholderWidth: symbolWidth)
        }

        let twoLines = content.layout == .twoLines
        var segments: [SegmentGeometry] = []
        for seg in content.segments {
            let pill = seg.level == .critical
            if twoLines {
                let capW = seg.caption.map { textWidth($0, font: BarStyle.smallCaptionFont) } ?? 0
                let valW = max(textWidth(seg.value, font: BarStyle.smallValueFont),
                               textWidth(seg.template, font: BarStyle.smallValueFont))
                let boxW = valW + (pill ? BarStyle.smallPillPadding * 2 : 0)
                let colW = max(capW, boxW)
                segments.append(SegmentGeometry(segment: seg, width: colW, captionX: (colW - capW) / 2,
                                                captionWidth: capW, boxX: (colW - boxW) / 2, boxWidth: boxW,
                                                valueWidth: textWidth(seg.value, font: BarStyle.smallValueFont),
                                                pill: pill))
            } else {
                let capW = seg.caption.map { textWidth($0, font: BarStyle.captionFont, kern: BarStyle.captionKern) } ?? 0
                let valW = max(textWidth(seg.value, font: BarStyle.valueFont),
                               textWidth(seg.template, font: BarStyle.valueFont))
                let boxW = valW + (pill ? BarStyle.pillPadding * 2 : 0)
                let actual = textWidth(seg.value, font: BarStyle.valueFont)
                if seg.caption == nil {
                    segments.append(SegmentGeometry(segment: seg, width: boxW, captionX: 0, captionWidth: 0,
                                                    boxX: 0, boxWidth: boxW, valueWidth: actual, pill: pill))
                } else if seg.captionAfter {
                    let capX = boxW + BarStyle.captionGap
                    segments.append(SegmentGeometry(segment: seg, width: capX + capW, captionX: capX,
                                                    captionWidth: capW, boxX: 0, boxWidth: boxW,
                                                    valueWidth: actual, pill: pill))
                } else {
                    let boxX = capW + BarStyle.captionGap
                    segments.append(SegmentGeometry(segment: seg, width: boxX + boxW, captionX: 0,
                                                    captionWidth: capW, boxX: boxX, boxWidth: boxW,
                                                    valueWidth: actual, pill: pill))
                }
            }
        }
        let gap = twoLines ? BarStyle.columnGap : BarStyle.segmentGap
        let body = segments.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, segments.count - 1))
        return BarGeometry(width: ceil(BarStyle.sidePadding * 2 + alertWidth + body), alertWidth: alertWidth,
                           segments: segments, placeholderWidth: 0)
    }

    // MARK: Symbols

    /// `colors`: one colour tints the whole symbol; two colours paint the primary layer (e.g. the "!")
    /// and the secondary layer (the triangle) separately.
    private static func symbol(_ name: String, fallback: String?, pointSize: CGFloat,
                               weight: NSFont.Weight, colors: [NSColor]) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        guard let image = base else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        return image.withSymbolConfiguration(config)
    }

    private static func alertSymbol(_ alert: BarAlert, color: NSColor) -> NSImage? {
        switch alert {
        case .none:
            return nil
        case .gpuStuck:
            return symbol("exclamationmark.triangle.fill", fallback: nil, pointSize: BarStyle.alertPointSize,
                          weight: .semibold, colors: [.white, color])
        case .throttling:
            return symbol("thermometer.high", fallback: "thermometer", pointSize: BarStyle.alertPointSize,
                          weight: .semibold, colors: [color])
        case .memory:
            return symbol("memorychip", fallback: nil, pointSize: BarStyle.alertPointSize,
                          weight: .semibold, colors: [color])
        }
    }

    private static func placeholderSymbol(color: NSColor) -> NSImage? {
        symbol("thermometer.medium", fallback: "thermometer", pointSize: BarStyle.placeholderPointSize,
               weight: .regular, colors: [color])
    }

    /// A dynamic system colour resolved for the current drawing appearance (symbol palettes need a fixed colour).
    private static func resolved(_ color: NSColor) -> NSColor {
        NSColor(cgColor: color.cgColor) ?? color
    }

    // MARK: Draw

    private static func halfPoint(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    private func valueColor(_ level: Level) -> NSColor {
        switch level {
        case .normal: return content.colorMode == .always ? .systemGreen : .labelColor
        case .warn: return .systemOrange
        case .high: return .systemRed
        case .critical: return .white
        }
    }

    /// Draws `text` with its baseline at `baseline` (no line-fragment origin: rect origin = baseline).
    private func drawText(_ text: String, x: CGFloat, baseline: CGFloat, font: NSFont,
                          color: NSColor, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let string = NSAttributedString(string: text, attributes: attrs)
        string.draw(with: NSRect(x: x, y: baseline, width: string.size().width + 2, height: font.pointSize * 1.5),
                    options: [], context: nil)
    }

    private func drawContent(in rect: NSRect) {
        let geo = geometry
        var x = rect.minX + BarStyle.sidePadding

        if let image = StatusBarView.alertSymbol(content.alert,
                                                 color: StatusBarView.resolved(alertColor(content.alert))) {
            let size = image.size
            image.draw(in: NSRect(x: x, y: StatusBarView.halfPoint(rect.midY - size.height / 2),
                                  width: size.width, height: size.height))
            x += geo.alertWidth
        }

        if geo.segments.isEmpty {
            if let image = StatusBarView.placeholderSymbol(color: StatusBarView.resolved(.labelColor)) {
                let size = image.size
                image.draw(in: NSRect(x: x, y: StatusBarView.halfPoint(rect.midY - size.height / 2),
                                      width: size.width, height: size.height))
            }
            return
        }

        if content.layout == .twoLines {
            drawTwoLines(geo.segments, startX: x, rect: rect)
        } else {
            drawSingleLine(geo.segments, startX: x, rect: rect)
        }
    }

    private func alertColor(_ alert: BarAlert) -> NSColor {
        switch alert {
        case .throttling: return .systemOrange
        case .none: return .labelColor
        case .gpuStuck, .memory: return .systemRed
        }
    }

    private func drawSingleLine(_ segments: [SegmentGeometry], startX: CGFloat, rect: NSRect) {
        let valueFont = BarStyle.valueFont
        let baseline = StatusBarView.halfPoint(rect.midY - valueFont.capHeight / 2)
        var x = startX
        for g in segments {
            let seg = g.segment
            if let caption = seg.caption {
                drawText(caption, x: x + g.captionX, baseline: baseline, font: BarStyle.captionFont,
                         color: .secondaryLabelColor, kern: BarStyle.captionKern)
            }
            if g.pill {
                let pillRect = NSRect(x: x + g.boxX,
                                      y: StatusBarView.halfPoint(baseline + valueFont.capHeight / 2 - BarStyle.pillHeight / 2),
                                      width: g.boxWidth, height: BarStyle.pillHeight)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: BarStyle.pillRadius, yRadius: BarStyle.pillRadius).fill()
            }
            // Right-align inside the box so the digits that change sit on the left.
            let pad = g.pill ? BarStyle.pillPadding : 0
            let valueX = x + g.boxX + g.boxWidth - pad - g.valueWidth
            drawText(seg.value, x: valueX, baseline: baseline, font: valueFont, color: valueColor(seg.level))
            x += g.width + BarStyle.segmentGap
        }
    }

    private func drawTwoLines(_ segments: [SegmentGeometry], startX: CGFloat, rect: NSRect) {
        let capFont = BarStyle.smallCaptionFont
        let valFont = BarStyle.smallValueFont
        let block = valFont.capHeight + BarStyle.lineGap + capFont.capHeight
        let valueBaseline = StatusBarView.halfPoint(rect.midY - block / 2)
        let captionBaseline = StatusBarView.halfPoint(valueBaseline + valFont.capHeight + BarStyle.lineGap)
        var x = startX
        for g in segments {
            let seg = g.segment
            if let caption = seg.caption {
                drawText(caption, x: x + g.captionX, baseline: captionBaseline, font: capFont,
                         color: .secondaryLabelColor)
            }
            if g.pill {
                let pillRect = NSRect(x: x + g.boxX, y: valueBaseline - 2,
                                      width: g.boxWidth, height: valFont.capHeight + 4)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: BarStyle.smallPillRadius,
                             yRadius: BarStyle.smallPillRadius).fill()
            }
            // Centred under its caption; the column keeps the template width, so nothing around it moves.
            let valueX = x + g.boxX + (g.boxWidth - g.valueWidth) / 2
            drawText(seg.value, x: valueX, baseline: valueBaseline, font: valFont, color: valueColor(seg.level))
            x += g.width + BarStyle.columnGap
        }
    }
}
