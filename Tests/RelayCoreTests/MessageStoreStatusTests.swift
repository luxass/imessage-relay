import Testing

@testable import RelayCore

@Test
func statusReportsReadyDatabaseAndFingerprint() throws {
    let fixture = try MessageDatabaseFixture()
    let status = try fixture.makeStore().status()

    #expect(status.ready)
    #expect(status.error == nil)
    #expect(status.fingerprint.contains("pages="))
}
