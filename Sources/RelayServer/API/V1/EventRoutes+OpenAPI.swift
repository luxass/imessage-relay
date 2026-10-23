import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import OpenAPIKit
import RelayCore

extension EventRoutes {
    static let endpoint = RawEndpoint(EndpointDefinition(
        method: .get, path: "/v1/events", operationID: "streamEvents", summary: "Stream live message changes with server-sent events.",
        description: "One authenticated SSE stream. Event data contains stable resource IDs, not complete resources. "
            + "Reconnect with Last-Event-ID for bounded in-process replay. Replay does not survive a restart. "
            + "stream.reset can require a REST refetch or provide a safe replay cursor. Replayed events can be duplicated. "
            + "The stream starts with retry: 3000 and sends keep-alive comments every 15 seconds. Comments are ignored by SSE parsing. "
            + "Database and authentication failures before streaming starts use the normal JSON error shape.",
        tags: ["Events"],
        parameters: [.init(name: "Last-Event-ID", location: .header,
            description: "Last received SSE event ID for replay.", type: EventCursor.self)],
        responses: [EndpointResponse(.ok, description: "Parsed SSE frames. Each data field is a string containing a JSON payload.",
            headers: [
            "Cache-Control": .b(.init(schema: .string(allowedValues: "no-cache"), required: true)),
            "X-Accel-Buffering": .b(.init(schema: .string(allowedValues: "no"), required: true)),
        ]) { context in
            let events: [JSONSchema] = try [
                frame(.streamReady, payload: StreamReadyEvent.self, in: context),
                frame(.messageCreated, payload: MessageCreatedEvent.self, in: context),
                frame(.messageUpdated, payload: MessageUpdatedEvent.self, in: context),
                frame(.reactionAdded, payload: ReactionChangedEvent.self, in: context),
                frame(.reactionRemoved, payload: ReactionChangedEvent.self, in: context),
                frame(.mediaAvailable, payload: MediaAvailableEvent.self, in: context),
                frame(.streamReset, payload: StreamResetEvent.self, in: context),
            ]
            let retry = JSONSchema.object(properties: ["retry": .integer(allowedValues: 3000)], additionalProperties: .a(false))
            return [.eventStream: .b(.init(itemSchema: .one(of: events + [retry])))]
        }] + V1OpenAPI.rawErrors([.serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    ))

    private static func frame<Payload: OpenAPISchemaProviding>(
        _ event: RelayEventType, payload: Payload.Type, in context: SchemaContext
    ) throws -> JSONSchema {
        .object(properties: [
            "event": .string(allowedValues: AnyCodable(event.rawValue)),
            "id": .string(required: false),
            "data": try context.encodedJSONString(for: Payload.self, direction: .response),
        ])
    }
}
