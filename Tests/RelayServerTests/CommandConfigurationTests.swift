import XCTest

@testable import relay_server

final class CommandConfigurationTests: XCTestCase {
    func testCommandMetadataMatchesReleaseArtifact() {
        XCTAssertEqual(HummingbirdArguments.configuration.commandName, "relay-server")
        XCTAssertEqual(HummingbirdArguments.configuration.version, packageVersion)
    }
}
