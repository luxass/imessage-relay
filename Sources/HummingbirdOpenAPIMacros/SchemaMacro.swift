import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct SchemaMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let access = declaration.modifiers.contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""
        let body: String
        let parameters = declaration.as(StructDeclSyntax.self)?.genericParameterClause?.parameters.map { $0.name.text } ?? []
        if let structure = declaration.as(StructDeclSyntax.self) {
            body = try structBody(structure, attribute: node)
        } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
            body = try enumBody(enumeration)
        } else {
            throw MacroExpansionErrorMessage("@OpenAPISchema supports structs and String/Int raw-value enums.")
        }
        // Generic specializations append their arguments, such as `PageOfString` or `PairOfIntAndString`.
        let suffix = parameters.enumerated().map {
            " + \"\($0.offset == 0 ? "Of" : "And")\" + \($0.element).openAPITypeName"
        }.joined()
        let defaultName = StringLiteralExprSyntax(content: type.trimmedDescription).description
        let name = (try customName(attribute: node, label: "name") ?? defaultName) + suffix
        let constraints = parameters.isEmpty ? "" : " where " + parameters.map {
            "\($0): HummingbirdOpenAPIModels.OpenAPISchemaProviding"
        }.joined(separator: ", ")
        let result: DeclSyntax = """
            extension \(type.trimmed): HummingbirdOpenAPIModels.OpenAPISchemaProviding\(raw: constraints) {
                \(raw: access)static var openAPIComponentName: String? { \(raw: name) }
                \(raw: access)static func openAPISchema(
                    in context: HummingbirdOpenAPIModels.SchemaContext,
                    direction: HummingbirdOpenAPIModels.SchemaDirection
                ) throws -> HummingbirdOpenAPIModels.SchemaValue {
                    \(raw: body)
                }
            }
            """
        guard let result = result.formatted().as(ExtensionDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("Could not construct schema conformance.")
        }
        return [result]
    }

    private static func structBody(_ declaration: StructDeclSyntax, attribute: AttributeSyntax) throws -> String {
        let members = declaration.memberBlock.members
        if members.contains(where: { $0.decl.is(IfConfigDeclSyntax.self) }) {
            throw MacroExpansionErrorMessage("Conditional members require an explicit schema provider.")
        }
        let acknowledgesCustomCoding: Bool
        if case .argumentList(let arguments) = attribute.arguments,
           let strategy = arguments.first(where: { $0.label?.text == "customCoding" }) {
            // Only the literal opt-in counts. `customCoding: nil` must not silence the check.
            acknowledgesCustomCoding = strategy.expression.trimmedDescription == ".explicitPropertyRules"
        } else {
            acknowledgesCustomCoding = false
        }
        if members.contains(where: { hasCustomCoding($0.decl) }) && !acknowledgesCustomCoding {
            throw MacroExpansionErrorMessage("Custom Codable requires an explicit schema provider or customCoding: .explicitPropertyRules.")
        }
        let fields = try storedFields(in: members)
        let names = try codingNames(in: members, fields: fields)
        let properties = fields.compactMap { field -> String? in
            guard let name = names[field.name] else { return nil }
            return "(\(name), try context.property(\(field.type).self, direction: direction\(field.rules)))"
        }
        return "return try context.object([" + properties.joined(separator: ", ") + "])"
    }

    private static func hasCustomCoding(_ declaration: DeclSyntax) -> Bool {
        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            return initializer.signature.parameterClause.parameters.first?.firstName.text == "from"
        }
        if let function = declaration.as(FunctionDeclSyntax.self) {
            return function.name.text == "encode"
                && function.signature.parameterClause.parameters.first?.firstName.text == "to"
        }
        return false
    }

    private struct Field {
        let name: String
        let type: String
        let rules: String
    }

    private static func storedFields(in members: MemberBlockItemListSyntax) throws -> [Field] {
        var fields: [Field] = []
        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else { continue }
            let rules = try propertyRules(variable.attributes)
            for binding in variable.bindings {
                if let field = try storedField(binding, specifier: variable.bindingSpecifier.text, rules: rules) {
                    fields.append(field)
                }
            }
        }
        return fields
    }

    private static func storedField(_ binding: PatternBindingSyntax, specifier: String, rules: String) throws -> Field? {
        // Computed properties do not participate in synthesized Codable.
        if let accessors = binding.accessorBlock {
            if case .getter = accessors.accessors { return nil }
            if case .accessors(let list) = accessors.accessors,
               list.contains(where: { ["get", "set"].contains($0.accessorSpecifier.text) }) { return nil }
        }
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let type = binding.typeAnnotation?.type else {
            throw MacroExpansionErrorMessage("Schema properties need a single named binding and an explicit type.")
        }
        guard !(specifier == "let" && binding.initializer != nil) else {
            throw MacroExpansionErrorMessage("Initialized let properties require an explicit schema provider.")
        }
        return Field(name: name, type: type.trimmedDescription, rules: rules)
    }

    private static func codingNames(
        in members: MemberBlockItemListSyntax,
        fields: [Field]
    ) throws -> [String: String] {
        guard let codingKeys = members.compactMap({ $0.decl.as(EnumDeclSyntax.self) }).first(where: { $0.name.text == "CodingKeys" }) else {
            return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, StringLiteralExprSyntax(content: $0.name).description) })
        }
        var names: [String: String] = [:]
        for member in codingKeys.memberBlock.members {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else {
                throw MacroExpansionErrorMessage("CodingKeys must contain only literal enum cases for automatic derivation.")
            }
            for element in cases.elements {
                let name = element.name.text
                guard fields.contains(where: { $0.name == name }) else {
                    throw MacroExpansionErrorMessage("CodingKeys entry '\(name)' does not match a supported stored property.")
                }
                names[name] = try stringValue(of: element)
            }
        }
        return names
    }

    private static func customName(attribute: AttributeSyntax, label: String) throws -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: { $0.label?.text == label }) else { return nil }
        guard argument.expression.is(StringLiteralExprSyntax.self) else {
            throw MacroExpansionErrorMessage("Schema names must be string literals.")
        }
        return argument.expression.trimmedDescription
    }

    private static func propertyRules(_ attributes: AttributeListSyntax) throws -> String {
        var result = ""
        for item in attributes {
            guard let attribute = item.as(AttributeSyntax.self), attribute.attributeName.trimmedDescription == "OpenAPIProperty" else {
                throw MacroExpansionErrorMessage("Property wrappers and other attributed fields require an explicit schema provider.")
            }
            guard case .argumentList(let arguments) = attribute.arguments else { continue }
            for argument in arguments {
                guard let label = argument.label?.text, ["request", "response"].contains(label),
                      let member = argument.expression.as(MemberAccessExprSyntax.self), member.base == nil else {
                    throw MacroExpansionErrorMessage("Use literal SchemaPropertyRule members, such as .requiredNullable.")
                }
                result += ", \(label): \(argument.expression.trimmedDescription)"
            }
        }
        return result
    }

    private static func stringValue(of element: EnumCaseElementSyntax) throws -> String {
        guard let raw = element.rawValue?.value else { return StringLiteralExprSyntax(content: element.name.text).description }
        guard raw.is(StringLiteralExprSyntax.self) else {
            throw MacroExpansionErrorMessage("String enum and CodingKeys raw values must be string literals.")
        }
        return raw.trimmedDescription
    }

    private static func enumBody(_ declaration: EnumDeclSyntax) throws -> String {
        let inherited = declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        guard inherited.contains("String") || inherited.contains("Int") else {
            throw MacroExpansionErrorMessage("Enum schemas require a String or Int raw value, or an explicit schema provider.")
        }
        if declaration.memberBlock.members.contains(where: { hasCustomCoding($0.decl) }) {
            throw MacroExpansionErrorMessage("Custom enum coding requires an explicit schema provider.")
        }
        let isString = inherited.contains("String")
        var values: [String] = []
        var nextInteger = 0
        for member in declaration.memberBlock.members {
            if member.decl.is(IfConfigDeclSyntax.self) {
                throw MacroExpansionErrorMessage("Conditional enum cases require an explicit schema provider.")
            }
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in cases.elements {
                guard element.parameterClause == nil else {
                    throw MacroExpansionErrorMessage("Associated values require an explicit schema provider.")
                }
                if isString {
                    values.append(try stringValue(of: element))
                } else {
                    let value: Int
                    if let raw = element.rawValue?.value {
                        guard let parsed = Int(raw.trimmedDescription) else {
                            throw MacroExpansionErrorMessage("Int enum raw values must be decimal literals.")
                        }
                        value = parsed
                    } else { value = nextInteger }
                    values.append(String(value))
                    if value == Int.max {
                        throw MacroExpansionErrorMessage("Int.max enum raw values require an explicit schema provider.")
                    }
                    nextInteger = value + 1
                }
            }
        }
        guard !values.isEmpty else { throw MacroExpansionErrorMessage("An enum schema needs at least one case.") }
        let schema = isString ? "string" : "integer"
        return "return HummingbirdOpenAPIModels.SchemaValue.\(schema)(allowedValues: [\(values.joined(separator: ", "))])"
    }
}
