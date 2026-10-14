import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct StatusRoutes {
    let database: any DatabaseStatusProviding
    let sender: any MessageSender

    func register(on routes: JSONRoutes<RelayRequestContext>) {
        Self.register(on: routes, use: status)
    }

    static func register(
        on routes: JSONRoutes<RelayRequestContext>,
        use handler: @escaping @Sendable (Request, RelayRequestContext) async throws -> StatusPayload
    ) {
        routes.get(
            "/v1/status",
            info: .init(operationID: "getStatus", summary: "Read service status", tag: "Status", anchor: "read-service-status"),
            use: handler
        )
    }

    @Sendable private func status(_ request: Request, context: RelayRequestContext) async throws -> StatusPayload {
        async let databaseStatus = database.databaseStatus()
        async let senderStatus = sender.status()
        let status = await ServiceStatus(
            version: packageVersion,
            healthy: databaseStatus.ready,
            database: databaseStatus,
            sender: senderStatus
        )
        return StatusPayload(status)
    }
}
