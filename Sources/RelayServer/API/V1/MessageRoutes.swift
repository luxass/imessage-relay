import Hummingbird
import RelayCore

struct MessageRoutes {
    let messages: MessageService
    let reactions: ReactionService

    func register(on router: Router<RelayRequestContext>) {
        router.get("/v1/messages/:message_id", use: get)
        router.get("/v1/requests/:request_id", use: getRequest)
        router.post("/v1/messages", use: send)
        router.put("/v1/messages/:message_id/reaction", use: setReaction)
        router.delete("/v1/messages/:message_id/reaction", use: clearReaction)
    }

    @Sendable private func setReaction(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let messageID: MessageID = try pathID("message_id", context: context)
        let payload = try await decodeJSONBody(SetReactionRequest.self, from: request)
        return try jsonResponse(
            try await reactions.set(
                messageID: messageID,
                request: payload,
                requestID: context.requestID
            )
        )
    }

    @Sendable private func clearReaction(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let messageID: MessageID = try pathID("message_id", context: context)
        return try jsonResponse(try await reactions.clear(messageID: messageID, requestID: context.requestID))
    }

    @Sendable private func getRequest(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let id: RelayCore.RequestID = try pathID("request_id", context: context)
        return try jsonResponse(try await messages.request(id: id))
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let id: MessageID = try pathID("message_id", context: context)
        return try jsonResponse(try await messages.get(id: id))
    }

    @Sendable private func send(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let payload = try await decodeJSONBody(SendMessageRequest.self, from: request)
        let result = try await messages.send(
            payload,
            requestID: context.requestID,
            idempotencyKey: request.headers[.init("idempotency-key")!]
        )
        return try jsonResponse(result, status: .accepted)
    }
}
