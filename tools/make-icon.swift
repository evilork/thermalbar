// make-icon.swift - draws the ThermalBar app icon with CoreGraphics and builds AppIcon.icns.
// Usage (from the repo root): swift tools/make-icon.swift [repo-root]
// Writes Resources/AppIcon.icns and docs/icon.png (512 px). No external assets.
import AppKit
import Foundation

// MARK: - Palette

struct RGB {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }

    func mix(_ other: RGB, _ t: CGFloat) -> RGB {
        let k = min(max(t, 0), 1)
        return RGB(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k)
    }
}

let graphiteTop = RGB(0x3A3F47)
let graphiteBottom = RGB(0x14171C)
let teal = RGB(0x58B0A6)
let sand = RGB(0xC9B489)
let amber = RGB(0xE09A55)
let bead = RGB(0xF4F1EA)

/// Scale colour: teal at the cool end, a soft sand in the middle, warm amber at the hot end.
func scaleColor(_ t: CGFloat) -> RGB {
    t < 0.5 ? teal.mix(sand, t / 0.5) : sand.mix(amber, (t - 0.5) / 0.5)
}

// MARK: - Geometry (1024 x 1024 canvas, origin bottom-left)

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 186
let gaugeCenter = CGPoint(x: 512, y: 486)
let gaugeRadius: CGFloat = 250
let gaugeWidth: CGFloat = 60
let startAngle: CGFloat = 225   // degrees, lower left
let sweep: CGFloat = 270        // clockwise to the lower right
let value: CGFloat = 0.70

func radians(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }

func angle(at t: CGFloat) -> CGFloat { radians(startAngle - sweep * t) }

func point(at t: CGFloat, radius: CGFloat) -> CGPoint {
    let a = angle(at: t)
    return CGPoint(x: gaugeCenter.x + cos(a) * radius, y: gaugeCenter.y + sin(a) * radius)
}

func bodyPath() -> CGPath {
    CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
}

// MARK: - Drawing

func drawIcon(_ ctx: CGContext) {
    let path = bodyPath()

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.38))
    ctx.addPath(path)
    ctx.setFillColor(graphiteBottom.cg())
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite gradient background.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    if let bg = CGGradient(colorsSpace: space, colors: [graphiteTop.cg(), graphiteBottom.cg()] as CFArray,
                           locations: [0, 1]) {
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    }
    // A faint warm glow behind the gauge, barely there.
    if let glow = CGGradient(colorsSpace: space, colors: [amber.cg(0.10), amber.cg(0)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: point(at: value, radius: gaugeRadius), startRadius: 0,
                               endCenter: point(at: value, radius: gaugeRadius), endRadius: 330, options: [])
    }
    // Top sheen.
    if let sheen = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY + 120), options: [])
    }
    ctx.restoreGState()

    // Hairline edge highlight.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: bodyRadius - 1.5,
                       cornerHeight: bodyRadius - 1.5, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Tick marks inside the arc.
    ctx.saveGState()
    ctx.setLineCap(.round)
    for i in 0...10 {
        let t = CGFloat(i) / 10
        let major = i % 5 == 0
        let inner = gaugeRadius - gaugeWidth / 2 - (major ? 46 : 36)
        let outer = gaugeRadius - gaugeWidth / 2 - 18
        ctx.move(to: point(at: t, radius: inner))
        ctx.addLine(to: point(at: t, radius: outer))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: major ? 0.30 : 0.16))
        ctx.setLineWidth(major ? 9 : 6)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Track.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(gaugeWidth)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
    ctx.addArc(center: gaugeCenter, radius: gaugeRadius, startAngle: angle(at: 0), endAngle: angle(at: 1), clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // Value arc: many short segments for a smooth colour sweep, round start cap.
    ctx.saveGState()
    ctx.setLineCap(.butt)
    ctx.setLineWidth(gaugeWidth)
    let steps = 360
    for i in 0..<steps {
        let t0 = value * CGFloat(i) / CGFloat(steps)
        let t1 = value * CGFloat(i + 1) / CGFloat(steps)
        ctx.addArc(center: gaugeCenter, radius: gaugeRadius, startAngle: angle(at: t0),
                   endAngle: angle(at: min(t1 + 0.002, value)), clockwise: true)
        ctx.setStrokeColor(scaleColor(t0).cg())
        ctx.strokePath()
    }
    let capStart = point(at: 0, radius: gaugeRadius)
    ctx.setFillColor(scaleColor(0).cg())
    ctx.fillEllipse(in: CGRect(x: capStart.x - gaugeWidth / 2, y: capStart.y - gaugeWidth / 2,
                               width: gaugeWidth, height: gaugeWidth))
    ctx.restoreGState()

    // Bead at the current value.
    let p = point(at: value, radius: gaugeRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setFillColor(bead.cg())
    let beadR: CGFloat = 46
    ctx.fillEllipse(in: CGRect(x: p.x - beadR, y: p.y - beadR, width: beadR * 2, height: beadR * 2))
    ctx.restoreGState()
    ctx.setFillColor(scaleColor(value).cg())
    let dotR: CGFloat = 18
    ctx.fillEllipse(in: CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2))

    drawThermometer(ctx)
}

