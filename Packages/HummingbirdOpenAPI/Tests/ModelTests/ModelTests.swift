import Foundation
import HummingbirdOpenAPIModels
import Testing

@OpenAPIModel
private struct Person: Codable, Sendable {
    let displayName: String
    let age: Int?
    let roles: [Role]
    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case age, roles
    }
}

@OpenAPIModel
private enum Role: String, Codable, Sendable {
    case reader
    case sender = "message_sender"
}

@OpenAPIModel(encodeNil: true)
private struct NullableResult: Codable, Sendable {
    let value: String?
}

@OpenAPIModel
private struct Node: Codable, Sendable {
    let label: String
    let children: [Node]
}

@OpenAPIModel
private struct GenericModel: Codable, Sendable {
    let values: Array<Int>
    let label: Optional<String>
}

@Test func genericCollectionAndOptionalSpellingsUseTheCorrectCodecTypes() throws {
    let data = Data(#"{"values":[1,2]}"#.utf8)
    let value = try JSONDecoder().decode(GenericModel.self, from: data)
    #expect(value.values == [1, 2])
    #expect(value.label == nil)
    var schemas = OpenAPISchemas()
    let reference = try schemas.schema(for: GenericModel.self)
    guard case .reference(let name) = reference,
          case .object(let fields, _) = schemas.components[name] else {
        Issue.record("Missing generic model schema")
        return
    }
    #expect(fields["values"] == .array(.integer))
    #expect(fields["label"] == .nullable(.string))
}

@Test func schemasUseCodingKeysTypesOptionalityAndEnumRawValues() throws {
    var schemas = OpenAPISchemas()
    let reference = try schemas.schema(for: Person.self)
    guard case .reference(let name) = reference,
          case .object(let fields, let required) = schemas.components[name] else {
        Issue.record("Missing generated object schema")
        return
    }
    #expect(Set(fields.keys) == Set(["display_name", "age", "roles"]))
    #expect(Set(required) == Set(["display_name", "roles"]))
    #expect(fields["age"] == .nullable(.integer))
    #expect(schemas.components.values.contains(.stringEnum(["reader", "message_sender"])))
    let encoded = try JSONEncoder().encode(Person(displayName: "Alex", age: nil, roles: [.sender]))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == Set(required))
}

@Test func nullEncodingAndRequirednessComeFromTheSameMacro() throws {
    var schemas = OpenAPISchemas()
    let reference = try schemas.schema(for: NullableResult.self)
    guard case .reference(let name) = reference,
          case .object(let fields, let required) = schemas.components[name] else {
        Issue.record("Missing generated nullable schema")
        return
    }
    #expect(fields["value"] == .nullable(.string))
    #expect(required == ["value"])
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(NullableResult(value: nil))) as? [String: Any]
    )
    #expect(object["value"] is NSNull)
}

@Test func recursiveModelsUseReferencesInsteadOfInfiniteExpansion() throws {
    var schemas = OpenAPISchemas()
    let reference = try schemas.schema(for: Node.self)
    guard case .reference(let name) = reference,
          case .object(let fields, _) = schemas.components[name] else {
        Issue.record("Missing recursive schema")
        return
    }
    #expect(fields["children"] == .array(reference))
    #expect(schemas.components.count == 1)
}
