import Hummingbird
import RelayCore

struct ConversationRoutes {
    let conversations: ConversationService
    let messages: MessageService
    let typing: TypingService

    func register(on router: Router<RelayRequestContext>) {
        router.get("/v1/conversations", use: list)
        router.get("/v1/conversations/:conversation_id", use: get)
        router.get("/v1/conversations/:conversation_id/messages", use: listMessages)
        router.put("/v1/conversations/:conversation_id/read", use: markRead)
        router.put("/v1/conversations/:conversation_id/typing", use: startTyping)
        router.delete("/v1/conversations/:conversation_id/typing", use: stopTyping)
    }

    @Sendable private func startTyping(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let raw = try pathValue("conversation_id", context: context)
        let id = try ConversationID(validating: raw)
        return try jsonResponse(
            try await typing.start(conversationID: id, requestID: context.requestID),
            requestID: context.requestID
        )
    }

    @Sendable private func stopTyping(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let raw = try pathValue("conversation_id", context: context)
        let id = try ConversationID(validating: raw)
        return try jsonResponse(
            try await typing.stop(conversationID: id, requestID: context.requestID),
            requestID: context.requestID
        )
    }

    @Sendable private func markRead(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> Response {
        let raw = try pathValue("conversation_id", context: context)
        let id = try ConversationID(validating: raw)
        return try jsonResponse(
            try await conversations.markRead(id: id, requestID: context.requestID),
            requestID: context.requestID
        )
    }

    @Sendable private func list(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let participant = try V1Query.string(request, "participant").map(RecipientHandle.direct(value:))
        let page = try await conversations.list(
            limit: V1Query.limit(request, default: 20),
            cursor: V1Query.cursor(request),
            unreadOnly: V1Query.bool(request, "unread_only"),
            participant: participant
        )
        return try jsonResponse(page, requestID: context.requestID)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let raw = try pathValue("conversation_id", context: context)
        let id = try ConversationID(validating: raw)
        return try jsonResponse(try await conversations.get(id: id), requestID: context.requestID)
    }

    @Sendable private func listMessages(_ request: Request, context: RelayRequestContext) async throws -> Response {
        let raw = try pathValue("conversation_id", context: context)
        let conversationID = try ConversationID(validating: raw)
        let rawMode = V1Query.string(request, "search_mode") ?? MessageSearchMode.contains.rawValue
        guard let searchMode = MessageSearchMode(rawValue: rawMode) else {
            throw APIHTTPError(
                status: .badRequest,
                code: .invalidRequest,
                message: "search_mode must be contains or exact.",
                fieldDetails: [APIFieldError(field: "search_mode", message: "Use contains or exact.")]
            )
        }
        let page = try await messages.list(
            conversationID: conversationID,
            options: MessageListOptions(
                limit: V1Query.limit(request, default: 50),
                cursor: V1Query.cursor(request),
                includeAttachments: V1Query.bool(request, "include_attachments"),
                search: V1Query.string(request, "q"),
                searchMode: searchMode
            )
        )
        return try jsonResponse(page, requestID: context.requestID)
    }
}
