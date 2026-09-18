import AppKit
import Combine
import SwiftUI

@main
enum CodeCapsMain {
    @MainActor
    static func main() {
        // Single-instance guard keyed on this build's own bundle identifier, so a
        // development build with a different identifier can run beside the installed app.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateAllWindows])
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = MonitorModel()
    let consoleState = ConsoleState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var consoleWindow: NSWindow?
    private var statusMenu: NSMenu?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        popover.behavior = .transient
        let glance = NSHostingController(rootView:
            GlancePopover(model: model,
                          openConsole: { [weak self] page in self?.showConsole(page: page) },
                          openSettings: { [weak self] in self?.showSettings() }))
        // SwiftUI must not publish a preferred content size: NSPopover prefers
        // it over `contentSize`, which would let Glance resize itself while it
        // is open and defeat the height ceiling the scroll view depends on.
        glance.sizingOptions = []
        popover.contentViewController = glance
        model.$displayMode.removeDuplicates().sink { [weak self] mode in
            self?.apply(mode)
        }.store(in: &subscriptions)
        model.$appearance.removeDuplicates().sink { [weak self] appearance in
            let resolved: NSAppearance? = switch appearance {
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            case .system: nil
            }
            NSApp.appearance = resolved
            // The popover keeps its own appearance and does not follow NSApp,
            // so Dark has to be handed to it directly.
            self?.popover.appearance = resolved
        }.store(in: &subscriptions)
        model.$keepConsoleInFront.removeDuplicates().sink { [weak self] pinned in
            self?.consoleWindow?.level = pinned ? .floating : .normal
        }.store(in: &subscriptions)
        consoleState.$page.removeDuplicates().sink { [weak self] page in
            self?.consoleWindow?.title = page.isSettings ? "CodeCaps Settings" : "CodeCaps"
        }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        if model.displayMode != .menuBar { showConsole(page: nil) }
        model.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConsole(page: nil)
        return true
    }

    private func apply(_ mode: DisplayMode) {
        // AppKit owns only activation and status-item lifetime; content remains SwiftUI.
        if mode != .dock && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        NSApp.setActivationPolicy(mode == .menuBar ? .accessory : .regular)
        if mode == .menuBar { consoleWindow?.orderOut(nil) }
        if mode == .dock {
            popover.performClose(nil)
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            showConsole(page: nil)
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
                iconImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CodeCaps")
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

        button.toolTip = "CodeCaps · \(detail)"
        button.setAccessibilityLabel("CodeCaps, \(detail)")
    }

    // MARK: - Status item

    /// Left-click toggles Glance; right-click and control-click open the command
    /// menu.  The menu is attached only for the length of that click, because a
    /// permanently assigned `statusItem.menu` would swallow the left-click path.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick { showStatusMenu() } else { togglePopover() }
    }

    private func showStatusMenu() {
        guard let item = statusItem else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = self
            menu.addItem(entry)
        }
        add("Refresh Quotas", #selector(refresh), "r")
        add("Open CodeCaps", #selector(showMonitor), "1")
        add("Settings…", #selector(showSettings), ",")
        menu.addItem(.separator())
        add("About CodeCaps", #selector(showAbout))
        add("Quit CodeCaps", #selector(quit), "q")
        statusMenu = menu
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusItem?.menu = nil
        statusMenu = nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { showConsole(page: nil); return }
        if popover.isShown { popover.performClose(nil) }
        else {
            // Sized immediately before every show, from the expected provider
            // count, so the popover cannot resize while it is open.
            // The ceiling comes from the screen the status item is on, not
            // from the key window's screen, or a short second display clamps to
            // a tall main display and pushes the footer off-screen.
            let screen = button.window?.screen ?? NSScreen.main
            popover.contentSize = NSSize(width: Metrics.glanceWidth,
                                         height: QuotaGlanceMetrics.popoverHeight(for: model, on: screen))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Console

    /// The single window.  `page` nil means "leave the selection alone", which
    /// is what a reopen or a Dock-mode switch wants.
    func showConsole(page: ConsolePage?) {
        popover.performClose(nil)
        if let page { consoleState.page = page }
        if consoleWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.consoleDefault),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentMinSize = Metrics.consoleMin
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            // A hosting CONTROLLER, not a bare hosting view: the controller
            // respects the titlebar's safe area, so scrolled content does not
            // smear through the translucent title bar.
            let console = NSHostingController(rootView: ConsoleView(model: model, state: consoleState))
            // A non-zero preferred content size on a window's content view
            // controller resizes the window to it, which would override both the
            // default content rect and any frame restored below.
            console.sizingOptions = []
            window.contentViewController = console
            // Restore first, centre only when there is nothing to restore:
            // `center()` after the autosave name discarded the saved origin on
            // every launch.
            if !window.setFrameUsingName("AgentBarConsoleWindow") { window.center() }
            window.setFrameAutosaveName("AgentBarConsoleWindow")
            consoleWindow = window
        }
        consoleWindow?.title = consoleState.page.isSettings ? "CodeCaps Settings" : "CodeCaps"
        consoleWindow?.level = model.keepConsoleInFront ? .floating : .normal
        consoleWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Kept so existing selectors and call sites keep working.
    @objc func showMonitor() { showConsole(page: .allPlatforms) }

    /// `⌘,` always lands on a Settings page, the last one used.
    @objc func showSettings() { showConsole(page: consoleState.lastSettingsPage) }

    @objc private func showAbout() { showConsole(page: .settingsAbout) }
    @objc private func refresh() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleKeepInFront() { model.keepConsoleInFront.toggle() }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            appMenu.addItem(item)
        }
        add("Open CodeCaps", #selector(showMonitor), "1")
        add("Glance", #selector(togglePopover), "2")
        add("Settings…", #selector(showSettings), ",")
        add("Refresh Quotas", #selector(refresh), "r")
        add("Keep In Front", #selector(toggleKeepInFront), "p")
        appMenu.addItem(.separator())
        add("About CodeCaps", #selector(showAbout))
        add("Quit CodeCaps", #selector(quit), "q")
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
        // Window ▸ Close gives the Console `⌘W` through the responder chain.
        // `applicationShouldTerminateAfterLastWindowClosed` is false, so closing
        // the window leaves the app running in the menu bar.
        let windowItem = NSMenuItem()
        windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
}
