import HummingbirdOpenAPIMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class MacroTests: XCTestCase {
    func testSchemaExpansionDoesNotGenerateCodecs() {
        assertMacroExpansion(
            """
            @OpenAPISchema
            struct Item: Codable {
                let name: String
            }
            """,
            expandedSource: """
            struct Item: Codable {
                let name: String
            }

            extension Item: HummingbirdOpenAPIModels.OpenAPISchemaProviding {
                static var openAPIComponentName: String? {
                    "Item"
                }
                static func openAPISchema(
                    in context: HummingbirdOpenAPIModels.SchemaContext,
                    direction: HummingbirdOpenAPIModels.SchemaDirection
                ) throws -> HummingbirdOpenAPIModels.SchemaValue {
                    return try context.object([("name", try context.property(String.self, direction: direction))])
                }
            }
            """,
            macros: ["OpenAPISchema": SchemaMacro.self]
        )
    }

    func testRejectsClassesRatherThanGuessing() {
        assertMacroExpansion(
            """
            @OpenAPISchema
            class Item {}
            """,
            expandedSource: "class Item {}",
            diagnostics: [DiagnosticSpec(
                message: "@OpenAPISchema supports structs and String/Int raw-value enums.",
                line: 1,
                column: 1
            )],
            macros: ["OpenAPISchema": SchemaMacro.self]
        )
    }

    func testRejectsUnacknowledgedCustomCoding() {
        assertMacroExpansion(
            """
            @OpenAPISchema()
            struct Item {
                func encode(to encoder: Encoder) throws {}
            }
            """,
            expandedSource: """
            struct Item {
                func encode(to encoder: Encoder) throws {}
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "Custom Codable requires an explicit schema provider or customCoding: .explicitPropertyRules.",
                line: 1,
                column: 1
            )],
            macros: ["OpenAPISchema": SchemaMacro.self]
        )
    }
}
