import ArgumentParser
import Hummingbird
import RelayCore

@main
struct HummingbirdArguments: AsyncParsableCommand {
    @Option(name: .shortAndLong)
    var hostname: String = "127.0.0.1"

    @Option(name: .shortAndLong)
    var port: Int = 8080

    func run() async throws {
        let serverConfig = ServerConfig.fromEnvironment()
        let app = buildApplication(
            configuration: .init(
                address: .hostname(self.hostname, port: self.port),
                serverName: "imessage-relay"
            ),
            serverConfig: serverConfig,
            store: MessageStore(path: serverConfig.databasePath),
            sender: MessageSender()
        )
        try await app.runService()
    }
}
