import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct MessageRoutes {
    let messages: MessageService
    let reactions: ReactionService

    func register(on router: Router<RelayRequestContext>) {
        Self.searchEndpoint.register(on: router, use: search)
        Self.getEndpoint.register(on: router, use: get)
        Self.requestEndpoint.register(on: router, use: getRequest)
        Self.sendEndpoint.register(on: router, use: send)
        Self.setReactionEndpoint.register(on: router, use: setReaction)
        Self.clearReactionEndpoint.register(on: router, use: clearReaction)
    }

    @Sendable private func setReaction(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<ReactionWriteResponse> {
        let messageID: MessageID = try pathID("message_id", context: context)
        let payload = try await decodeJSONBody(SetReactionRequest.self, from: request)
        return relayJSONResponse(
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
    ) async throws -> JSONResponse<ReactionWriteResponse> {
        let messageID: MessageID = try pathID("message_id", context: context)
        return relayJSONResponse(try await reactions.clear(messageID: messageID, requestID: context.requestID))
    }

    @Sendable private func getRequest(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<SendMessageResponse> {
        let id: RelayCore.RequestID = try pathID("request_id", context: context)
        return relayJSONResponse(try await messages.request(id: id))
    }

    @Sendable private func search(
        _ request: Request, context: RelayRequestContext
    ) async throws -> JSONResponse<PaginatedResponse<Message>> {
        relayJSONResponse(try await messages.list(
            conversationID: nil, options: V1Query.messageOptions(request, requiresSearch: true)
        ))
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<Message> {
        let id: MessageID = try pathID("message_id", context: context)
        return relayJSONResponse(try await messages.get(id: id))
    }

    @Sendable private func send(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<SendMessageResponse> {
        let payload = try await decodeJSONBody(SendMessageRequest.self, from: request)
        let result = try await messages.send(
            payload,
            requestID: context.requestID,
            idempotencyKey: request.headers[.init("idempotency-key")!]
        )
        return relayJSONResponse(result, status: .accepted)
    }
}
