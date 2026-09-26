import Foundation
import Testing

@testable import RelayApp

@Test
@MainActor
func relayStaysOffOnLaterLaunches() {
    let suite = "relay-off-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }

    let firstLaunch = RelayController(preferences: preferences)
    firstLaunch.stop()
    #expect(preferences.bool(forKey: "relayShouldRun") == false)

    let laterLaunch = RelayController(preferences: preferences)
    laterLaunch.startOnLaunch()
    #expect(laterLaunch.state.description == "Stopped")
    #expect(!laterLaunch.state.isEnabled)
    #expect(laterLaunch.state.canChange)
}

@Test
@MainActor
func reloadingConfigurationDoesNotStartAStoppedRelay() {
    let suite = "relay-reload-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }

    let relay = RelayController(preferences: preferences)
    relay.stop()
    relay.reloadConfiguration()

    #expect(!preferences.bool(forKey: "relayShouldRun"))
    #expect(!relay.state.isEnabled)
}
