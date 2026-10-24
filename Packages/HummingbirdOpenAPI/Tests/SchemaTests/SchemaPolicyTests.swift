import Foundation
import HummingbirdOpenAPIModels
import OpenAPIKit
import Testing

@OpenAPISchema
struct Page<Item: Codable & Sendable>: Codable, Sendable {
    let items: [Item]
}

@OpenAPISchema(customCoding: .explicitPropertyRules)
struct ExplicitNull: Codable {
    @OpenAPIProperty(response: .requiredNullable)
    let value: String?
    @OpenAPIProperty(request: .optionalNullable)
    let enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case value, enabled
    }

    init(value: String?, enabled: Bool) {
        self.value = value
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(enabled, forKey: .enabled)
    }
}

@OpenAPISchema(name: "NamedExample")
struct Renamed: Codable {
    let name: String
}

private struct FirstCollision: OpenAPISchemaProviding {
    static var openAPIComponentName: String? { "Collision" }
    static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .string }
}

private struct SecondCollision: OpenAPISchemaProviding {
    static var openAPIComponentName: String? { "Collision" }
    static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) -> SchemaValue { .integer }
}

private struct FailingProvider: OpenAPISchemaProviding {
    static var openAPIComponentName: String? { "Failing" }
    static func openAPISchema(in context: SchemaContext, direction: SchemaDirection) throws -> SchemaValue {
        _ = try context.schema(for: Renamed.self, direction: direction)
        throw SchemaError.duplicateProperty("injected")
    }
}

@Test
func genericSpecializationsHaveStableSeparateComponents() throws {
    let context = SchemaContext()
    _ = try context.schema(for: Page<String>.self, direction: .response)
    _ = try context.schema(for: Page<Int>.self, direction: .response)
    _ = try context.schema(for: Page<[String]>.self, direction: .response)
    #expect(context.components["Page__String_response"] != nil)
    #expect(context.components["Page__Int_response"] != nil)
    #expect(context.components["Page__Array_of_String_response"] != nil)
}

@Test
func customPropertyRulesPreserveNullAndInputDefaults() throws {
    let context = SchemaContext()
    _ = try context.schema(for: ExplicitNull.self, direction: .request)
    _ = try context.schema(for: ExplicitNull.self, direction: .response)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context.components)) as? [String: [String: Any]])
    let output = try #require(object["ExplicitNull_response"])
    let input = try #require(object["ExplicitNull_request"])
    #expect(Set(output["required"] as? [String] ?? []) == ["value", "enabled"])
    #expect((input["required"] as? [String] ?? []).isEmpty)
    let properties = try #require(output["properties"] as? [String: [String: Any]])
    #expect(Set(properties["value"]?["type"] as? [String] ?? []) == ["string", "null"])
    let data = try JSONEncoder().encode(ExplicitNull(value: nil, enabled: false))
    let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(encoded["value"] is NSNull)
    #expect(try JSONDecoder().decode(ExplicitNull.self, from: Data("{}".utf8)).enabled == false)
}

@Test
func componentCollisionsAndFailedExpansionsCannotPoisonTheRegistry() throws {
    let context = SchemaContext()
    _ = try context.schema(for: FirstCollision.self, direction: .response)
    #expect(throws: SchemaError.componentCollision("Collision_response")) {
        try context.schema(for: SecondCollision.self, direction: .response)
    }
    #expect(throws: SchemaError.duplicateProperty("injected")) {
        try context.schema(for: FailingProvider.self, direction: .request)
    }
    #expect(context.components.count == 1)
    _ = try context.schema(for: Renamed.self, direction: .request)
    #expect(context.components["NamedExample_request"] != nil)
    #expect(context.components.count == 2)
}