/// A small thermometer in the middle of the gauge: outlined glass with warm liquid.
func drawThermometer(_ ctx: CGContext) {
    let cx = gaugeCenter.x
    let bulbCenter = CGPoint(x: cx, y: gaugeCenter.y - 78)
    let bulbR: CGFloat = 54
    let stemW: CGFloat = 56
    let stemTop = gaugeCenter.y + 128

    let glass = CGMutablePath()
    glass.addRoundedRect(in: CGRect(x: cx - stemW / 2, y: bulbCenter.y, width: stemW, height: stemTop - bulbCenter.y),
                         cornerWidth: stemW / 2, cornerHeight: stemW / 2)
    glass.addEllipse(in: CGRect(x: bulbCenter.x - bulbR, y: bulbCenter.y - bulbR, width: bulbR * 2, height: bulbR * 2))

    // Glass body.
    ctx.saveGState()
    ctx.addPath(glass)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // Outline: stroke the stem and the bulb, then refill the bulb's inside so the joint disappears.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.82))
    ctx.setLineWidth(12)
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - stemW / 2, y: bulbCenter.y, width: stemW, height: stemTop - bulbCenter.y),
                       cornerWidth: stemW / 2, cornerHeight: stemW / 2, transform: nil))
    ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: bulbCenter.x - bulbR, y: bulbCenter.y - bulbR, width: bulbR * 2, height: bulbR * 2))
    ctx.strokePath()
    // Hide the stem's bottom edge inside the bulb.
    ctx.addEllipse(in: CGRect(x: bulbCenter.x - bulbR + 6, y: bulbCenter.y - bulbR + 6,
                              width: (bulbR - 6) * 2, height: (bulbR - 6) * 2))
    ctx.clip()
    ctx.setFillColor(graphiteBottom.mix(graphiteTop, 0.55).cg())
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.restoreGState()

    // Liquid.
    let liquidColor = scaleColor(value)
    let liquidW: CGFloat = 22
    let liquidTop = bulbCenter.y + (stemTop - bulbCenter.y) * 0.62
    ctx.setFillColor(liquidColor.cg())
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - liquidW / 2, y: bulbCenter.y, width: liquidW, height: liquidTop - bulbCenter.y),
                       cornerWidth: liquidW / 2, cornerHeight: liquidW / 2, transform: nil))
    ctx.fillPath()
    let innerR: CGFloat = 32
    ctx.fillEllipse(in: CGRect(x: bulbCenter.x - innerR, y: bulbCenter.y - innerR, width: innerR * 2, height: innerR * 2))
}

// MARK: - Rendering and output

enum IconError: Error, CustomStringConvertible {
    case context(Int)
    case encode(Int)
    case write(String)
    case iconutil(Int32)
    case root(String)

    var description: String {
        switch self {
        case .context(let s): return "cannot create a \(s) px bitmap context"
        case .encode(let s): return "cannot encode the \(s) px PNG"
        case .write(let p): return "cannot write \(p)"
        case .iconutil(let code): return "iconutil failed with exit code \(code)"
        case .root(let p): return "\(p) does not look like the ThermalBar repo (no Sources/)"
        }
    }
}

func renderPNG(size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else {
        throw IconError.context(size)
    }
    let ctx = gc.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx)
    gc.flushGraphics()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw IconError.encode(size) }
    return data
}

func write(_ data: Data, to url: URL) throws {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw IconError.write(url.path)
    }
}

func run() throws {
    let args = CommandLine.arguments
    let rootPath = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path, isDirectory: &isDir),
          isDir.boolValue else {
        throw IconError.root(root.path)
    }

    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("thermalbar-icon-\(getpid())", isDirectory: true)
    let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    let entries: [(name: String, size: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for entry in entries {
        try write(try renderPNG(size: entry.size), to: iconset.appendingPathComponent("\(entry.name).png"))
    }

    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.createDirectory(at: docs, withIntermediateDirectories: true)

    let icns = resources.appendingPathComponent("AppIcon.icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw IconError.iconutil(task.terminationStatus) }

    try write(try renderPNG(size: 512), to: docs.appendingPathComponent("icon.png"))
    if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW_DIR"] {
        let dir = URL(fileURLWithPath: preview, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in [1024, 128, 64, 32, 16] {
            try write(try renderPNG(size: size), to: dir.appendingPathComponent("icon-\(size).png"))
        }
    }
    print("wrote \(icns.path)")
    print("wrote \(docs.appendingPathComponent("icon.png").path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
