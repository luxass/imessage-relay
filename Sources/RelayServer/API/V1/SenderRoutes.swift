import Hummingbird
import HummingbirdOpenAPI
import OpenAPIKit
import RelayCore

struct SenderRoutes {
    let sender: any MessageSender

    static let endpoint = JSONEndpoint<Sender>(
        method: .get,
        path: "/v1/sender",
        operationID: "getSender",
        summary: "Read sender identity and capabilities.",
        tags: ["Status"],
        responses: [
            .success(.ok, description: "Current sender status."),
            .error(.unauthorized, body: APIError.self, description: "Missing or invalid bearer token."),
            .error(.internalServerError, body: APIError.self, description: "The request failed."),
        ],
        responseHeaders: [
            "X-Request-ID": .b(.init(schema: .string, description: "Request correlation identifier.", required: true)),
        ]
    )

    func register(on router: Router<RelayRequestContext>) {
        Self.endpoint.register(on: router, use: get)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<Sender> {
        relayJSONResponse(await sender.status(), requestID: context.requestID)
    }
}
