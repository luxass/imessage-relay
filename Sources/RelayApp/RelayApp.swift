import AppKit
import Foundation

@main
struct RelayApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = RelayAppDelegate()
        application.delegate = delegate
        application.finishLaunching()
        application.run()
    }
}

enum RelayWindows {
    static let setupTitle = "Set Up iMessage Relay"
    static let settingsTitle = "iMessage Relay Settings"
}

enum AppSetup {
    private static let key = "setupCompleted"
    private static let tokenReadyKey = "setupTokenReady"

    static var isComplete: Bool {
        isComplete(
            preferences: .standard,
            configurationURL: ManagedConfigurationStore.configurationURL,
            readToken: { try KeychainTokenStore().read() }
        )
    }

    static func isComplete(
        preferences: UserDefaults,
        configurationURL: URL,
        readToken: () throws -> String?
    ) -> Bool {
        if let saved = preferences.object(forKey: key) as? Bool {
            guard saved else { return false }
            do {
                if try readToken() != nil { return true }
                preferences.set(false, forKey: key)
                return false
            } catch {
                return true
            }
        }
        // Old versions created config.json before setup existed. Only treat
        // it as an existing installation if a token is also available.
        let hasConfiguration = FileManager.default.fileExists(atPath: configurationURL.path)
        let existingInstallation = hasConfiguration && (try? readToken()) != nil
        preferences.set(existingInstallation, forKey: key)
        return existingInstallation
    }

    static func tokenReady(preferences: UserDefaults = .standard) -> Bool {
        preferences.bool(forKey: tokenReadyKey)
    }

    static func markTokenReady(preferences: UserDefaults = .standard) {
        preferences.set(true, forKey: tokenReadyKey)
    }

    static func clearTokenReady(preferences: UserDefaults = .standard) {
        preferences.removeObject(forKey: tokenReadyKey)
    }

    static func complete(preferences: UserDefaults = .standard) {
        preferences.set(true, forKey: key)
        clearTokenReady(preferences: preferences)
    }
}
