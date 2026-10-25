import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct OpenAPIPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [SchemaMacro.self, PropertyMacro.self]
}
