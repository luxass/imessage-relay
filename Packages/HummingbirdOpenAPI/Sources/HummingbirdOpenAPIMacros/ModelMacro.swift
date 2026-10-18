import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ModelMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try rejectCustomCoding(declaration)
        if let structure = declaration.as(StructDeclSyntax.self) {
            return try structMembers(structure, encodeNil: encodeNil(node)).filter {
                !$0.is(FunctionDeclSyntax.self) || $0.as(FunctionDeclSyntax.self)?.name.text != "encode"
            }.filter { !$0.is(InitializerDeclSyntax.self) }
        }
        if let enumeration = declaration.as(EnumDeclSyntax.self) {
            return [try enumSchema(enumeration)]
        }
        throw ModelError("@OpenAPIModel supports only structs and raw-value enums.")
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Codecs are generated with the schema. A custom codec in another extension
        // then fails compilation as a redeclaration, rather than silently drifting.
        let codecs: [DeclSyntax]
        if let structure = declaration.as(StructDeclSyntax.self) {
            guard let members = try? structMembers(structure, encodeNil: encodeNil(node)) else { return [] }
            codecs = members.filter {
                $0.is(InitializerDeclSyntax.self) || $0.as(FunctionDeclSyntax.self)?.name.text == "encode"
            }
        } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
            let rawType = enumeration.inheritanceClause?.inheritedTypes.contains {
                $0.type.trimmedDescription == "String"
            } == true ? "String" : "Int"
            codecs = [DeclSyntax(stringLiteral: """
            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
            """), DeclSyntax(stringLiteral: """
            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(\(rawType).self)
                guard let value = Self(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum raw value.")
                }
                self = value
            }
            """)]
        } else { return [] }
        return [try ExtensionDeclSyntax("""
        extension \(type): OpenAPISchema {
            \(raw: codecs.map(\.description).joined(separator: "\n"))
        }
        """)]
    }

    private static func encodeNil(_ node: AttributeSyntax) throws -> Bool {
        guard let arguments = node.arguments else { return false }
        guard case .argumentList(let list) = arguments,
              list.count == 1, let argument = list.first,
              argument.label?.text == "encodeNil",
              let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
            throw ModelError("encodeNil must be a Bool literal.")
        }
        return literal.literal.text == "true"
    }

    private static func rejectCustomCoding(_ declaration: some DeclGroupSyntax) throws {
        for member in declaration.memberBlock.members {
            if let function = member.decl.as(FunctionDeclSyntax.self),
               function.name.text == "encode",
               function.signature.parameterClause.parameters.first?.firstName.text == "to" {
                throw ModelError("Custom encode(to:) is unsupported. Use a declarative Codable wire model.")
            }
            if let initializer = member.decl.as(InitializerDeclSyntax.self),
               initializer.signature.parameterClause.parameters.first?.firstName.text == "from" {
                throw ModelError("Custom init(from:) is unsupported. Validate the wire model after decoding.")
            }
            if member.decl.is(IfConfigDeclSyntax.self) {
                throw ModelError("Conditional model members are unsupported.")
            }
        }
    }

    private struct Property {
        let name: String
        let type: String
        let optional: Bool
        let wrappedType: String
    }

    private static func structMembers(_ declaration: StructDeclSyntax, encodeNil: Bool) throws -> [DeclSyntax] {
        var properties: [Property] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) { continue }
            for binding in variable.bindings {
                // Computed properties do not participate in synthesized Codable.
                if let accessors = binding.accessorBlock {
                    switch accessors.accessors {
                    case .getter: continue
                    case .accessors(let list):
                        if list.contains(where: { ["get", "set"].contains($0.accessorSpecifier.text) }) { continue }
                    }
                }
                guard variable.attributes.isEmpty else {
                    throw ModelError("Property wrappers and property attributes are unsupported in wire models.")
                }
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let type = binding.typeAnnotation?.type else {
                    throw ModelError("Every stored wire property needs a name and explicit type.")
                }
                if variable.bindingSpecifier.text == "let", binding.initializer != nil {
                    throw ModelError("Initialized let properties do not decode normally. Use an uninitialized wire property.")
                }
                let optional = type.is(OptionalTypeSyntax.self)
                    || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                guard !name.contains("`") else { throw ModelError("Escaped property names are not supported yet.") }
                let wrapped = type.as(OptionalTypeSyntax.self)?.wrappedType
                    ?? type.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self)
                guard !optional || wrapped != nil else { throw ModelError("Optional requires an explicit wrapped type.") }
                properties.append(Property(
                    name: name, type: type.trimmedDescription, optional: optional,
                    wrappedType: optional ? (wrapped?.trimmedDescription ?? type.trimmedDescription) : type.trimmedDescription
                ))
            }
        }
        guard Set(properties.map(\.name)).count == properties.count else {
            throw ModelError("Stored property names must be unique.")
        }
        let keys = try codingKeys(declaration, properties: properties)
        let fields = properties.map { property in
            "\(String(reflecting: keys[property.name]!)): try schemas.schema(for: (\(property.type)).self)"
        }.joined(separator: ",\n")
        let required = properties.filter { encodeNil || !$0.optional }.map { String(reflecting: keys[$0.name]!) }
        let dictionary = properties.isEmpty ? ":" : fields
        var members: [DeclSyntax] = [DeclSyntax(stringLiteral: """
        public static var jsonPropertyNames: [String] {
            [\(properties.map { String(reflecting: keys[$0.name]!) }.joined(separator: ", "))]
        }
        """), DeclSyntax(stringLiteral: """
        public static func openAPISchema(in schemas: inout OpenAPISchemas) throws -> JSONSchema {
            try schemas.component(Self.self) { schemas in
                .object(properties: [\(dictionary)], required: [\(required.joined(separator: ", "))])
            }
        }
        """)]
        if !declaration.memberBlock.members.contains(where: {
            $0.decl.as(EnumDeclSyntax.self)?.name.text == "CodingKeys"
        }) {
            members.append(DeclSyntax(stringLiteral: """
            private enum CodingKeys: \(properties.isEmpty ? "" : "String, ")CodingKey {
                \(properties.map { "case \($0.name)" }.joined(separator: "\n"))
            }
            """))
        }
        let encoding = properties.map { property in
            let method = property.optional && !encodeNil ? "encodeIfPresent" : "encode"
            return "try container.\(method)(self.\(property.name), forKey: .\(property.name))"
        }.joined(separator: "\n")
        let decoding = properties.map { property in
            let method = property.optional && !encodeNil ? "decodeIfPresent" : "decode"
            let type = property.optional && encodeNil ? property.type : property.wrappedType
            return "self.\(property.name) = try container.\(method)((\(type)).self, forKey: .\(property.name))"
        }.joined(separator: "\n")
        members.append(DeclSyntax(stringLiteral: """
        public func encode(to encoder: Encoder) throws {
            \(properties.isEmpty ? "_ =" : "var container =") encoder.container(keyedBy: CodingKeys.self)
            \(encoding)
        }
        """))
        members.append(DeclSyntax(stringLiteral: """
        public init(from decoder: Decoder) throws {
            \(properties.isEmpty ? "_ =" : "let container =") try decoder.container(keyedBy: CodingKeys.self)
            \(decoding)
        }
        """))
        return members
    }

    private static func codingKeys(_ declaration: StructDeclSyntax, properties: [Property]) throws -> [String: String] {
        guard let enumeration = declaration.memberBlock.members.compactMap({ $0.decl.as(EnumDeclSyntax.self) })
            .first(where: { $0.name.text == "CodingKeys" }) else {
            return Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.name) })
        }
        var result: [String: String] = [:]
        for member in enumeration.memberBlock.members {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else {
                throw ModelError("CodingKeys must contain only literal enum cases.")
            }
            for element in cases.elements {
                let name = element.name.text
                guard element.parameterClause == nil else { throw ModelError("Associated CodingKeys are unsupported.") }
                if let raw = element.rawValue {
                    guard let value = raw.value.as(StringLiteralExprSyntax.self)?.representedLiteralValue else {
                        throw ModelError("CodingKeys values must be string literals.")
                    }
                    result[name] = value
                } else {
                    result[name] = name
                }
            }
        }
        guard Set(result.keys) == Set(properties.map(\.name)), Set(result.values).count == result.count else {
            throw ModelError("CodingKeys must map every stored wire property exactly once, with unique JSON names.")
        }
        return result
    }

    private static func enumSchema(_ declaration: EnumDeclSyntax) throws -> DeclSyntax {
        let inherited = declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        guard inherited.contains("String") || inherited.contains("Int") else {
            throw ModelError("Only String and Int raw-value enums are supported. Use a wire struct for associated values.")
        }
        let stringEnum = inherited.contains("String")
        var values: [String] = []
        var nextInteger = 0
        for member in declaration.memberBlock.members {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in cases.elements {
                guard element.parameterClause == nil else { throw ModelError("Associated enum values are unsupported.") }
                if element.name.text.contains("`"), element.rawValue == nil, stringEnum {
                    throw ModelError("Escaped enum cases need an explicit string raw value.")
                }
                if stringEnum {
                    if let raw = element.rawValue {
                        guard let value = raw.value.as(StringLiteralExprSyntax.self)?.representedLiteralValue else {
                            throw ModelError("Enum raw values must be literals.")
                        }
                        values.append(String(reflecting: value))
                    } else {
                        values.append(String(reflecting: element.name.text))
                    }
                } else {
                    if let raw = element.rawValue {
                        guard let value = Int(raw.value.trimmedDescription) else {
                            throw ModelError("Integer enum raw values must be decimal integer literals.")
                        }
                        nextInteger = value
                    }
                    values.append(String(nextInteger))
                    guard nextInteger < Int.max else { throw ModelError("Integer enum raw value overflow.") }
                    nextInteger += 1
                }
            }
        }
        guard !values.isEmpty else { throw ModelError("Empty enums are unsupported.") }
        return DeclSyntax(stringLiteral: """
        public static func openAPISchema(in schemas: inout OpenAPISchemas) throws -> JSONSchema {
            try schemas.component(Self.self) { _ in
                .\(stringEnum ? "stringEnum" : "integerEnum")([\(values.joined(separator: ", "))])
            }
        }
        """)
    }
}

private struct ModelError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct OpenAPIPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ModelMacro.self]
}
