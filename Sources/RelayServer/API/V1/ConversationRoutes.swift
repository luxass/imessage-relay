import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct ConversationRoutes {
    let conversations: ConversationService
    let messages: MessageService
    let typing: TypingService

    func register(on router: Router<RelayRequestContext>) {
        Self.listEndpoint.register(on: router, use: list)
        Self.getEndpoint.register(on: router, use: get)
        Self.messagesEndpoint.register(on: router, use: listMessages)
        Self.readEndpoint.register(on: router, use: markRead)
        Self.startTypingEndpoint.register(on: router, use: startTyping)
        Self.stopTypingEndpoint.register(on: router, use: stopTyping)
    }

    @Sendable private func startTyping(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<ConversationTypingResponse> {
        let id: ConversationID = try pathID("conversation_id", context: context)
        return relayJSONResponse(try await typing.start(conversationID: id, requestID: context.requestID))
    }

    @Sendable private func stopTyping(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<ConversationTypingResponse> {
        let id: ConversationID = try pathID("conversation_id", context: context)
        return relayJSONResponse(try await typing.stop(conversationID: id, requestID: context.requestID))
    }

    @Sendable private func markRead(
        _ request: Request,
        context: RelayRequestContext
    ) async throws -> JSONResponse<ConversationReadResponse> {
        let id: ConversationID = try pathID("conversation_id", context: context)
        return relayJSONResponse(try await conversations.markRead(id: id, requestID: context.requestID))
    }

    @Sendable private func list(
        _ request: Request, context: RelayRequestContext
    ) async throws -> JSONResponse<PaginatedResponse<Conversation>> {
        let participant = try V1Query.string(request, "participant").map(RecipientHandle.direct(value:))
        let page = try await conversations.list(
            limit: V1Query.limit(request, default: 20),
            cursor: V1Query.cursor(request),
            unreadOnly: V1Query.bool(request, "unread_only"),
            participant: participant
        )
        return relayJSONResponse(page)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> JSONResponse<Conversation> {
        let id: ConversationID = try pathID("conversation_id", context: context)
        return relayJSONResponse(try await conversations.get(id: id))
    }

    @Sendable private func listMessages(
        _ request: Request, context: RelayRequestContext
    ) async throws -> JSONResponse<PaginatedResponse<Message>> {
        let conversationID: ConversationID = try pathID("conversation_id", context: context)
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
        return relayJSONResponse(page)
    }
}
