import Foundation
import HummingbirdOpenAPIModels
import OpenAPIKit

/// A narrow encoding adapter for the standard contentSchema keyword absent from OpenAPIKit 7.
enum OpenAPIDocumentEncoding {
    static func encode(_ document: OpenAPI.Document) throws -> Data {
        let data = try JSONEncoder().encode(document)
        let source = try JSONSerialization.jsonObject(with: data)
        let normalized = documentValue(source)
        try validateReferences(in: normalized, root: normalized)
        var result = try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        result.append(0x0A)
        return result
    }

    private static func documentValue(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(documentValue) }
        guard var object = value as? [String: Any] else { return value }
        for (key, child) in object {
            switch key {
            case "example", "examples": continue
            case "schema", "itemSchema": object[key] = schemaValue(child)
            case "schemas": object[key] = (child as? [String: Any])?.mapValues(schemaValue) ?? child
            default: object[key] = documentValue(child)
            }
        }
        return object
    }

    private static func schemaValue(_ value: Any) -> Any {
        guard var object = value as? [String: Any] else { return value }
        if let contentSchema = object.removeValue(forKey: SchemaContext.contentSchemaMarker) {
            object["contentSchema"] = contentSchema
        }
        for (key, child) in object {
            switch key {
            case "properties", "patternProperties", "$defs", "dependentSchemas":
                object[key] = (child as? [String: Any])?.mapValues(schemaValue) ?? child
            case "items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames", "contentSchema":
                object[key] = schemaValue(child)
            case "allOf", "anyOf", "oneOf", "prefixItems": object[key] = (child as? [Any])?.map(schemaValue) ?? child
            default: continue
            }
        }
        return object
    }

    private static func validateReferences(in value: Any, root: Any, schemaMap: Bool = false) throws {
        if let array = value as? [Any] {
            for child in array { try validateReferences(in: child, root: root) }
        }
        guard let object = value as? [String: Any] else { return }
        if !schemaMap, let reference = object["$ref"] as? String {
            guard reference.hasPrefix("#/"), resolve(reference, in: root) != nil else {
                throw EndpointError.invalidDefinition("Unresolved or external reference: \(reference)")
            }
        }
        for (key, child) in object {
            if !schemaMap && ["example", "examples", "default", "enum", "const"].contains(key) { continue }
            // A field named "example" is a schema in a properties map, not an annotation to skip.
            let childIsMap = !schemaMap && ["schemas", "properties", "patternProperties", "$defs", "dependentSchemas"].contains(key)
            try validateReferences(in: child, root: root, schemaMap: childIsMap)
        }
    }

    private static func resolve(_ reference: String, in root: Any) -> Any? {
        var current: Any? = root
        for part in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current as? [String: Any] {
                current = object[key]
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }
}
