import ArgumentParser
import Foundation
import RelayServer

@main
struct RelayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-relay",
        abstract: "Expose the local Messages database and sender through the /v1 API.",
        version: packageVersion
    )

    @Option(name: .shortAndLong)
    var hostname = "127.0.0.1"

    @Option(name: .shortAndLong)
    var port = 8080

    func run() async throws {
        try await runRelayServer(
            hostname: hostname,
            port: port,
            config: ServerConfig.fromEnvironment()
        )
    }
}
