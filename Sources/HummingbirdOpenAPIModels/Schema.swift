import OpenAPIKit

/// Macro-generated conformances name this alias, so annotated models only need to import this module.
public typealias SchemaValue = JSONSchema

public enum SchemaDirection: String, Sendable {
    case request
    case response
}

public protocol OpenAPISchemaProviding: SendableMetatype {
    /// Nil keeps scalar schemas inline. Named schemas become reusable components.
    /// Both directions share this name, so their schemas must be identical.
    static var openAPIComponentName: String? { get }
    static var openAPITypeName: String { get }

    /// Describes a value, including an array element or dictionary value.
    /// For example, `[String?]` can encode `["hello", null]`. Its item schema must
    /// allow null even in a response, because an array element cannot be omitted.
    /// This hook does not decide whether a named object field can be absent.
    static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue

    /// Describes a value as a named object field, including its presence rules.
    /// With synthesized Codable, `let nickname: String?` encodes as `{}` when nil,
    /// rather than `{"nickname": null}`. Synthesized decoding accepts both forms.
    /// Custom codecs can differ and need explicit field rules or a schema provider.
    /// `Optional` overrides this hook to describe the synthesized behavior.
    /// Other providers use their value schema by default.
    static func openAPIPropertySchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue
}

extension OpenAPISchemaProviding {
    public static var openAPIComponentName: String? { nil }
    public static var openAPITypeName: String { openAPIComponentName ?? String(describing: Self.self) }

    public static func openAPIPropertySchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        try context.schema(for: Self.self, direction: direction)
    }
}

public enum SchemaError: Error, Equatable {
    case invalidComponentName(String)
    case componentCollision(String)
    /// The request and response schemas differ but share one component name.
    case directionalSchemaMismatch(String)
    case duplicateProperty(String)
}

/// State shared by schema providers while building one OpenAPI document.
///
/// The component registry is one part of this context. Providers also use it to
/// resolve nested schemas, apply request/response field rules, and build objects
/// or JSON-encoded string schemas. Reusing it within a build keeps references
/// consistent and lets recursive models refer to components during expansion.
/// A type used in both directions gets one component when both schemas match.
/// Different schemas throw `directionalSchemaMismatch` rather than silently renaming.
/// Create a separate context for each document. Do not share it concurrently.
public final class SchemaContext {
    public private(set) var components: OpenAPI.ComponentDictionary<JSONSchema> = [:]
    private var owners: [OpenAPI.ComponentKey: (type: ObjectIdentifier, directions: Set<SchemaDirection>)] = [:]

    public init() {}

    public func schema<Value: OpenAPISchemaProviding>(
        for type: Value.Type,
        direction: SchemaDirection
    ) throws -> SchemaValue {
        guard let name = type.openAPIComponentName else {
            return try type.openAPISchema(in: self, direction: direction)
        }
        guard let key = OpenAPI.ComponentKey(rawValue: name) else {
            throw SchemaError.invalidComponentName(name)
        }
        let reference = JSONSchema.reference(.component(named: name))
        let existing = owners[key]
        if let existing {
            guard existing.type == ObjectIdentifier(type) else { throw SchemaError.componentCollision(name) }
            if existing.directions.contains(direction) { return reference }
        }
        // Reserve the identity before expansion so recursive fields can refer to it.
        // A shared component assumes the directions match until the comparison below.
        let previousComponents = components
        let previousOwners = owners
        owners[key] = (ObjectIdentifier(type), (existing?.directions ?? []).union([direction]))
        do {
            let schema = try type.openAPISchema(in: self, direction: direction)
            if let stored = components[key] {
                guard stored == schema else { throw SchemaError.directionalSchemaMismatch(name) }
            } else {
                components[key] = schema
            }
            return reference
        } catch {
            components = previousComponents
            owners = previousOwners
            throw error
        }
    }

    public func property<Value: OpenAPISchemaProviding>(
        _ type: Value.Type,
        direction: SchemaDirection,
        request: SchemaPropertyRule = .inferred,
        response: SchemaPropertyRule = .inferred
    ) throws -> SchemaValue {
        switch direction == .request ? request : response {
        case .inferred:
            return try type.openAPIPropertySchema(in: self, direction: direction)
        case .requiredNullable:
            return try schema(for: type, direction: direction).nullableSchemaObject().requiredSchemaObject()
        case .optionalNullable:
            return try schema(for: type, direction: direction).nullableSchemaObject().optionalSchemaObject()
        }
    }

    public func object(_ fields: [(String, SchemaValue)]) throws -> SchemaValue {
        var properties: OrderedDictionary<String, JSONSchema> = [:]
        for (name, schema) in fields {
            guard properties[name] == nil else { throw SchemaError.duplicateProperty(name) }
            properties[name] = schema
        }
        // Ordinary Codable decoders ignore unknown keys. Do not close the object.
        return .object(properties: properties)
    }

    /// OpenAPIKit 7 does not yet expose contentSchema. The canonical document encoder restores this standard keyword.
    public static let contentSchemaMarker = "x-hummingbird-openapi-content-schema"

    public func encodedJSONString<Value: OpenAPISchemaProviding>(
        for type: Value.Type, direction: SchemaDirection
    ) throws -> SchemaValue {
        .string(contentMediaType: .json).with(vendorExtensions: [
            Self.contentSchemaMarker: AnyCodable(try schema(for: type, direction: direction)),
        ])
    }
}

/// Lets `@OpenAPISchema` derive a schema for a struct with custom Codable methods.
/// Enums with custom Codable methods require an explicit schema provider.
/// The macro cannot infer a wire format from arbitrary encoder or decoder code.
/// This is an author opt-in, not a change to encoding or decoding behavior.
public enum CustomCodingStrategy {
    /// Derive from stored properties, CodingKeys, and `@OpenAPIProperty` rules.
    /// The author guarantees that those declarations match the custom wire format.
    case explicitPropertyRules
}

/// Schema-only field presence and nullability rules for `@OpenAPIProperty`.
/// Use these when a custom codec differs from synthesized Codable behavior.
/// They affect the generated description, not the codec or runtime validation.
public enum SchemaPropertyRule {
    /// Use the property's ordinary inferred schema for the selected direction.
    case inferred
    /// Require the field but allow an explicit null value.
    case requiredNullable
    /// Allow both omission and null, such as when a decoder supplies a default.
    case optionalNullable
}

@attached(
    extension, conformances: OpenAPISchemaProviding,
    names: named(openAPISchema), named(openAPIComponentName)
)
public macro OpenAPISchema(name: String? = nil, customCoding: CustomCodingStrategy? = nil) = #externalMacro(
    module: "HummingbirdOpenAPIMacros", type: "SchemaMacro"
)

@attached(peer)
public macro OpenAPIProperty(request: SchemaPropertyRule = .inferred, response: SchemaPropertyRule = .inferred) = #externalMacro(
    module: "HummingbirdOpenAPIMacros", type: "PropertyMacro"
)
