import OpenAPIKit

// Built-in schema mappings for Swift scalars and containers. For example, String
// describes an OpenAPI string, Int an integer, and [Value] an array of Value's schema.
// These conformances describe JSON shapes. They do not convert values or change Codable.
// Optional treats nullable values separately from fields that can be absent.

extension String: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .string }
}

extension Bool: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .boolean }
}

extension Int: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .integer }
}

extension Int64: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue {
        .integer(format: .int64)
    }
}

extension Double: OpenAPISchemaProviding {
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .number }
}

extension Optional: OpenAPISchemaProviding where Wrapped: OpenAPISchemaProviding {
    public static var openAPITypeName: String { "OptionalOf" + Wrapped.openAPITypeName }
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        try context.schema(for: Wrapped.self, direction: direction).nullableSchemaObject()
    }

    public static func openAPIPropertySchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        let wrapped = try context.schema(for: Wrapped.self, direction: direction)
        // Synthesized encodeIfPresent omits nil, while decodeIfPresent accepts null.
        return (direction == .request ? wrapped.nullableSchemaObject() : wrapped).optionalSchemaObject()
    }
}

extension Array: OpenAPISchemaProviding where Element: OpenAPISchemaProviding {
    public static var openAPITypeName: String { "ArrayOf" + Element.openAPITypeName }
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        .array(items: try context.schema(for: Element.self, direction: direction))
    }
}

extension Dictionary: OpenAPISchemaProviding where Key == String, Value: OpenAPISchemaProviding {
    public static var openAPITypeName: String { "DictionaryOf" + Value.openAPITypeName }
    public static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        .object(additionalProperties: .b(try context.schema(for: Value.self, direction: direction)))
    }
}
