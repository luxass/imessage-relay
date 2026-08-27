import Hummingbird
import HummingbirdRouter
import RelayCore

struct StatusController: RouterController {
    typealias Context = RelayRequestContext

    let store: StoreProvider
    let capabilities: [String]

    var body: some RouterMiddleware<Context> {
        Get("status", handler: status)
    }

    @Sendable private func status(
        _ request: Request,
        context: Context
    ) -> StatusResponse {
        StatusResponse(
            version: packageVersion,
            database: store.status(),
            sender: .init(
                available: !capabilities.isEmpty,
                capabilities: capabilities
            )
        )
    }
}
