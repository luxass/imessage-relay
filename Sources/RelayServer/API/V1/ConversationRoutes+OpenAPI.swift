import Hummingbird
import HummingbirdOpenAPI
import OpenAPIKit
import RelayCore

extension ConversationRoutes {
    static let listEndpoint = JSONEndpoint<PaginatedResponse<Conversation>>(
        method: .get, path: "/v1/conversations", operationID: "listConversations", summary: "Page through conversations.",
        description: "Newest messages sort first. Cursor values are opaque and bound to this exact filter and database.",
        tags: ["Conversations"],
        parameters: [
            V1OpenAPI.limit(default: conversationPageLimit), V1OpenAPI.cursor,
            V1OpenAPI.boolean("unread_only", description: "Return only conversations with unread messages."),
            .init(name: "participant", location: .query,
                  description: "Exact normalized phone number or email address. Email matching is case-insensitive.", schema: .string),
        ],
        responses: V1OpenAPI.responses(description: "A page of conversations.",
            errors: [.badRequest, .unprocessableContent, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let getEndpoint = JSONEndpoint<Conversation>(
        method: .get, path: "/v1/conversations/:conversation_id", operationID: "getConversation", summary: "Read one conversation.",
        tags: ["Conversations"], parameters: [V1OpenAPI.identifier("conversation_id", type: ConversationID.self)],
        responses: V1OpenAPI.responses(description: "The conversation.", errors: [.badRequest, .notFound, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let messagesEndpoint = JSONEndpoint<PaginatedResponse<Message>>(
        method: .get, path: "/v1/conversations/:conversation_id/messages", operationID: "listMessages",
            summary: "Page through conversation messages.",
        description: "Reactions are nested under their target messages. URL previews can be folded into the preceding text message.",
        tags: ["Messages"],
        parameters: [
            V1OpenAPI.identifier("conversation_id", type: ConversationID.self),
            V1OpenAPI.limit(default: messagePageLimit), V1OpenAPI.cursor,
            V1OpenAPI.boolean("include_attachments", description: "Include attachment metadata in messages and attachment parts."),
            .init(name: "q", location: .query,
            description: "Case-insensitive search of decoded message text in this conversation.", schema: .string),
            .init(name: "search_mode", location: .query, description: "Text search matching mode.",
                  schema: .string(
                    allowedValues: MessageSearchMode.allCases.map { AnyCodable($0.rawValue) },
                    defaultValue: AnyCodable(MessageSearchMode.contains.rawValue)
                  )),
        ],
        responses: V1OpenAPI.responses(description: "A page of messages.", errors: [.badRequest, .notFound, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let readEndpoint = JSONEndpoint<ConversationReadResponse>(
        method: .put, path: "/v1/conversations/:conversation_id/read", operationID: "markConversationRead",
            summary: "Mark a conversation as read.",
        description: "No request body. Success follows confirmation in chat.db. Stops active typing before the native action. "
            + "This confirms local state, not remote read receipt delivery. A 502 result requires a refetch before retrying.",
        tags: ["Conversations"], parameters: [V1OpenAPI.identifier("conversation_id", type: ConversationID.self)],
        responses: V1OpenAPI.responses(description: "The applied or unchanged read state.", errors: [.badRequest, .notFound, .conflict,
                .notImplemented, .badGateway, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let startTypingEndpoint = JSONEndpoint<ConversationTypingResponse>(
        method: .put, path: "/v1/conversations/:conversation_id/typing", operationID: "startTyping",
            summary: "Start or refresh a typing lease.",
        description: "No request body. The local lease lasts five seconds. Refresh about every three seconds. "
            + "Starting a lease stops the previous conversation's lease. A protected draft returns 409 without changing it. "
            + "Local active status does not prove remote delivery of an indicator.",
        tags: ["Conversations"], parameters: [V1OpenAPI.identifier("conversation_id", type: ConversationID.self)],
        responses: V1OpenAPI.responses(description: "The active typing lease.", errors: [.badRequest, .notFound, .conflict,
                                                                                       .notImplemented, .badGateway, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let stopTypingEndpoint = JSONEndpoint<ConversationTypingResponse>(
        method: .delete, path: "/v1/conversations/:conversation_id/typing", operationID: "stopTyping", summary: "Stop a typing lease.",
        description: "No request body. Clears only the relay-owned one-space marker. Does not discard a user's draft.",
        tags: ["Conversations"], parameters: [V1OpenAPI.identifier("conversation_id", type: ConversationID.self)],
        responses: V1OpenAPI.responses(description: "The inactive typing state.", errors: [.badRequest, .notFound, .conflict,
                .notImplemented, .badGateway, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static var endpoints: [EndpointDefinition] {
        [listEndpoint.definition, getEndpoint.definition, messagesEndpoint.definition, readEndpoint.definition,
         startTypingEndpoint.definition, stopTypingEndpoint.definition]
    }
}
