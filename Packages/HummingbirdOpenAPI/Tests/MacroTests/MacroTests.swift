import HummingbirdOpenAPIMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

private func expand(_ source: String) throws -> [DeclSyntax] {
    let file = Parser.parse(source: source)
    let declaration = try #require(file.statements.first?.item.as(StructDeclSyntax.self))
    let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
    return try ModelMacro.expansion(
        of: attribute, providingMembersOf: declaration, conformingTo: [], in: BasicMacroExpansionContext()
    )
}

@Test(arguments: [
    "@OpenAPIModel struct Bad: Codable { let value: String; func encode(to encoder: Encoder) throws {} }",
    "@OpenAPIModel struct Bad: Codable { let value: String; init(from decoder: Decoder) throws { value = \"\" } }",
    "@OpenAPIModel struct Bad: Codable { let value = \"constant\" }",
    "@OpenAPIModel(encodeNil: Bool.random()) struct Bad: Codable { let value: String }",
    "@OpenAPIModel struct Bad: Codable { let value: String; let value: Int }",
    "@OpenAPIModel struct Bad: Codable { @Wrapper var value: String }",
    "@OpenAPIModel struct Bad: Codable { let one: String; let two: String; enum CodingKeys: String, CodingKey { case one } }",
    "@OpenAPIModel struct Bad: Codable { let one: String; let two: String; enum CodingKeys: String, CodingKey { case one = \"same\"; case two = \"same\" } }",
])
func unsupportedCodingFailsInsteadOfGuessing(source: String) {
    #expect(throws: (any Error).self) { try expand(source) }
}

@Test func addingAStoredPropertyAutomaticallyChangesTheSchema() throws {
    let result = try expand("""
    @OpenAPIModel struct Added: Codable {
        let original: String
        let newlyAdded: [Int]?
        enum CodingKeys: String, CodingKey {
            case original
            case newlyAdded = "newly_added"
        }
    }
    """).map(\.description).joined()
    #expect(result.contains("\"newly_added\": try schemas.schema(for: ([Int]?).self)"))
    #expect(result.contains("required: [\"original\"]"))
}
