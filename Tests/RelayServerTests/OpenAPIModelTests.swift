import Foundation
import HummingbirdOpenAPIModels
import OpenAPIKit
import RelayCore
import Testing

@Test
func openAPIMessageNullRulesMatchTheExistingCustomEncoder() throws {
    let message = try #require(testMessages().first)
    let schema = try modelSchema(Message.self, direction: .response)
    let required = Set(try #require(schema["required"] as? [String]))
    let explicitNull = Set(["provider_guid", "text", "sender", "created_at", "delivered_at", "read_at", "thread", "parts"])
    #expect(explicitNull.isSubset(of: required))
    #expect(!required.contains("url_preview"))
    #expect(!required.contains("is_audio_message"))
    let wire = try jsonValue(message)
    #expect(required.isSubset(of: Set(wire.keys)))
    #expect(wire["delivered_at"] is NSNull)
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(Set(properties["text"]?["type"] as? [String] ?? []) == ["string", "null"])
}

@Test
func openAPIReceiptAndReactionNullsDifferFromSynthesizedResponseOmission() throws {
    let id = try RequestID(validating: "request")
    let receipt = MediaReceipt(requestedMediaID: try MediaID(validating: "upload"), mediaID: nil, messageID: nil)
    #expect(try jsonValue(receipt)["media_id"] is NSNull)
    let receiptSchema = try modelSchema(MediaReceipt.self, direction: .response)
    #expect(Set(receiptSchema["required"] as? [String] ?? []) == ["requested_media_id", "media_id", "message_id"])
    let reaction = ReactionWriteResponse(requestID: id, status: .unchanged, messageID: try MessageID(validating: "message"), reaction: nil)
    #expect(try jsonValue(reaction)["reaction"] is NSNull)
    let response = SendMessageResponse.tracking(requestID: id, status: .accepted)
    #expect(try jsonValue(response)["conversation_id"] == nil)
    let responseSchema = try modelSchema(SendMessageResponse.self, direction: .response)
    #expect(!(responseSchema["required"] as? [String] ?? []).contains("conversation_id"))
}

@Test
func openAPICustomMediaDefaultsAndGenericPaginationMatchTheCodecs() throws {
    let input = Data(#"{"media_id":"media","source":"upload","is_sticker":null}"#.utf8)
    let reference = try RelayJSON.decoder.decode(MediaReference.self, from: input)
    #expect(reference.isSticker == false)
    let request = try modelSchema(MediaReference.self, direction: .request)
    #expect(!(request["required"] as? [String] ?? []).contains("is_sticker"))
    let response = try modelSchema(MediaReference.self, direction: .response)
    #expect((response["required"] as? [String] ?? []).contains("is_sticker"))
    let page = PaginatedResponse<Conversation>(items: [], nextCursor: nil, hasMore: false)
    #expect(try jsonValue(page)["next_cursor"] == nil)
    let pageSchema = try modelSchema(PaginatedResponse<Conversation>.self, direction: .response)
    #expect(Set(pageSchema["required"] as? [String] ?? []) == ["items", "has_more"])
}

@Test
func openAPICustomMessagePartVariantsPreserveTheirActualWireShape() throws {
    let parts: [MessagePart] = [.text(index: 0, text: "Hello"), .attachment(index: 1, attachment: nil), .unknown(index: 2)]
    for part in parts {
        #expect(try RelayJSON.decoder.decode(MessagePart.self, from: RelayJSON.encoder.encode(part)) == part)
    }
    #expect(try jsonValue(parts[1])["attachment"] is NSNull)
    #expect(try jsonValue(parts[2])["text"] == nil)
    let schema = try modelSchema(MessagePart.self, direction: .response)
    let variants = try #require(schema["oneOf"] as? [[String: Any]])
    #expect(variants.count == 3)
    let attachment = try #require(variants.first { ($0["required"] as? [String] ?? []).contains("attachment") })
    #expect(Set(attachment["required"] as? [String] ?? []) == ["index", "type", "attachment"])
    let decoded = try RelayJSON.decoder.decode(MessagePart.self, from: Data(#"{"index":1,"type":"attachment"}"#.utf8))
    #expect(decoded == .attachment(index: 1, attachment: nil))
}

@Test
func openAPISendRequestDescribesFlatteningAndNonNullDestinationExclusivity() throws {
    for json in [
        #"{"to":"friend@example.com","text":"Hello"}"#,
        #"{"conversation_id":"chat","to":null,"text":"Hello"}"#,
        #"{"participants":["a@example.com","b@example.com"],"text":"Hello"}"#,
    ] {
        let request = try RelayJSON.decoder.decode(SendMessageRequest.self, from: Data(json.utf8))
        #expect(try jsonValue(request)["destination"] == nil)
    }
    for json in [
        #"{"text":"Hello"}"#,
        #"{"conversation_id":"chat","to":"friend@example.com","text":"Hello"}"#,
        #"{"participants":[],"text":"Hello"}"#,
        #"{"to":"friend@example.com","extra":true}"#,
    ] {
        #expect(throws: (any Error).self) { try RelayJSON.decoder.decode(SendMessageRequest.self, from: Data(json.utf8)) }
    }
    let schema = try modelSchema(SendMessageRequest.self, direction: .request)
    let all = try #require(schema["allOf"] as? [[String: Any]])
    #expect(all.first?["additionalProperties"] as? Bool == false)
    let choices = try #require(all.last?["oneOf"] as? [[String: Any]])
    #expect(choices.count == 3)
    #expect(Set(choices.flatMap { $0["required"] as? [String] ?? [] }) == ["conversation_id", "to", "participants"])
}

private func modelSchema<Value: OpenAPISchemaProviding>(_ type: Value.Type, direction: SchemaDirection) throws -> [String: Any] {
    let context = SchemaContext()
    _ = try context.schema(for: type, direction: direction)
    let object = try jsonValue(context.components)
    let name = try #require(type.openAPIComponentName)
    return try #require(object[name] as? [String: Any])
}

private func jsonValue<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: RelayJSON.encoder.encode(value)) as? [String: Any])
}
