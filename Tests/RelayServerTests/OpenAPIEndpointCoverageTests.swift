import Foundation
import Hummingbird
import HummingbirdOpenAPIModels
import OpenAPIKit
import RelayCore
import Testing

@testable import RelayServer

@Test
func openAPIOperationsMatchEveryLiveRouteExactly() throws {
    let router = ServerTestHarness().router()
    try router.validate()
    let live = Set(router.routes.map { route in
        let path = "/" + route.path.description.split(separator: "/").map { segment in
            segment.hasPrefix(":") ? "{\(segment.dropFirst())}" : String(segment)
        }.joined(separator: "/")
        return "\(route.method.rawValue) \(path)"
    })
    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: relayOpenAPIDocumentData())
    let documented = Set(document.paths.flatMap { path, item in
        (item.b?.endpoints ?? []).map { "\($0.method.rawValue) \(path.rawValue)" }
    })
    #expect(live == documented)
    #expect(documented.count == 16)
    #expect(RelayAPIDocument.endpoints.count == 16)
}

@Test
func openAPIMediaUploadAndDownloadUseRawBodiesInsteadOfJSONStringSchemas() throws {
    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: relayOpenAPIDocumentData())
    let upload = try #require(document.paths["/v1/media"]?.b?.post)
    #expect(upload.responses[status: 201] != nil)
    let body = try #require(upload.requestBody?.b)
    #expect(body.required)
    #expect(body.content.count == 6)
    for content in body.content.values { #expect(content.b?.schema == nil) }
    let download = try #require(document.paths["/v1/media/{media_id}"]?.b?.get)
    let content = try #require(download.responses[status: 200]?.b?.content)
    #expect(content[.json]?.b?.schema != nil)
    #expect(content[.any]?.b?.schema == nil)
    #expect(download.responses[status: 200]?.b?.headers?["Content-Disposition"] != nil)
}

/// Checks fixture event names and payload keys against the exported SSE variants.
/// The final assertion compares fixture names with the enum schema built separately below.
@Test
func openAPISSEPayloadsMatchAllEmittedEventShapes() throws {
    let document = try #require(JSONSerialization.jsonObject(with: relayOpenAPIDocumentData()) as? [String: Any])
    let paths = try #require(document["paths"] as? [String: [String: [String: Any]]])
    let operation = try #require(paths["/v1/events"]?["get"])
    let responses = try #require(operation["responses"] as? [String: [String: Any]])
    #expect(responses["503"] != nil)
    let content = try #require(responses["200"]?["content"] as? [String: [String: Any]])
    let item = try #require(content["text/event-stream"]?["itemSchema"] as? [String: Any])
    let variants = try #require(item["oneOf"] as? [[String: Any]])
    #expect(variants.count == 8)
    let components = try #require(document["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: [String: Any]])
    let message = try MessageID(validating: "message")
    let conversation = try ConversationID(validating: "conversation")
    let observed = Timestamp(Date(timeIntervalSince1970: 0))
    let reaction = ReactionChangedEvent(messageID: message, reactionID: message, observedAt: observed)
    let events: [RelayEvent] = [
        .streamReady(.init(databaseIdentity: "fixture", replaySupported: true)),
        .messageCreated(.init(messageID: message, conversationID: conversation, isFromMe: false, observedAt: observed)),
        .messageUpdated(.init(messageID: message, conversationID: conversation, changedFields: [.deliveryState], observedAt: observed)),
        .reactionAdded(reaction), .reactionRemoved(reaction),
        .mediaAvailable(.init(messageID: message, mediaID: try MediaID(validating: "media"), observedAt: observed)),
        .streamReset(.init(reason: .replayUnavailable, message: "Refetch.")),
    ]
    for event in events {
        let fields = try #require(variants.compactMap { $0["properties"] as? [String: [String: Any]] }.first {
            $0["event"]?["const"] as? String == event.type.rawValue
        })
        #expect(fields["data"]?["type"] as? String == "string")
        #expect(fields["data"]?["contentMediaType"] as? String == "application/json")
        let payloadSchema = try #require(fields["data"]?["contentSchema"] as? [String: String])
        let name = try #require(payloadSchema["$ref"]?.split(separator: "/").last).description
        let payload = try #require(schemas[name])
        let frame = try serverSentEventFrame(.init(eventID: EventCursor(rawValue: "cursor:1"), event: event))
        #expect(frame.contains("event: \(event.type.rawValue)\n"))
        let line = try #require(frame.split(separator: "\n").first { $0.hasPrefix("data: ") })
        let json = Data(line.dropFirst(6).utf8)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let properties = try #require(payload["properties"] as? [String: Any])
        #expect(Set(object.keys).isSubset(of: Set(properties.keys)))
        #expect(Set(payload["required"] as? [String] ?? []).isSubset(of: Set(object.keys)))
    }
    let context = SchemaContext()
    _ = try context.schema(for: RelayEventType.self, direction: .response)
    let enumData = try RelayJSON.encoder.encode(context.components)
    let enumSchemas = try #require(JSONSerialization.jsonObject(with: enumData) as? [String: [String: Any]])
    #expect(Set(enumSchemas["RelayEventType_response"]?["enum"] as? [String] ?? []) == Set(events.map { $0.type.rawValue }))
}
