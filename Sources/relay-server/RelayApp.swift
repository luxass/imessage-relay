import Foundation
import Hummingbird
import RelayCore
import RelaySender

let packageVersion = "0.1.0"

@main
struct RelayApp {
    static func main() async throws {
        let config = ServerConfig.fromEnvironment()

        let store = StoreProvider(path: config.databasePath)
        let sender: any MessageSender = AppleScriptSender()

        let router = Router()
        API.register(
            on: router,
            store: store,
            sender: sender,
            policy: config.sendPolicy(),
            token: config.token
        )

        // Loopback only.
        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: config.port))
        )
        print("imessage-relay listening on http://127.0.0.1:\(config.port) (db: \(config.databasePath))")
        try await app.runService()
    }
}
