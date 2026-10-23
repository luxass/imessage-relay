import Foundation
import Hummingbird
import HummingbirdOpenAPIModels
import OpenAPIKit

public struct EndpointParameter: Sendable {
    public enum Location: String, Sendable { case path, query, header, cookie }
    public let name: String
    public let location: Location
    private let description: String
    private let required: Bool
    private let schema: @Sendable (SchemaContext) throws -> SchemaValue

    public init(name: String, location: Location, description: String, required: Bool = false, schema: SchemaValue) {
        self.name = name
        self.location = location
        self.description = description
        self.required = required
        self.schema = { _ in schema }
    }

    public init<Value: OpenAPISchemaProviding>(
        name: String, location: Location, description: String, required: Bool = false, type: Value.Type
    ) {
        self.name = name
        self.location = location
        self.description = description
        self.required = required
        self.schema = { try $0.schema(for: Value.self, direction: .request) }
    }

    func parameter(in registry: SchemaContext) throws -> OpenAPI.Parameter {
        guard !name.isEmpty, !description.isEmpty else {
            throw EndpointError.invalidDefinition("Parameters need a name and description.")
        }
        if location == .header && ["accept", "content-type", "authorization"].contains(name.lowercased()) {
            throw EndpointError.invalidDefinition("Use media content declarations or security instead of the \(name) header parameter.")
        }
        let schema = try schema(registry)
        let context: OpenAPI.Parameter.Context
        switch location {
        case .path: context = .path(schema: schema)
        case .query: context = .query(required: required, schema: schema)
        case .header: context = .header(required: required, schema: schema)
        case .cookie: context = .cookie(required: required, schema: schema)
        }
        return OpenAPI.Parameter(name: name, context: context, description: description)
    }
}

public struct EndpointBody: Sendable {
    let description: String
    let required: Bool
    let content: @Sendable (SchemaContext) throws -> OpenAPI.Content.Map

    public init(
        description: String, required: Bool = true,
        content: @escaping @Sendable (SchemaContext) throws -> OpenAPI.Content.Map
    ) {
        self.description = description
        self.required = required
        self.content = content
    }

    public static func json<Value: OpenAPISchemaProviding>(
        _ type: Value.Type, description: String, required: Bool = true, example: AnyCodable? = nil
    ) -> Self {
        Self(description: description, required: required) { context in
            [.json: .b(.init(schema: try context.schema(for: Value.self, direction: .request), example: example))]
        }
    }

    public static func binary(mediaTypes: [OpenAPI.ContentType], description: String) -> Self {
        Self(description: description) { _ in
            var content: OpenAPI.Content.Map = [:]
            for mediaType in mediaTypes { content[mediaType] = .b(.init(schema: nil)) }
            return content
        }
    }

    func request(in context: SchemaContext) throws -> OpenAPI.Request {
        let content = try content(context)
        guard !content.isEmpty, !description.isEmpty else {
            throw EndpointError.invalidDefinition("A request body needs content and a description.")
        }
        return OpenAPI.Request(description: description, content: content, required: required)
    }
}

public struct EndpointResponse: Sendable {
    let status: HTTPResponse.Status
    let description: String
    let headers: OpenAPI.Header.Map
    let content: @Sendable (SchemaContext) throws -> OpenAPI.Content.Map

    public init(
        _ status: HTTPResponse.Status, description: String, headers: OpenAPI.Header.Map = [:],
        content: @escaping @Sendable (SchemaContext) throws -> OpenAPI.Content.Map
    ) {
        self.status = status
        self.description = description
        self.headers = headers
        self.content = content
    }

    public static func json<Value: OpenAPISchemaProviding>(
        _ status: HTTPResponse.Status, body: Value.Type, description: String, example: AnyCodable? = nil
    ) -> Self {
        Self(status, description: description) { context in
            [.json: .b(.init(schema: try context.schema(for: Value.self, direction: .response), example: example))]
        }
    }
}

public struct EndpointDefinition: Sendable {
    public let method: HTTPRequest.Method
    public let path: String
    public let operationID: String
    public let summary: String
    public let description: String?
    public let tags: [String]
    public let parameters: [EndpointParameter]
    public let requestBody: EndpointBody?
    public let responses: [EndpointResponse]
    public let responseHeaders: OpenAPI.Header.Map

    public init(
        method: HTTPRequest.Method, path: String, operationID: String, summary: String,
        description: String? = nil, tags: [String] = [], parameters: [EndpointParameter] = [],
        requestBody: EndpointBody? = nil, responses: [EndpointResponse], responseHeaders: OpenAPI.Header.Map = [:]
    ) {
        self.method = method
        self.path = path
        self.operationID = operationID
        self.summary = summary
        self.description = description
        self.tags = tags
        self.parameters = parameters
        self.requestBody = requestBody
        self.responses = responses
        self.responseHeaders = responseHeaders
    }

    public func prefixed(by prefix: String) -> Self {
        Self(method: method, path: prefix + path, operationID: operationID, summary: summary,
             description: description, tags: tags, parameters: parameters, requestBody: requestBody,
             responses: responses, responseHeaders: responseHeaders)
    }

    func operation(in context: SchemaContext) throws -> OpenAPI.Operation {
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              responses.contains(where: { (200...299).contains($0.status.code) }) else {
            throw EndpointError.invalidDefinition("An endpoint needs an operation ID, summary, and success response.")
        }
        var result: OpenAPI.Response.Map = [:]
        for response in responses {
            let code = response.status.code
            guard (100...599).contains(code), !response.description.isEmpty else {
                throw EndpointError.invalidDefinition("Invalid response for \(operationID).")
            }
            let key = OpenAPI.Response.StatusCode(integerLiteral: code)
            guard result[key] == nil else { throw EndpointError.invalidDefinition("Duplicate response status \(code) for \(operationID).") }
            var headers = responseHeaders
            for (name, header) in response.headers { headers[name] = header }
            result[key] = .b(.init(description: response.description, headers: headers.isEmpty ? nil : headers,
                                   content: try response.content(context)))
        }
        return OpenAPI.Operation(tags: tags.isEmpty ? nil : tags, summary: summary, description: description,
                                 operationId: operationID, parameters: try parameters.map { .b(try $0.parameter(in: context)) },
                                 requestBody: try requestBody?.request(in: context), responses: result)
    }
}
