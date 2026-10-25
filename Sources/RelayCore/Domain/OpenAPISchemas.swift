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
