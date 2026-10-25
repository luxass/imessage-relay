import Foundation
import HummingbirdOpenAPIModels
import OpenAPIKit
import Testing

@OpenAPISchema
struct Greeting: Codable, Sendable {
    let message: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case displayName = "display_name"
    }
}

@OpenAPISchema
enum GreetingKind: String, Codable {
    case normal
    case veryFriendly = "very_friendly"
}

@OpenAPISchema
struct Farewell: Codable {
    let note: String?
}

@OpenAPISchema
struct Tree: Codable {
    let children: [Tree]
}

@OpenAPISchema
struct CollectionModel: Codable {
    let values: [String: [Int?]]
}

@Test
func schemasPreserveCodingKeysAndDirectionalOptionals() throws {
    // The directions differ, so each one needs its own document context.
    let requestContext = SchemaContext()
    _ = try requestContext.schema(for: Greeting.self, direction: .request)
    let responseContext = SchemaContext()
    _ = try responseContext.schema(for: Greeting.self, direction: .response)
    let input = try #require(try object(requestContext.components)["Greeting"] as? [String: Any])
    let output = try #require(try object(responseContext.components)["Greeting"] as? [String: Any])
    #expect(input["required"] as? [String] == ["message"])
    #expect(output["required"] as? [String] == ["message"])
    let inputProperties = try #require(input["properties"] as? [String: [String: Any]])
    let outputProperties = try #require(output["properties"] as? [String: [String: Any]])
    #expect(Set(inputProperties["display_name"]?["type"] as? [String] ?? []) == ["string", "null"])
    #expect(outputProperties["display_name"]?["type"] as? String == "string")
    #expect(outputProperties["displayName"] == nil)
    #expect(output["additionalProperties"] == nil)
    let encoded = try object(Greeting(message: "Hello", displayName: nil))
    #expect(Set(encoded.keys) == ["message"])
    let decoded = try JSONDecoder().decode(Greeting.self, from: Data(#"{"message":"Hello","display_name":null,"extra":1}"#.utf8))
    #expect(decoded.displayName == nil)
}

@Test
func rawEnumsUseWireValues() throws {
    let context = SchemaContext()
    _ = try context.schema(for: GreetingKind.self, direction: .response)
    let components = try object(context.components)
    let schema = try #require(components["GreetingKind"] as? [String: Any])
    #expect(schema["enum"] as? [String] == ["normal", "very_friendly"])
}

@Test
func matchingDirectionsShareOneComponent() throws {
    let context = SchemaContext()
    _ = try context.schema(for: GreetingKind.self, direction: .request)
    _ = try context.schema(for: Tree.self, direction: .response)
    _ = try context.schema(for: Tree.self, direction: .request)
    _ = try context.schema(for: GreetingKind.self, direction: .response)
    #expect(Set(context.components.keys.map(\.rawValue)) == ["GreetingKind", "Tree"])
}

@Test
func differingDirectionsAreRejected() throws {
    let context = SchemaContext()
    _ = try context.schema(for: Farewell.self, direction: .response)
    #expect(throws: SchemaError.directionalSchemaMismatch("Farewell")) {
        try context.schema(for: Farewell.self, direction: .request)
    }
    // The rejected request expansion leaves the response component in place.
    #expect(context.components.count == 1)
    _ = try context.schema(for: Farewell.self, direction: .response)
    #expect(context.components.count == 1)
}

@Test
func recursiveComponentsTerminateAndBuildDeterministically() throws {
    func encoded() throws -> Data {
        let context = SchemaContext()
        _ = try context.schema(for: Tree.self, direction: .response)
        #expect(context.components.count == 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(context.components)
    }
    #expect(try encoded() == encoded())
}

@Test
func nestedCollectionsDescribeNullArrayElements() throws {
    let context = SchemaContext()
    _ = try context.schema(for: CollectionModel.self, direction: .response)
    let text = try #require(String(data: JSONEncoder().encode(context.components), encoding: .utf8))
    #expect(text.contains("additionalProperties"))
    #expect(text.contains("null"))
}

private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}
