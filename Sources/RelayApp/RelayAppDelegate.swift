import AppKit
import RelayServer
import ServiceManagement

@main
@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    private let keychain = KeychainTokenStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private let runMenuItem = NSMenuItem(title: "Stop Relay", action: nil, keyEquivalent: "")
    private let loginItemMenuItem = NSMenuItem(
        title: "Start at Login",
        action: nil,
        keyEquivalent: ""
    )
    private var serverTask: Task<Void, Never>?
    private var relayEnabled = true

    static func main() {
        let application = NSApplication.shared
        let delegate = RelayAppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        registerLoginItemOnFirstLaunch()
        startRelay()
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverTask?.cancel()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right.fill",
                accessibilityDescription: "iMessage Relay"
            )
            button.toolTip = "iMessage Relay"
        }

        statusMenuItem.isEnabled = false
        runMenuItem.target = self
        runMenuItem.action = #selector(toggleRelay)
        loginItemMenuItem.target = self
        loginItemMenuItem.action = #selector(toggleLoginItem)

        let menu = NSMenu()
        menu.addItem(withTitle: "iMessage Relay \(packageVersion)", action: nil, keyEquivalent: "")
        menu.items.last?.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(runMenuItem)
        menu.addItem(loginItemMenuItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Reload Configuration",
            action: #selector(reloadConfiguration),
            keyEquivalent: "r"
        ).target = self
        menu.addItem(
            withTitle: "Open Configuration File",
            action: #selector(openConfiguration),
            keyEquivalent: ","
        ).target = self
        menu.addItem(
            withTitle: "Copy API Token",
            action: #selector(copyAPIToken),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Open Full Disk Access Settings",
            action: #selector(openFullDiskAccessSettings),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit iMessage Relay",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        statusItem.menu = menu
        refreshLoginItemState()
    }

    private func startRelay() {
        guard serverTask == nil else { return }
        relayEnabled = true
        runMenuItem.title = "Stop Relay"
        runMenuItem.isEnabled = true
        serverTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let managedConfiguration = try ManagedConfigurationStore.loadOrCreate()
                    let token = try keychain.loadOrCreate()
                    let configuration = try managedConfiguration.serverConfiguration(token: token)
                    setStatus("Running on \(managedConfiguration.hostname):\(managedConfiguration.port)")
                    try await runRelayServer(
                        hostname: managedConfiguration.hostname,
                        port: managedConfiguration.port,
                        config: configuration
                    )
                    if !Task.isCancelled {
                        setStatus("Server stopped; retrying...")
                    }
                } catch is CancellationError {
                    break
                } catch {
                    setStatus("Error: \(error.localizedDescription). Retrying...")
                }

                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
            }
            setStatus(relayEnabled ? "Server stopped" : "Stopped")
            serverTask = nil
            runMenuItem.isEnabled = true
        }
    }

    private func stopRelay() {
        relayEnabled = false
        serverTask?.cancel()
        runMenuItem.title = "Start Relay"
        runMenuItem.isEnabled = false
        setStatus("Stopping...")
    }

    private func setStatus(_ title: String) {
        statusMenuItem.title = title
        statusItem.button?.toolTip = "iMessage Relay: \(title)"
    }

    private func registerLoginItemOnFirstLaunch() {
        let preferenceKey = "loginItemPreferenceSet"
        guard !UserDefaults.standard.bool(forKey: preferenceKey), isInstalledInApplications else {
            refreshLoginItemState()
            return
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: preferenceKey)
        } catch {
            setStatus("Could not enable Start at Login: \(error.localizedDescription)")
        }
        refreshLoginItemState()
    }

    private var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true).path + "/")
    }

    private func refreshLoginItemState() {
        let service = SMAppService.mainApp
        loginItemMenuItem.state = service.status == .enabled ? .on : .off
        if service.status == .requiresApproval {
            loginItemMenuItem.title = "Approve Start at Login..."
        } else {
            loginItemMenuItem.title = "Start at Login"
        }
    }

    @objc private func toggleRelay() {
        if relayEnabled {
            stopRelay()
        } else {
            startRelay()
        }
    }

    @objc private func reloadConfiguration() {
        let previousTask = serverTask
        previousTask?.cancel()
        relayEnabled = true
        runMenuItem.title = "Stop Relay"
        setStatus("Reloading...")
        Task { [weak self] in
            await previousTask?.value
            self?.startRelay()
        }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                UserDefaults.standard.set(true, forKey: "loginItemPreferenceSet")
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notFound, .notRegistered:
                guard isInstalledInApplications else {
                    setStatus("Move iMessage Relay to Applications before enabling Start at Login")
                    return
                }
                try service.register()
                UserDefaults.standard.set(true, forKey: "loginItemPreferenceSet")
            @unknown default:
                setStatus("Unknown Start at Login state")
            }
        } catch {
            setStatus("Start at Login failed: \(error.localizedDescription)")
        }
        refreshLoginItemState()
    }

    @objc private func openConfiguration() {
        do {
            _ = try ManagedConfigurationStore.loadOrCreate()
            NSWorkspace.shared.open(ManagedConfigurationStore.configurationURL)
        } catch {
            setStatus("Could not open configuration: \(error.localizedDescription)")
        }
    }

    @objc private func copyAPIToken() {
        do {
            let token = try keychain.loadOrCreate()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(token, forType: .string)
            pasteboard.setData(
                Data(),
                forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            )
            pasteboard.setData(
                Data(),
                forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            )
            let changeCount = pasteboard.changeCount
            setStatus("API token copied; clipboard clears in 60 seconds")
            Task {
                try? await Task.sleep(for: .seconds(60))
                if pasteboard.changeCount == changeCount {
                    pasteboard.clearContents()
                }
            }
        } catch {
            setStatus("Could not read API token: \(error.localizedDescription)")
        }
    }

    @objc private func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
