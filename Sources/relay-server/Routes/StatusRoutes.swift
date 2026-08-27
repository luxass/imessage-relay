import Hummingbird
import RelayCore
import RelaySender

/// GET /status — readiness, database fingerprint, sender capabilities.
enum StatusRoutes {
    static func register(
        _ router: Router<BasicRequestContext>,
        store: StoreProvider,
        capabilities: [String]
    ) {
        router.get("status") { _, _ in
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
}
