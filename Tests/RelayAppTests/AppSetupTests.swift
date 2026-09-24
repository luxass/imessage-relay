import Foundation
import Testing

@testable import RelayApp

@Test
func configurationWithoutTokenStillNeedsSetup() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let configurationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("setup-test-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: configurationURL)
    defer { try? FileManager.default.removeItem(at: configurationURL) }

    #expect(!AppSetup.isComplete(
        preferences: preferences,
        configurationURL: configurationURL,
        readToken: { nil }
    ))
}

@Test
func missingTokenRecoversFromAnEarlierCompletedMarker() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "setupCompleted")

    #expect(!AppSetup.isComplete(
        preferences: preferences,
        configurationURL: FileManager.default.temporaryDirectory,
        readToken: { nil }
    ))
}

@Test
func keychainErrorPreservesCompletedSetup() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "setupCompleted")

    #expect(AppSetup.isComplete(
        preferences: preferences,
        configurationURL: FileManager.default.temporaryDirectory,
        readToken: { throw KeychainTokenError.invalidStoredToken }
    ))
    #expect(preferences.bool(forKey: "setupCompleted"))
}

@Test
func disabledLegacyRelayWithoutTokenStillNeedsSetup() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(false, forKey: "relayShouldRun")
    let configurationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("setup-test-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: configurationURL)
    defer { try? FileManager.default.removeItem(at: configurationURL) }

    #expect(!AppSetup.isComplete(
        preferences: preferences,
        configurationURL: configurationURL,
        readToken: { nil }
    ))
}

@Test
func disabledLegacyRelayWithTokenKeepsCompletedSetup() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(false, forKey: "relayShouldRun")
    let configurationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("setup-test-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: configurationURL)
    defer { try? FileManager.default.removeItem(at: configurationURL) }

    #expect(AppSetup.isComplete(
        preferences: preferences,
        configurationURL: configurationURL,
        readToken: { "existing-token" }
    ))
    #expect(preferences.object(forKey: "relayShouldRun") as? Bool == false)
}

@Test
func disabledCompletedRelayWithoutTokenNeedsSetupAgain() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "setupCompleted")
    preferences.set(false, forKey: "relayShouldRun")

    #expect(!AppSetup.isComplete(
        preferences: preferences,
        configurationURL: FileManager.default.temporaryDirectory,
        readToken: { nil }
    ))
}

@Test
func setupResumesPermissionsAfterRelaunch() throws {
    let suite = "setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    AppSetup.markTokenReady(preferences: preferences)
    #expect(AppSetup.tokenReady(preferences: preferences))
    #expect(preferences.object(forKey: "setupCompleted") == nil)

    AppSetup.complete(preferences: preferences)
    #expect(!AppSetup.tokenReady(preferences: preferences))
}
