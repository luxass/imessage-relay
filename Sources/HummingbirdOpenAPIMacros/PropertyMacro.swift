import SwiftSyntax
import SwiftSyntaxMacros

/// A schema-only marker. It emits no runtime storage or JSON code.
public struct PropertyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@OpenAPIProperty must annotate a stored property.")
        }
        return []
    }
}
