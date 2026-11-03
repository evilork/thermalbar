// main.swift - entry point. The status item is created in AppDelegate.applicationDidFinishLaunching,
// because an item created before NSApplication is ready does not attach to the menu bar.
import AppKit

let app = NSApplication.shared
let arguments = CommandLine.arguments

if let flag = arguments.firstIndex(of: "--render-preview") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: ThermalBar --render-preview <output-dir>\n".utf8))
        exit(2)
    }
    app.setActivationPolicy(.prohibited)
    let renderer = PreviewRenderer(outputDir: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true))
    DispatchQueue.main.async { renderer.run() }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
}
