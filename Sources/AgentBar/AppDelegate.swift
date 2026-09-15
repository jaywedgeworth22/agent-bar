import AppKit
import Combine
import SwiftUI

@main
enum AgentBarMain {
    @MainActor
    static func main() {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.jays.agent-bar.mac")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }
        let app = NSApplication.shared
        app.disableRelaunchOnLogin()
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = MonitorModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var monitorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        configureMenu()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 410, height: 600)
        popover.contentViewController = NSHostingController(rootView:
            QuotaPopover(model: model, openMonitor: { [weak self] in self?.showMonitor() },
                         openSettings: { [weak self] in self?.showSettings() }))
        model.$displayMode.removeDuplicates().sink { [weak self] mode in
            self?.apply(mode)
        }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        if model.displayMode != .menuBar { showMonitor() }
        model.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMonitor()
        return true
    }

    private func apply(_ mode: DisplayMode) {
        // AppKit owns only activation and status-item lifetime; content remains SwiftUI.
        if mode != .dock && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            statusItem = item
        }
        NSApp.setActivationPolicy(mode == .menuBar ? .accessory : .regular)
        if mode == .menuBar { monitorWindow?.orderOut(nil) }
        if mode == .dock {
            popover.performClose(nil)
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            showMonitor()
        }
        updateStatus()
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let style = model.menuBarStyle
        let title = model.menuBarTitle
        let detail = model.menuBarDetail
        let target = model.menuBarTargetSnapshot

        // Configure image presence
        if style == .percentOnly {
            button.image = nil
            button.imagePosition = .noImage
        } else {
            let providerKey = target?.window.canonicalProviderKey ?? "auto"
            var iconImage: NSImage?
            if target != nil {
                iconImage = PlatformLogoImage.menuBarImage(providerKey: providerKey)
            }
            if iconImage == nil {
                let symbolName = target != nil
                    ? PlatformLogoImage.fallbackSymbolName(for: providerKey)
                    : "gauge.with.dots.needle.50percent"
                iconImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AgentBar")
                iconImage?.isTemplate = true
            }
            button.image = iconImage
            button.imagePosition = style == .symbolOnly ? .imageOnly : .imageLeading
        }

        // Configure title
        if style == .symbolOnly {
            button.title = ""
        } else {
            button.title = " \(title)"
        }

        button.toolTip = "AgentBar · \(detail)"
        button.setAccessibilityLabel("AgentBar, \(detail)")
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { showMonitor(); return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func showMonitor() {
        popover.performClose(nil)
        if monitorWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "AgentBar"
            window.minSize = NSSize(width: 800, height: 540)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.contentView = NSHostingView(rootView:
                MonitorDashboard(model: model, openSettings: { [weak self] in self?.showSettings() }))
            window.setFrameAutosaveName("AgentBarMainWindow")
            window.center()
            monitorWindow = window
        }
        monitorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 510),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AgentBar Settings"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: MonitorSettings(model: model))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            appMenu.addItem(item)
        }
        add("Open AgentBar", #selector(showMonitor), "1")
        add("Quick Quotas", #selector(togglePopover), "2")
        add("Settings…", #selector(showSettings), ",")
        add("Refresh Quotas", #selector(refresh), "r")
        appMenu.addItem(.separator())
        add("Quit AgentBar", #selector(quit), "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
