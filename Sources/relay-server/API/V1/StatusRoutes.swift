import Hummingbird
import RelayCore

struct StatusRoutes {
    let database: any DatabaseStatusProviding
    let sender: any MessageSender

    func register(on router: Router<RelayRequestContext>) {
        router.get("/v1/status", use: status)
    }

    @Sendable private func status(_ request: Request, context: RelayRequestContext) async throws -> Response {
        async let databaseStatus = database.databaseStatus()
        async let senderStatus = sender.status()
        let status = await ServiceStatus(
            version: packageVersion,
            healthy: databaseStatus.ready,
            database: databaseStatus,
            sender: senderStatus
        )
        return try jsonResponse(status, requestID: context.requestID)
    }
}
