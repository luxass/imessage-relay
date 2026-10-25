import AppKit
import Combine
import Foundation
import RelayCore
import RelayServer

enum RelayState {
    case stopped
    case starting
    case running(String)
    case retrying(String)
    case restarting
    case stopping
    case needsToken
    case tokenError(String)

    var description: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting..."
        case .running(let address): "Running on \(address)"
        case .retrying(let error): "Error: \(error). Retrying..."
        case .restarting: "Reloading..."
        case .stopping: "Stopping..."
        case .needsToken: "No API token. Open Settings to add one."
        case .tokenError(let error): "Keychain: \(error). Retrying..."
        }
    }

    var isEnabled: Bool {
        switch self {
        case .starting, .running, .retrying, .restarting, .tokenError: true
        case .stopped, .stopping, .needsToken: false
        }
    }

    var canChange: Bool {
        switch self {
        case .stopping, .restarting: false
        default: true
        }
    }
}

private enum RelayStartupError: LocalizedError {
    case databaseUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let detail):
            "Messages database unavailable: \(detail). Check Full Disk Access in Settings > Permissions."
        }
    }
}

/// Starts and stops the server. Views observe one lifecycle state rather than
/// keeping separate copies of the desired state and task status.
@MainActor
final class RelayController: ObservableObject {
    let tokenStore = KeychainTokenStore()

    @Published private(set) var state: RelayState = .stopped
    @Published private(set) var address = "Unavailable"

    private let preferences: UserDefaults
    private var serverTask: Task<Void, Never>?
    private var didStartOnLaunch = false

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    func startOnLaunch() {
        guard !didStartOnLaunch else { return }
        didStartOnLaunch = true
        if preferences.object(forKey: "relayShouldRun") as? Bool ?? true {
            start()
        }
    }

    func start() {
        guard serverTask == nil else { return }
        preferences.set(true, forKey: "relayShouldRun")
        state = .starting
        serverTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let configuration = try ManagedConfigurationStore.loadOrCreate()
                    address = "\(configuration.hostname):\(configuration.port)"
                    let token = try tokenStore.read()
                    guard let token else {
                        serverTask = nil
                        state = .needsToken
                        return
                    }
                    let serverConfig = try configuration.serverConfiguration(token: token)
                    try await requireMessagesDatabase()
                    guard !Task.isCancelled else { break }
                    state = .running(address)
                    try await runRelayServer(
                        hostname: configuration.hostname,
                        port: configuration.port,
                        config: serverConfig
                    )
                    if Task.isCancelled { break }
                    // A clean return is the server's graceful signal shutdown.
                    NSApp.terminate(nil)
                    return
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled else { break }
                    if error is KeychainTokenError {
                        state = .tokenError(error.localizedDescription)
                    } else {
                        state = .retrying(error.localizedDescription)
                    }
                }

                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
            }
            let shouldRestart: Bool
            if case .restarting = state {
                shouldRestart = true
            } else {
                shouldRestart = false
            }
            serverTask = nil
            if shouldRestart {
                start()
            } else {
                state = .stopped
            }
        }
    }

    func stop() {
        preferences.set(false, forKey: "relayShouldRun")
        guard let serverTask else {
            state = .stopped
            return
        }
        state = .stopping
        serverTask.cancel()
    }

    func reloadConfiguration() {
        guard let serverTask else { return }
        state = .restarting
        serverTask.cancel()
    }

    func applyTokenChange() {
        if case .needsToken = state {
            start()
        } else if state.isEnabled {
            reloadConfiguration()
        }
    }

    func cancelForTermination() {
        state = .stopping
        serverTask?.cancel()
    }

    private func requireMessagesDatabase() async throws {
        let storage = MessagesStorage(path: ManagedConfiguration.messagesDatabasePath)
        let status = await storage.databaseStatus()
        try await storage.shutdown()
        guard status.ready else {
            throw RelayStartupError.databaseUnavailable(status.error ?? "Cannot read chat.db")
        }
    }
}
