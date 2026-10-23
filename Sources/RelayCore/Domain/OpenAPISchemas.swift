import HummingbirdOpenAPIModels
import OpenAPIKit

extension Timestamp: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue {
        .string(format: .dateTime)
    }
}

extension RelayIdentifier {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue {
        // These identifiers accept provider GUIDs as well as generated request IDs. They are not always UUIDs.
        .string(minLength: 1, pattern: #"^[^\p{Cc}\p{Cf}]+$"#)
    }
}

extension EventCursor: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .string }
}

extension MessagePart: OpenAPISchemaProviding {
    public static var openAPIComponentName: String? { "MessagePart" }

    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        let index = JSONSchema.integer(minimum: (0, exclusive: false))
        var attachment = try context.schema(for: MediaReference.self, direction: direction).nullableSchemaObject()
        if direction == .request { attachment = attachment.optionalSchemaObject() }
        return .one(of: [
            .object(properties: ["index": index, "type": .string(allowedValues: "text"), "text": .string]),
            .object(properties: ["index": index, "type": .string(allowedValues: "attachment"), "attachment": attachment]),
            .object(properties: ["index": index, "type": .string(allowedValues: "unknown")]),
        ])
    }
}

extension SendMessageRequest: OpenAPISchemaProviding {
    public static var openAPIComponentName: String? { "SendMessageRequest" }

    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        let destinations: OrderedDictionary<String, JSONSchema> = [
            "conversation_id": try context.schema(for: ConversationID.self, direction: direction),
            "to": .string(minLength: 1),
            "participants": .array(minItems: 2, items: .string(minLength: 1)),
        ]
        var properties: OrderedDictionary<String, JSONSchema> = [:]
        for (name, schema) in destinations { properties[name] = optionalWireValue(schema, direction: direction) }
        properties["text"] = optionalWireValue(.string, direction: direction)
        properties["media"] = optionalWireValue(
            .array(items: try context.schema(for: SendMediaReference.self, direction: direction)), direction: direction
        )
        properties["reply_to"] = optionalWireValue(try context.schema(for: ReplyTarget.self, direction: direction), direction: direction)
        let destinationChoices = destinations.map { selected, _ -> JSONSchema in
            var branch: OrderedDictionary<String, JSONSchema> = [:]
            for (name, schema) in destinations {
                branch[name] = name == selected ? schema : .null().optionalSchemaObject()
            }
            return .object(properties: branch)
        }
        return .all(of: [
            .object(
                description: "Exactly one non-null destination. The service requires text or uploaded media. "
                    + "Participant sends require text and do not support media or reply_to. Normalized participants must be unique.",
                properties: properties,
                additionalProperties: .a(false)
            ),
            .one(of: destinationChoices),
        ])
    }
}

private func optionalWireValue(_ schema: JSONSchema, direction: SchemaDirection) -> JSONSchema {
    (direction == .request ? schema.nullableSchemaObject() : schema).optionalSchemaObject()
}
