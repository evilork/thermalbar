// AppDelegate.swift - menu bar item, the panel (popover), the right-click menu and the settings window.
import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private let barView = StatusBarView()
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var configObserver: AnyCancellable?

    init(model: AppModel = AppModel()) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            barView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(barView)
            NSLayoutConstraint.activate([
                barView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                barView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                barView.topAnchor.constraint(equalTo: button.topAnchor),
                barView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(
            model: model,
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        model.onUpdate = { [weak self] in self?.refreshBar() }
        // The settings window title follows the language setting.
        configObserver = model.$strings.sink { [weak self] strings in
            self?.settingsWindow?.title = strings.t(.settingsTitle)
        }
        refreshBar()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: - Menu bar

    private func refreshBar() {
        let content = StatusBarContent.make(snapshot: model.snapshot, config: model.config,
                                            strings: model.strings, gpuStuck: model.gpuStuck)
        if barView.content != content { barView.content = content }
        guard let item = statusItem else { return }
        let width = barView.preferredWidth
        if abs(item.length - width) > 0.5 { item.length = width }
        item.button?.setAccessibilityLabel(content.accessibilityText.isEmpty ? "ThermalBar" : content.accessibilityText)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu()
        } else {
            togglePanel(sender)
        }
    }

    private func togglePanel(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.panelOpen = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        guard let item = statusItem, let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu()
        let settings = NSMenuItem(title: model.strings.t(.settings), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: model.strings.t(.quit), action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    func popoverDidClose(_ notification: Notification) {
        model.panelOpen = false
    }

    // MARK: - Settings window

    private func openSettings() {
        if popover.isShown { popover.performClose(nil) }
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = model.strings.t(.settingsTitle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
    }
}
