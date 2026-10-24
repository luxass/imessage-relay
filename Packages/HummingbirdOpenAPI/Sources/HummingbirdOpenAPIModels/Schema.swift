import OpenAPIKit

public typealias SchemaValue = JSONSchema

public enum SchemaDirection: String, Sendable {
    case request
    case response
}

public protocol OpenAPISchemaProviding: SendableMetatype {
    /// Nil keeps scalar schemas inline. Named schemas become reusable components.
    static var openAPIComponentName: String? { get }
    static var openAPITypeName: String { get }

    /// Describes a value, including an array element or dictionary value.
    /// For example, `[String?]` can encode `["hello", null]`. Its item schema must
    /// allow null even in a response, because an array element cannot be omitted.
    /// This hook does not decide whether a named object field can be absent.
    static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue

    /// Describes a value as a named object field, including its presence rules.
    /// For example, a response's `let nickname: String?` is absent when nil:
    /// `{}` rather than `{"nickname": null}`. In a request, the inferred optional
    /// field accepts both forms. `Optional` overrides this hook to describe that
    /// difference; other providers use their value schema by default.
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
    case duplicateProperty(String)
}

/// State shared by schema providers while building one OpenAPI document.
///
/// The component registry is one part of this context. Providers also use it to
/// resolve nested schemas, apply request/response field rules, and build objects
/// or JSON-encoded string schemas. Reusing it within a build keeps references
/// consistent and lets recursive models refer to components during expansion.
/// Create a separate context for each document. Do not share it concurrently.
public final class SchemaContext {
    public private(set) var components: OpenAPI.ComponentDictionary<JSONSchema> = [:]
    private var owners: [OpenAPI.ComponentKey: ObjectIdentifier] = [:]

    public init() {}

    public func schema<Value: OpenAPISchemaProviding>(
        for type: Value.Type,
        direction: SchemaDirection
    ) throws -> SchemaValue {
        guard let name = type.openAPIComponentName else {
            return try type.openAPISchema(in: self, direction: direction)
        }
        let componentName = name + "_" + direction.rawValue
        guard let key = OpenAPI.ComponentKey(rawValue: componentName) else {
            throw SchemaError.invalidComponentName(componentName)
        }
        let reference = JSONSchema.reference(.component(named: componentName))
        if let owner = owners[key] {
            guard owner == ObjectIdentifier(type) else { throw SchemaError.componentCollision(componentName) }
            return reference
        }
        // Reserve the identity before expansion so recursive fields can refer to it.
        let previousComponents = components
        let previousOwners = owners
        owners[key] = ObjectIdentifier(type)
        do {
            components[key] = try type.openAPISchema(in: self, direction: direction)
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
        case .required:
            return try type.openAPIPropertySchema(in: self, direction: .response).requiredSchemaObject()
        case .requiredNullable:
            return try schema(for: type, direction: direction).nullableSchemaObject().requiredSchemaObject()
        case .omittedWhenNil:
            return try type.openAPIPropertySchema(in: self, direction: .response).optionalSchemaObject()
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

    public func stringEnumeration(_ values: [String]) -> SchemaValue {
        .string(allowedValues: values.map { AnyCodable($0) })
    }

    public func integerEnumeration(_ values: [Int]) -> SchemaValue {
        .integer(allowedValues: values.map { AnyCodable($0) })
    }
}

/// Lets `@OpenAPISchema` derive a schema for a type with custom Codable methods.
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
    /// Require the field, using its response schema's nullability.
    case required
    /// Require the field but allow an explicit null value.
    case requiredNullable
    /// Allow omission, using the response field shape without adding null.
    case omittedWhenNil
    /// Allow both omission and null, such as when a decoder supplies a default.
    case optionalNullable
}

@attached(extension, conformances: OpenAPISchemaProviding, names: named(openAPISchema), named(openAPIComponentName))
public macro OpenAPISchema(name: String? = nil, customCoding: CustomCodingStrategy? = nil) = #externalMacro(
    module: "HummingbirdOpenAPIMacros", type: "SchemaMacro"
)

@attached(peer)
public macro OpenAPIProperty(request: SchemaPropertyRule = .inferred, response: SchemaPropertyRule = .inferred) = #externalMacro(
    module: "HummingbirdOpenAPIMacros", type: "PropertyMacro"
)
