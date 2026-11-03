// Preview.swift - `ThermalBar --render-preview <dir>` writes README images from live readings:
// panel-light.png, panel-dark.png, menubar-light.png, menubar-dark.png. It uses a temporary config
// (default settings), shows only system processes and never touches the login item or notifications.
import AppKit
import SwiftUI

final class PreviewRenderer {
    private let outputDir: URL
    private let model: AppModel
    private let workDir: URL

    init(outputDir: URL) {
        self.outputDir = outputDir
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thermalbar-preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        // A copy of the saved peaks so the panel shows real data without writing to the real file.
        let stateCopy = workDir.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: StateStore.defaultURL, to: stateCopy)
        model = AppModel(configURL: workDir.appendingPathComponent("config.json"),
                         stateStore: StateStore(url: stateCopy),
                         previewMode: true)
        var config = model.config
        config.intervalSeconds = 1
        config.panelTransparency = 0
        config.notifyMemory = false
        config.notifyThrottle = false
        config.notifyGPUStuck = false
        config.showFans = true
        model.config = config
    }

    /// Samples for a few seconds, renders, then quits the app with the result code.
    func run() {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            finish(code: 1, message: "cannot create \(outputDir.path): \(error.localizedDescription)")
            return
        }
        model.panelOpen = true
        model.start(requestNotifications: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.render() }
    }

    private struct PanelShot {
        let suffix: String
        let appearance: NSAppearance
        let window: NSWindow
        let host: NSView
        let size: NSSize
    }

    private func render() {
        model.stop()  // freeze the readings so no number is captured mid-animation
        var written: [String] = []
        var shots: [PanelShot] = []
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            if let shot = preparePanel(suffix: suffix, appearance: name) { shots.append(shot) }
            let bar = StatusBarView(content: StatusBarContent.make(snapshot: model.snapshot, config: model.config,
                                                                   strings: model.strings, gpuStuck: model.gpuStuck))
            if let data = bar.renderPNG(appearanceName: name, scale: 2) {
                written.append(write(data, "menubar-\(suffix).png"))
            }
        }
        // Give the hosting views one display pass on a Retina screen before capturing them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            for shot in shots {
                if let data = self.capture(shot) { written.append(self.write(data, "panel-\(shot.suffix).png")) }
                shot.window.orderOut(nil)
            }
            let ok = !written.contains("") && written.count == 4
            self.finish(code: ok ? 0 : 1,
                        message: "wrote \(written.filter { !$0.isEmpty }.count) images to \(self.outputDir.path)")
        }
    }

    private func preparePanel(suffix: String, appearance name: NSAppearance.Name) -> PanelShot? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        let probe = NSHostingView(rootView: PanelView(model: model, onSettings: {}, onQuit: {}))
        probe.appearance = appearance
        let size = probe.fittingSize
        guard size.width > 10, size.height > 10 else { return nil }
        let host = probe
        // On screen but fully transparent and click-through.
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let win = NSWindow(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = appearance
        win.isOpaque = false
        win.backgroundColor = .clear
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.orderFrontRegardless()
        return PanelShot(suffix: suffix, appearance: appearance, window: win, host: host, size: size)
    }

    private func capture(_ shot: PanelShot) -> Data? {
        let host = shot.host
        let size = shot.size
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Rounded panel on an opaque window-coloured card, like the real popover.
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        out.size = size  // before the context, so it draws at the bitmap's pixels-per-point
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        shot.appearance.performAsCurrentDrawingAppearance {
            let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14)
            path.addClip()
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            rep.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }

    private func write(_ data: Data, _ name: String) -> String {
        let url = outputDir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            FileHandle.standardError.write(Data("cannot write \(url.path): \(error.localizedDescription)\n".utf8))
            return ""
        }
    }

    private func finish(code: Int32, message: String) {
        model.stop()
        try? FileManager.default.removeItem(at: workDir)
        FileHandle.standardError.write(Data("preview: \(message)\n".utf8))
        exit(code)
    }
}
