import Foundation

/// Models must use the Codable representation described by this conformance.
public protocol OpenAPISchema: Codable, Sendable {
    static func openAPISchema(in schemas: inout OpenAPISchemas) throws -> JSONSchema
}

/// Derives codecs and schemas from stored properties and raw-value enum cases.
/// `encodeNil` generates an encoder that emits null for optional properties.
@attached(member, names: named(openAPISchema), named(jsonPropertyNames), named(encode), named(CodingKeys))
@attached(extension, conformances: OpenAPISchema, names: named(encode), named(init))
public macro OpenAPIModel(encodeNil: Bool = false) = #externalMacro(
    module: "HummingbirdOpenAPIMacros", type: "ModelMacro"
)

public indirect enum JSONSchema: Encodable, Sendable, Equatable {
    case string
    case integer
    case number
    case boolean
    case null
    case stringEnum([String])
    case integerEnum([Int])
    case object(properties: [String: JSONSchema], required: [String])
    case array(JSONSchema)
    case nullable(JSONSchema)
    case reference(String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string: try container.encode("string", forKey: .type)
        case .integer: try container.encode("integer", forKey: .type)
        case .number: try container.encode("number", forKey: .type)
        case .boolean: try container.encode("boolean", forKey: .type)
        case .null: try container.encode("null", forKey: .type)
        case .stringEnum(let values):
            try container.encode("string", forKey: .type)
            try container.encode(values, forKey: .enumValues)
        case .integerEnum(let values):
            try container.encode("integer", forKey: .type)
            try container.encode(values, forKey: .enumValues)
        case .object(let properties, let required):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required.sorted(), forKey: .required)
            try container.encode(false, forKey: .additionalProperties)
        case .array(let items):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
        case .nullable(let wrapped):
            try container.encode([wrapped, .null], forKey: .anyOf)
        case .reference(let name):
            try container.encode("#/components/schemas/\(name)", forKey: .reference)
        }
    }

    private enum Keys: String, CodingKey {
        case type, properties, required, additionalProperties, items, anyOf
        case enumValues = "enum"
        case reference = "$ref"
    }
}

/// Registers referenced components before traversing properties, so recursive
/// models do not recurse forever. Component-name collisions fail generation.
public struct OpenAPISchemas: Sendable {
    public private(set) var components: [String: JSONSchema] = [:]
    private var names: [String: String] = [:]

    public init() {}

    public mutating func schema<T: OpenAPISchema>(for type: T.Type) throws -> JSONSchema {
        try type.openAPISchema(in: &self)
    }

    public mutating func component<T>(
        _ type: T.Type,
        build: (inout OpenAPISchemas) throws -> JSONSchema
    ) throws -> JSONSchema {
        let identity = String(reflecting: type)
        let stableIdentity = identity.replacingOccurrences(
            of: #"\.\(unknown context at \$[^)]+\)"#, with: "", options: .regularExpression
        )
        let name = stableIdentity.unicodeScalars.map { scalar -> String in
            let ascii = scalar.value < 128
            let allowed = CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
            return ascii && allowed ? String(scalar) : "_"
        }.joined()
        if let existing = names[name] {
            guard existing == identity else { throw SchemaError.componentNameCollision(name) }
            return .reference(name)
        }
        names[name] = identity
        do {
            components[name] = try build(&self)
        } catch {
            names.removeValue(forKey: name)
            throw error
        }
        return .reference(name)
    }

    public enum SchemaError: Error, Equatable {
        case componentNameCollision(String)
    }
}

extension String: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) -> JSONSchema { .string }
}
extension Bool: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) -> JSONSchema { .boolean }
}
extension Int: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) -> JSONSchema { .integer }
}
extension Int64: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) -> JSONSchema { .integer }
}
extension Double: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) -> JSONSchema { .number }
}
extension Optional: OpenAPISchema where Wrapped: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) throws -> JSONSchema {
        .nullable(try schemas.schema(for: Wrapped.self))
    }
}
extension Array: OpenAPISchema where Element: OpenAPISchema {
    public static func openAPISchema(in schemas: inout OpenAPISchemas) throws -> JSONSchema {
        .array(try schemas.schema(for: Element.self))
    }
}
