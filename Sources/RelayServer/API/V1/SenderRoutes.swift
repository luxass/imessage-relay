import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct SenderRoutes {
    let sender: any MessageSender

    static let endpoint = JSONEndpoint<Sender>(
        method: .get, path: "/v1/sender", operationID: "getSender", summary: "Read sender identity and capabilities.",
        tags: ["Status"], responses: V1OpenAPI.responses(description: "Current sender status."),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    func register(on router: Router<RelayRequestContext>) {
        Self.endpoint.register(on: router, use: get)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<Sender> {
        relayJSONResponse(await sender.status())
    }
}
