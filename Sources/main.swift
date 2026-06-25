// main.swift - entry point. The status item is created inside the AppDelegate
// (applicationDidFinishLaunching); creating it before NSApplication is ready
// prevents the item from attaching to the menu bar.
import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
app.run()
