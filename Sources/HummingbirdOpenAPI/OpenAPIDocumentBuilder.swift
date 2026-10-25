import Foundation
import Hummingbird
import HummingbirdOpenAPIModels
import OpenAPIKit

/// Collects endpoint metadata without constructing application handlers or services.
public final class OpenAPIDocumentBuilder {
    private let title: String
    private let apiVersion: String
    private let servers: [OpenAPI.Server]
    private var entries: [EndpointDefinition] = []
    private var bearerScheme: String?

    public init(title: String, apiVersion: String, servers: [OpenAPI.Server] = []) {
        self.title = title
        self.apiVersion = apiVersion
        self.servers = servers
    }

    public func requireHTTPBearerAuthentication(named name: String) { bearerScheme = name }
    public func add(_ definition: EndpointDefinition) { entries.append(definition) }

    /// Produces the canonical JSON bytes for schema files, downloads, or other tools.
    /// Restores standard keywords such as `contentSchema` that OpenAPIKit 7 cannot
    /// represent directly, checks their references, and writes deterministic JSON.
    /// Use this method for export instead of encoding `buildValidated()` with JSONEncoder.
    public func encodedJSON() throws -> Data { try OpenAPIDocumentEncoding.encode(buildValidated()) }

    /// Builds and structurally validates the OpenAPIKit object model for inspection.
    /// This model can still contain the private `contentSchema` compatibility marker.
    /// Direct JSONEncoder output does not restore the standard keyword. For exchange, use `encodedJSON()`.
    /// These checks describe the API; they do not validate live request or response values.
    public func buildValidated() throws -> OpenAPI.Document {
        let context = SchemaContext()
        let paths = try buildPaths(in: context)
        var components = OpenAPI.Components(schemas: context.components)
        var security: [OpenAPI.SecurityRequirement] = []
        if let bearerScheme {
            guard let key = OpenAPI.ComponentKey(rawValue: bearerScheme) else {
                throw EndpointError.invalidDefinition("Invalid security scheme name: \(bearerScheme)")
            }
            components.securitySchemes[key] = .b(.http(scheme: "bearer"))
            security = [[.component(named: bearerScheme): []]]
        }
        let document = OpenAPI.Document(
            openAPIVersion: .v3_2_1,
            info: .init(title: title, version: apiVersion),
            servers: servers,
            paths: paths,
            components: components,
            security: security,
            tags: Set(entries.flatMap(\.tags)).sorted().map { .init(name: $0) }
        )
        let validator = Validator().validating(
            \.documentContainsPaths, \.pathsContainOperations, \.operationsContainResponses, \.pathParametersAreDefined
        )
        try document.validate(using: validator, strict: true)
        return document
    }

    private func buildPaths(in context: SchemaContext) throws -> OpenAPI.PathItem.Map {
        var paths: OpenAPI.PathItem.Map = [:]
        var operationIDs: Set<String> = []
        var operationKeys: Set<String> = []
        var templates: [String: String] = [:]
        for entry in entries {
            let normalized = try Self.normalizedPath(entry.path)
            try validateParameters(entry.parameters, captures: normalized.captures)
            let key = "\(entry.method.rawValue) \(normalized.path)"
            guard operationKeys.insert(key).inserted, operationIDs.insert(entry.operationID).inserted else {
                throw EndpointError.duplicateOperation(key)
            }
            let skeleton = normalized.path.replacingOccurrences(of: #"\{[^}]+\}"#, with: "{}", options: .regularExpression)
            if let previous = templates[skeleton], previous != normalized.path {
                throw EndpointError.invalidDefinition("Equivalent path templates: \(previous) and \(normalized.path)")
            }
            templates[skeleton] = normalized.path
            let path = OpenAPI.Path(rawValue: normalized.path)
            var item = paths[path]?.b ?? OpenAPI.PathItem()
            guard let method = OpenAPI.HttpMethod(rawValue: entry.method.rawValue) else {
                throw EndpointError.invalidDefinition("Unsupported HTTP method: \(entry.method)")
            }
            item.set(operation: try entry.operation(in: context), for: method)
            paths[path] = .b(item)
        }
        return paths
    }

    private func validateParameters(_ parameters: [EndpointParameter], captures: [String]) throws {
        let declared = parameters.filter { $0.location == .path }.map(\.name)
        guard Set(declared) == Set(captures), declared.count == captures.count else {
            throw EndpointError.invalidDefinition("Path captures must have exactly one matching required path parameter.")
        }
        var identities: Set<String> = []
        for parameter in parameters {
            let name = parameter.location == .header ? parameter.name.lowercased() : parameter.name
            guard identities.insert("\(parameter.location.rawValue):\(name)").inserted else {
                throw EndpointError.invalidDefinition("Duplicate parameter: \(parameter.name)")
            }
        }
    }

    private static func normalizedPath(_ path: String) throws -> (path: String, captures: [String]) {
        guard path.hasPrefix("/"), !path.contains("//"), path == "/" || !path.hasSuffix("/"),
              !path.contains(where: { $0.isWhitespace || $0.isNewline || "*{}?#".contains($0) }) else {
            throw EndpointError.invalidDefinition("Unsupported route path: \(path)")
        }
        var captures: [String] = []
        let components = try path.split(separator: "/").map { part -> String in
            guard part.hasPrefix(":") else {
                guard !part.contains(":") else { throw EndpointError.invalidDefinition("Partial captures are unsupported: \(path)") }
                return String(part)
            }
            let name = String(part.dropFirst())
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  !captures.contains(name) else { throw EndpointError.invalidDefinition("Invalid or repeated path capture: \(path)") }
            captures.append(name)
            return "{\(name)}"
        }
        return ("/" + components.joined(separator: "/"), captures)
    }
}
