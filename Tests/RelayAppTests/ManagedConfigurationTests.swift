import Foundation
import Testing

@testable import RelayApp

@Test
func managedConfigurationUsesSecureDefaultsForMissingFields() throws {
    let configuration = try JSONDecoder().decode(
        ManagedConfiguration.self,
        from: Data("{}".utf8)
    )
    _ = try configuration.serverConfiguration(token: "secret")

    #expect(configuration.hostname == "127.0.0.1")
    #expect(configuration.port == 8080)
    #expect(configuration.allowRemoteConnections == false)
    #expect(configuration.allowedRecipients.isEmpty)
    #expect(configuration.maximumMediaBytes == 25 * 1024 * 1024)
}

@Test
func managedConfigurationRequiresAnExplicitRemoteBindingOptIn() throws {
    let blocked = ManagedConfiguration(hostname: "0.0.0.0")
    #expect(throws: ManagedConfigurationError.remoteConnectionsRequireOptIn) {
        try blocked.serverConfiguration(token: "secret")
    }

    let allowed = ManagedConfiguration(
        hostname: "0.0.0.0",
        allowRemoteConnections: true
    )
    _ = try allowed.serverConfiguration(token: "secret")
}

@Test
func managedConfigurationRejectsUnsafeLimits() {
    let invalidPort = ManagedConfiguration(port: 0)
    #expect(throws: ManagedConfigurationError.invalidPort) {
        try invalidPort.serverConfiguration(token: "secret")
    }

    let invalidMediaLimit = ManagedConfiguration(maximumMediaBytes: 25 * 1024 * 1024 + 1)
    #expect(throws: ManagedConfigurationError.invalidMediaLimit) {
        try invalidMediaLimit.serverConfiguration(token: "secret")
    }
}
