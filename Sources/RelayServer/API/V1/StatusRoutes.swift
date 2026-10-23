import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct StatusRoutes {
    let database: any DatabaseStatusProviding
    let sender: any MessageSender

    static let endpoint = JSONEndpoint<ServiceStatus>(
        method: .get, path: "/v1/status", operationID: "getStatus", summary: "Read service, database, and sender status.",
        description: "Reports readiness and sender permissions without running AppleScript or requesting permissions. "
            + "A database that is not ready is represented in the 200 response, not as an HTTP failure.",
        tags: ["Status"], responses: V1OpenAPI.responses(description: "Service, database, and sender status."),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    func register(on router: Router<RelayRequestContext>) {
        Self.endpoint.register(on: router, use: status)
    }

    @Sendable private func status(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<ServiceStatus> {
        async let databaseStatus = database.databaseStatus()
        async let senderStatus = sender.status()
        let status = await ServiceStatus(
            version: packageVersion,
            healthy: databaseStatus.ready,
            database: databaseStatus,
            sender: senderStatus
        )
        return relayJSONResponse(status, requestID: context.requestID)
    }
}
