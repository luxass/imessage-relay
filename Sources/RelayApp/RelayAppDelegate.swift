import AppKit
import RelayServer
import SwiftUI

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var setupComplete = AppSetup.isComplete
    let relay = RelayController()
    let loginItem = LoginItemSettings()
    let permissions = PermissionStore()
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var menuError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let needsSetup = !setupComplete
        NSApp.setActivationPolicy(needsSetup ? .regular : .accessory)
        configureMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        if needsSetup {
            showSetup()
        } else {
            showStatusItem()
            loginItem.refresh()
            relay.startOnLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        relay.cancelForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === setupWindow {
            if !setupComplete {
                NSApp.terminate(nil)
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        } else if window === settingsWindow {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { [weak self] in
                self?.settingsWindow = nil
            }
        }
    }

    private func showSetup() {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 640,
                height: AppSetup.tokenReady() ? 540 : 390
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = RelayWindows.setupTitle
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(
            tokenStore: KeychainTokenStore(),
            permissions: PermissionStore(),
            onFinish: { [weak self] in
                guard let self else { return }
                AppSetup.complete()
                self.setupComplete = true
                self.showStatusItem()
                self.loginItem.refresh()
                self.relay.startOnLaunch()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.setupWindow?.close()
                    self.setupWindow = nil
                }
            },
            onHeightChange: { [weak window] contentHeight in
                guard let window else { return }
                let contentRect = NSRect(
                    x: 0, y: 0, width: 640,
                    height: contentHeight
                )
                let height = window.frameRect(forContentRect: contentRect).height
                var frame = window.frame
                frame.origin.y = frame.maxY - height
                frame.size.height = height
                window.setFrame(frame, display: true, animate: true)
            }
        ))
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "dev.luxass.imessage-relay.menu"
        let image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "iMessage Relay"
        )
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = true
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "iMessage Relay", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "iMessage Relay")
        let quitItem = NSMenuItem(title: "Quit iMessage Relay", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        NSApp.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.refresh()
        menu.removeAllItems()
        menu.addItem(disabledItem("iMessage Relay \(packageVersion)"))
        menu.addItem(disabledItem(relay.state.description))
        if let menuError {
            menu.addItem(disabledItem(menuError))
        }
        menu.addItem(.separator())
        let toggle = menuItem(
            relay.state.isEnabled ? "Stop Relay" : "Start Relay",
            action: #selector(toggleRelay)
        )
        toggle.isEnabled = relay.state.canChange
        menu.addItem(toggle)
        menu.addItem(menuItem(loginItem.title, action: #selector(toggleLoginItem)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings...", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit iMessage Relay", action: #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleRelay() {
        if relay.state.isEnabled { relay.stop() } else { relay.start() }
    }

    @objc private func toggleLoginItem() {
        do {
            try loginItem.toggle()
            menuError = nil
        } catch {
            menuError = error.localizedDescription
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = RelayWindows.settingsTitle
            window.contentView = NSHostingView(rootView: SettingsView(
                relay: relay,
                loginItem: loginItem,
                permissions: permissions
            ))
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
