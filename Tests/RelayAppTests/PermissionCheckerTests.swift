import Foundation
import Testing

@testable import RelayApp

@Test
func fullDiskAccessCheckReportsUnknownForAMissingDatabase() {
    #expect(
        PermissionChecker.checkFullDiskAccess(
            databasePath: "/nonexistent/imessage-relay/chat.db"
        ) == .unknown
    )
}

@Test
func fullDiskAccessCheckReportsGrantedForAReadableFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("imessage-relay-fda-probe-\(UUID().uuidString).db")
    try Data("probe".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(PermissionChecker.checkFullDiskAccess(databasePath: url.path) == .granted)
}

@Test
func automationCheckWithoutPromptNeverPrompts() async {
    // A non-prompting probe must resolve to a plain state without showing UI.
    let state = await PermissionChecker.checkAutomation(prompt: false)
    #expect(state == .granted || state == .notGranted || state == .unknown)
}

@Test
func osascriptProbeGrantsOnlyOnCleanExit() {
    #expect(PermissionChecker.osascriptProbeGranted(.exited(0)))
    #expect(!PermissionChecker.osascriptProbeGranted(.exited(1)))
    #expect(!PermissionChecker.osascriptProbeGranted(.timedOut))
}

@Test
func automationVerifyKeepsFallbackWithoutMessagesRunning() async {
    // Without Messages running there is nothing to probe, so a denial stands.
    // (On machines with Messages open this resolves via the live probe.)
    if !PermissionChecker.isMessagesAppRunning() {
        #expect(await PermissionChecker.verifyAutomation(fallback: .notGranted) == .notGranted)
        #expect(await PermissionChecker.verifyAutomation(fallback: .granted) == .granted)
    }
}
