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

    static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue
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

/// A document-scoped registry. Do not share it across concurrent document builds.
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

public enum CustomCodingStrategy {
    /// The author guarantees that CodingKeys and property types describe the wire shape.
    case explicitPropertyRules
}

public enum SchemaPropertyRule {
    case inferred
    case required
    case requiredNullable
    case omittedWhenNil
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
