import Hummingbird
import HummingbirdRouter
import RelayCore

struct StatusController: RouterController {
    typealias Context = RelayRequestContext

    let store: MessageStore
    let sender: any MessageSending

    var body: some RouterMiddleware<Context> {
        Get("status", handler: status)
    }

    @Sendable private func status(
        _ request: Request,
        context: Context
    ) async -> StatusResponse {
        let database = await store.status()
        if let error = database.error {
            context.logger.error("Messages database unavailable", metadata: ["error": "\(error)"])
        }
        return StatusResponse(
            version: packageVersion,
            database: database,
            sender: .init(
                available: sender.isAvailable,
                capabilities: sender.capabilities,
                automationPermission: "unknown"
            )
        )
    }
}
