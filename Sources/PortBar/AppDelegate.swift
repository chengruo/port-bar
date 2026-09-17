import Cocoa
import SwiftUI
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var managerWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup Main Menu with Edit menu for Cut, Copy, Paste, Select All, Undo
        setupMainMenu()

        // Ensure askpass binary is ready
        _ = AskpassHelper.shared.getAskpassBinaryPath()

        // Configure Status Bar Item
        setupStatusItem()

        // Configure Popover
        setupPopover()

        // Bind Status Changes to Status Item Appearance
        observeTunnelState()

        // Setup Global HotKey (Option + P) to toggle window anywhere
        setupGlobalHotKey()

        // Auto-start configured mappings
        startAutoStartMappings()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        SSHTunnelManager.shared.stopAll()
        HotKeyManager.shared.unregister()
    }

    // MARK: - Global HotKey Setup (Option + P)

    private func setupGlobalHotKey() {
        HotKeyManager.shared.registerDefaultHotKey()
        HotKeyManager.onHotKey = { [weak self] in
            self?.toggleManagerWindow()
        }
    }

    public func toggleManagerWindow() {
        if let window = managerWindow, window.isVisible, NSApp.isActive {
            window.orderOut(nil)
            if !UserDefaults.standard.bool(forKey: "portbar_show_dock_icon") {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            openManagerWindow()
        }
    }

    // MARK: - Reopen from Spotlight / Launchpad / Dock

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openManagerWindow()
        return true
    }

    // MARK: - URL Scheme (portbar://open, portbar://mappings, portbar://hosts)

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "portbar" else { return }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        if host == "hosts" || path.contains("hosts") {
            openManagerWindow(initialTab: .hosts)
        } else if host == "toggle" {
            toggleManagerWindow()
        } else {
            openManagerWindow(initialTab: .mappings)
        }
    }

    // MARK: - Main Menu (Fixes Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z in accessory apps)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 PortBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 PortBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 PortBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu (Essential for Undo, Redo, Cut, Copy, Paste, Select All)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        let undoItem = editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateStatusItemButton(activeCount: 0)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 330, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                onOpenManager: { [weak self] tab in
                    self?.popover.performClose(nil)
                    self?.openManagerWindow(initialTab: tab)
                },
                onQuit: { [weak self] in
                    self?.popover.performClose(nil)
                    SSHTunnelManager.shared.stopAll()
                    NSApplication.shared.terminate(nil)
                }
            )
        )
        self.popover = popover
    }

    private func observeTunnelState() {
        SSHTunnelManager.shared.$statuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let count = SSHTunnelManager.shared.activeTunnelCount
                self.updateStatusItemButton(activeCount: count)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemButton(activeCount: Int) {
        guard let button = statusItem?.button else { return }

        let iconName = activeCount > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "PortBar") {
            image.isTemplate = true
            button.image = image
        }

        if activeCount > 0 {
            button.title = " \(activeCount)"
        } else {
            button.title = ""
        }
    }

    // MARK: - Actions

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.contentViewController = NSHostingController(
                rootView: MenuBarView(
                    onOpenManager: { [weak self] tab in
                        self?.popover.performClose(nil)
                        self?.openManagerWindow(initialTab: tab)
                    },
                    onQuit: { [weak self] in
                        self?.popover.performClose(nil)
                        SSHTunnelManager.shared.stopAll()
                        NSApplication.shared.terminate(nil)
                    }
                )
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func openManagerWindow(initialTab: ManagerTab = .mappings) {
        if let window = managerWindow {
            window.contentViewController = NSHostingController(rootView: HostManagerView(initialTab: initialTab))
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "PortBar - 端口映射与主机管理"
        window.contentViewController = NSHostingController(rootView: HostManagerView(initialTab: initialTab))
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.managerWindow = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: "portbar_show_dock_icon") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func startAutoStartMappings() {
        for mapping in ConfigStore.shared.mappings where mapping.autoStart {
            SSHTunnelManager.shared.startTunnel(for: mapping)
        }
    }
}
