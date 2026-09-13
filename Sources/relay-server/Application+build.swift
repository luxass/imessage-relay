import Hummingbird
import HummingbirdRouter
import Logging
import RelayCore
import ServiceLifecycle

let packageVersion = "0.1.0" // x-release-please-version

struct MessageStoreService: Service {
    let store: MessageStore

    func run() async throws {
        let shutdownReason: (any Error)?
        do {
            try await gracefulShutdown()
            shutdownReason = nil
        } catch {
            shutdownReason = error
        }

        do {
            try await store.shutdown()
        } catch {
            if let shutdownReason { throw shutdownReason }
            throw error
        }
        if let shutdownReason { throw shutdownReason }
    }
}

func buildApplication(
    configuration: ApplicationConfiguration,
    serverConfig: ServerConfig,
    store: MessageStore,
    sender: any MessageSending,
    logger: Logger? = nil
) -> some ApplicationProtocol {
    let router = RouterBuilder(context: RelayRequestContext.self) {
        RedactedRequestLogMiddleware()
        if let token = serverConfig.token {
            BearerAuthMiddleware(token: token)
        }
        StatusController(store: store, sender: sender)
        ChatsController(store: store)
        AttachmentsController(store: store)
        SendController(store: store, sender: sender, config: serverConfig)
    }

    return Application(
        router: router,
        configuration: configuration,
        services: [MessageStoreService(store: store)],
        logger: logger
    )
}
