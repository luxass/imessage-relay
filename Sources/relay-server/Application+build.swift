import Hummingbird
import HummingbirdRouter

let packageVersion = "0.1.0"

func buildApplication(
    configuration: ApplicationConfiguration
) async throws -> some ApplicationProtocol {
    let serverConfig = ServerConfig.fromEnvironment()
    let store = StoreProvider(path: serverConfig.databasePath)
    let sender = MessageSender()

    let router = RouterBuilder(context: RelayRequestContext.self) {
        LogRequestsMiddleware(.info)
        if let token = serverConfig.token {
            BearerAuthMiddleware(token: token)
        }
        StatusController(store: store, capabilities: sender.capabilities)
        ChatsController(store: store)
        MessagesController(store: store)
        AttachmentsController(store: store)
        SendController(store: store, sender: sender, config: serverConfig)
    }

    return Application(router: router, configuration: configuration)
}
