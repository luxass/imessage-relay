import Hummingbird
import HummingbirdOpenAPI
import RelayCore

struct ConversationRoutes {
    let conversations: ConversationService
    let messages: MessageService
    let typing: TypingService

    static let conversationPageLimit = 20
    static let messagePageLimit = 50

    func register(on router: Router<RelayRequestContext>) {
        Self.listEndpoint.register(on: router, use: list)
        Self.getEndpoint.register(on: router, use: get)
        Self.messagesEndpoint.register(on: router, use: listMessages)
        Self.countsEndpoint.register(on: router, use: counts)
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
            limit: V1Query.limit(request, default: Self.conversationPageLimit),
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

    @Sendable private func counts(
        _ request: Request, context: RelayRequestContext
    ) async throws -> JSONResponse<MessageCounts> {
        let conversationID: ConversationID = try pathID("conversation_id", context: context)
        let range: MessageCountRange
        do {
            range = try MessageCountRange(from: V1Query.timestamp(request, "from"), to: V1Query.timestamp(request, "to"))
        } catch RelayServiceError.invalidRequest(let fields) {
            throw APIHTTPError(status: .badRequest, code: .invalidRequest,
                               message: "The message-count range is invalid.", fieldDetails: fields)
        }
        return relayJSONResponse(try await messages.counts(conversationID: conversationID, range: range))
    }

    @Sendable private func listMessages(
        _ request: Request, context: RelayRequestContext
    ) async throws -> JSONResponse<PaginatedResponse<Message>> {
        let conversationID: ConversationID = try pathID("conversation_id", context: context)
        let page = try await messages.list(
            conversationID: conversationID, options: V1Query.messageOptions(request)
        )
        return relayJSONResponse(page)
    }
}
