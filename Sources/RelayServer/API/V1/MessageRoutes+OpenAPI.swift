import Hummingbird
import HummingbirdOpenAPI
import OpenAPIKit
import RelayCore

extension MessageRoutes {
    static let searchEndpoint = JSONEndpoint<PaginatedResponse<Message>>(
        method: .get, path: "/v1/messages", operationID: "searchMessages", summary: "Search text across conversations.",
        description: "Requires nonblank q. Uses current decoded text with case- and diacritic-insensitive matching. "
            + "Each result includes one visible conversation. Newest candidates sort first, with bounded continuation pages "
            + "that can be empty while has_more is true. Cursors are bound to the database, scope, and search options.",
        tags: ["Messages"], parameters: V1OpenAPI.messageOptions(requiresSearch: true),
        responses: V1OpenAPI.responses(description: "A page of matching messages.", errors: [.badRequest, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let scheduledEndpoint = JSONEndpoint<PaginatedResponse<Message>>(
        method: .get, path: "/v1/messages/scheduled", operationID: "listScheduledMessages",
        summary: "List pending native Send Later messages.",
        description: "Read-only, across visible conversations, earliest scheduled time first. "
            + "Recognizes schedule_type 2 and schedule_state 1, excluding past, sent, delivered, failed, and retracted rows. "
            + "Unknown provider states are omitted; unavailable schedule/sent-state columns return 501. "
            + "The queue is current state, not a snapshot. This operation cannot schedule, cancel, or reschedule messages.",
        tags: ["Messages"], parameters: [
            V1OpenAPI.limit(default: ConversationRoutes.messagePageLimit), V1OpenAPI.cursor,
            V1OpenAPI.boolean("include_attachments", description: "Include attachment metadata."),
        ],
        responses: V1OpenAPI.responses(description: "Messages with conversation_id and schedule.scheduled_at.",
            errors: [.badRequest, .notImplemented, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let getEndpoint = JSONEndpoint<Message>(
        method: .get, path: "/v1/messages/:message_id", operationID: "getMessage", summary: "Read one message.",
        tags: ["Messages"], parameters: [V1OpenAPI.identifier("message_id", type: MessageID.self)],
        responses: V1OpenAPI.responses(description: "The message and its provider metadata.",
            errors: [.badRequest, .notFound, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let requestEndpoint = JSONEndpoint<SendMessageResponse>(
        method: .get, path: "/v1/requests/:request_id", operationID: "getSendRequest", summary: "Read durable send request status.",
        description: "Retries provider-message identification for pending or partial correlation, "
            + "then refreshes identified message lifecycle states. "
            + "Durable request state survives relay restarts. Polling never sends the message again.",
        tags: ["Messages"], parameters: [V1OpenAPI.identifier("request_id", type: RelayCore.RequestID.self)],
        responses: V1OpenAPI.responses(description: "The current durable send result.",
            errors: [.badRequest, .notFound, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let sendEndpoint = JSONEndpoint<SendMessageResponse>(
        method: .post, path: "/v1/messages", operationID: "sendMessage", summary: "Submit a message send.",
        description: "Provide exactly one non-null destination. Every resolved participant must be allowlisted. "
            + "Participant sends require text and do not support media or reply_to. Use an existing conversation for native replies. "
            + "Reuse the same idempotency key for retries. A changed normalized request returns 409. "
            + "A 202 response is not proof of delivery. Poll poll_url for correlation and lifecycle status.",
        tags: ["Messages"],
        parameters: [.init(name: "Idempotency-Key", location: .header,
                           description: "Trimmed before use. Blank means no key. At most 128 UTF-8 bytes without control characters. "
                               + "The same key and normalized request return the stored result without dispatching again.",
                           schema: .string(maxLength: 128))],
        requestBody: .json(SendMessageRequest.self, description: "A destination, text or uploaded media, and an optional reply target.",
                           example: AnyCodable(["to": "friend@example.com", "text": "Hello"])),
        responses: V1OpenAPI.responses(success: .accepted, description: "Accepted send with a durable poll URL and correlation state.",
                                       errors: [.badRequest, .forbidden, .notFound, .conflict, .contentTooLarge,
                                                .unprocessableContent, .notImplemented, .badGateway, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let setReactionEndpoint = JSONEndpoint<ReactionWriteResponse>(
        method: .put, path: "/v1/messages/:message_id/reaction", operationID: "setReaction", summary: "Set the local sender's reaction.",
        description: "Uses the provider's default message part. Repeating the same reaction returns unchanged. "
            + "Success follows observation of the resulting outgoing reaction row. Refetch after a 502 result.",
        tags: ["Messages"], parameters: [V1OpenAPI.identifier("message_id", type: MessageID.self)],
        requestBody: .json(SetReactionRequest.self, description: "The reaction to set.", example: AnyCodable(["reaction": "love"])),
        responses: V1OpenAPI.responses(description: "The resulting local reaction state.",
                                       errors: [.badRequest, .notFound, .conflict, .contentTooLarge, .unprocessableContent,
                                                .notImplemented, .badGateway, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let clearReactionEndpoint = JSONEndpoint<ReactionWriteResponse>(
        method: .delete, path: "/v1/messages/:message_id/reaction", operationID: "clearReaction",
            summary: "Clear the local sender's reaction.",
        description: "No request body. Clearing an absent reaction returns unchanged. A successful result contains reaction: null.",
        tags: ["Messages"], parameters: [V1OpenAPI.identifier("message_id", type: MessageID.self)],
        responses: V1OpenAPI.responses(description: "The resulting local reaction state.",
                                       errors: [.badRequest, .notFound, .conflict, .notImplemented, .badGateway, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static var endpoints: [EndpointDefinition] {
        [searchEndpoint.definition, scheduledEndpoint.definition, getEndpoint.definition, requestEndpoint.definition, sendEndpoint.definition,
         setReactionEndpoint.definition, clearReactionEndpoint.definition]
    }
}
