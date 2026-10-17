import Foundation
import Hummingbird
import HTTPTypes
import HummingbirdOpenAPIModels
import NIOCore

public struct NoBody: OpenAPISchema {
    public init() {}
    public static func openAPISchema(in schemas: inout OpenAPISchemas) -> JSONSchema {
        .object(properties: [:], required: [])
    }
}

public struct StringHeader: Sendable {
    public let name: String
    public let description: String
    public let required: Bool

    public init(_ name: String, description: String, required: Bool = false) {
        self.name = name
        self.description = description
        self.required = required
    }

    public func value(in request: Request) -> String? {
        guard let name = HTTPField.Name(name) else { return nil }
        return request.headers[name]
    }
}

public struct JSONRouteInfo: Sendable {
    public let operationID: String
    public let summary: String
    public let tag: String
    public let anchor: String?
    public let headers: [StringHeader]

    /// Fail fast: reject invalid or case-insensitively duplicate header names
    /// at construction instead of waiting for document generation.
    public init(
        operationID: String, summary: String, tag: String,
        anchor: String? = nil, headers: [StringHeader] = []
    ) throws {
        for header in headers {
            guard HTTPField.Name(header.name) != nil else {
                throw JSONRouteDocumentError.invalidHeaderName(header.name)
            }
        }
        var headerNames: Set<String> = []
        for header in headers {
            guard headerNames.insert(header.name.lowercased()).inserted else {
                throw JSONRouteDocumentError.duplicateParameter("header", header.name)
            }
        }
        self.headers = headers
        self.operationID = operationID
        self.summary = summary
        self.tag = tag
        self.anchor = anchor
    }
}

public enum JSONInputError: Error, Sendable, Equatable {
    case unknownFields([String])
}

/// Use the same registration function with a live router or a document-only
/// recorder. Handlers return their declared output model, never an opaque Response.
public final class JSONRoutes<Context: RequestContext> {
    private let router: Router<Context>?
    private let responseHeaders: @Sendable (Context) -> HTTPFields
    private var operations: [RecordedOperation] = []
    private var operationIDs: Set<String> = []
    private var templatePaths: [String: String] = [:]
    private var routeKeys: Set<String> = []

    public init(
        router: Router<Context>? = nil,
        responseHeaders: @escaping @Sendable (Context) -> HTTPFields = { _ in [:] }
    ) {
        self.router = router
        self.responseHeaders = responseHeaders
    }

    public func get<Output: OpenAPISchema>(
        _ path: String,
        info: JSONRouteInfo,
        use handler: @escaping @Sendable (Request, Context) async throws -> Output
    ) throws {
        try record(path: path, method: .get, status: .ok, info: info, input: NoBody.self, output: Output.self)
        router?.on(RouterPath(path), method: .get) { [responseHeaders] request, context in
            try Self.response(try await handler(request, context), status: .ok, headers: responseHeaders(context))
        }
    }

    public func post<Input: OpenAPISchema, Output: OpenAPISchema>(
        _ path: String,
        info: JSONRouteInfo,
        status: HTTPResponse.Status = .ok,
        maximumBodyBytes: @escaping @Sendable (Context) -> Int = { _ in 1024 * 1024 },
        use handler: @escaping @Sendable (Input, Request, Context) async throws -> Output
    ) throws {
        try record(path: path, method: .post, status: status, info: info, input: Input.self, output: Output.self)
        router?.on(RouterPath(path), method: .post) { [responseHeaders] request, context in
            let body = try await request.body.collect(upTo: maximumBodyBytes(context))
            let payload = try Self.decode(Input.self, from: Data(body.readableBytesView))
            return try Self.response(
                try await handler(payload, request, context), status: status, headers: responseHeaders(context)
            )
        }
    }

    public func document<Failure: OpenAPISchema>(
        title: String, version: String, serverURL: String,
        errorModel: Failure.Type,
        bearerAuthentication: Bool = false,
        description: String = ""
    ) throws -> OpenAPIDocument {
        var schemas = OpenAPISchemas()
        let errorSchema = try schemas.schema(for: errorModel)
        var paths: [String: [String: OpenAPIDocument.Operation]] = [:]
        for operation in operations {
            let path = operation.documentPath
            let method = operation.method.rawValue.lowercased()
            let input = try operation.input(&schemas)
            let output = try operation.output(&schemas)
            let pathParameters = path.split(separator: "/").filter { $0.hasPrefix("{") }.map {
                OpenAPIDocument.Parameter(
                    name: String($0.dropFirst().dropLast()), location: "path", required: true,
                    description: "Percent-encoded path segment.", schema: .string
                )
            }
            let headerParameters = operation.info.headers.map { header in
                OpenAPIDocument.Parameter(
                    name: header.name, location: "header", required: header.required,
                    description: header.description, schema: .string
                )
            }
            paths[path, default: [:]][method] = OpenAPIDocument.Operation(
                operationId: operation.info.operationID,
                summary: operation.info.summary,
                tags: [operation.info.tag],
                anchor: operation.info.anchor,
                parameters: pathParameters + headerParameters,
                requestBody: operation.hasBody ? .init(schema: input) : nil,
                responses: [
                    String(operation.status.code): .init(description: operation.status.reasonPhrase, schema: output),
                    "default": .init(description: "Error returned by the application's middleware.", schema: errorSchema),
                ]
            )
        }
        return OpenAPIDocument(
            title: title, version: version, description: description, serverURL: serverURL,
            paths: paths, schemas: schemas.components, bearerAuthentication: bearerAuthentication
        )
    }

    public typealias DocumentError = JSONRouteDocumentError

    /// Fail fast: validate the path, template, operation ID, and method/route
    /// combination at registration time so document generation cannot fail on them.
    private func record<Input: OpenAPISchema, Output: OpenAPISchema>(
        path: String, method: HTTPRequest.Method, status: HTTPResponse.Status,
        info: JSONRouteInfo, input: Input.Type, output: Output.Type
    ) throws {
        let documentPath = try Self.documentPath(path)
        let template = documentPath.split(separator: "/")
            .map { $0.hasPrefix("{") ? "{}" : String($0) }.joined(separator: "/")
        if let existing = templatePaths[template], existing != documentPath {
            throw DocumentError.conflictingPathTemplates(existing, documentPath)
        }
        templatePaths[template] = documentPath
        guard operationIDs.insert(info.operationID).inserted else {
            throw DocumentError.duplicateOperationID(info.operationID)
        }
        let routeKey = "\(method.rawValue.lowercased()) \(documentPath)"
        guard routeKeys.insert(routeKey).inserted else {
            throw DocumentError.duplicateRoute(method.rawValue.lowercased(), documentPath)
        }
        operations.append(RecordedOperation(
            documentPath: documentPath, method: method, status: status, info: info,
            hasBody: method == .post,
            input: { try $0.schema(for: Input.self) }, output: { try $0.schema(for: Output.self) }
        ))
    }

    private static func documentPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("*"), !path.contains("?"), !path.contains("#") else {
            throw DocumentError.unsupportedPath(path)
        }
        var captureNames: Set<String> = []
        let segments = try path.split(separator: "/").map { segment in
            if segment.hasPrefix(":") {
                let name = segment.dropFirst()
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                    throw DocumentError.unsupportedPath(path)
                }
                guard captureNames.insert(String(name)).inserted else {
                    throw DocumentError.duplicateParameter("path", String(name))
                }
                return "{\(name)}"
            }
            guard !segment.contains("{"), !segment.contains("}") else { throw DocumentError.unsupportedPath(path) }
            return String(segment)
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func response<Output: Encodable>(
        _ value: Output, status: HTTPResponse.Status, headers: HTTPFields
    ) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var headers = headers
        headers[.contentType] = "application/json; charset=utf-8"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: try encoder.encode(value))))
    }

    private static func decode<Input: OpenAPISchema>(_ type: Input.Type, from data: Data) throws -> Input {
        var schemas = OpenAPISchemas()
        let schema = try schemas.schema(for: type)
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON.", underlyingError: error))
        }
        try checkUnknownFields(json, schema: schema, components: schemas.components)
        return try JSONDecoder().decode(type, from: data)
    }

    // JSONDecoder handles type/required-field errors. This check only enforces
    // the generated closed-object policy, including nested request objects.
    private static func checkUnknownFields(_ value: Any, schema: JSONSchema, components: [String: JSONSchema]) throws {
        switch schema {
        case .reference(let name):
            if let resolved = components[name] { try checkUnknownFields(value, schema: resolved, components: components) }
        case .nullable(let wrapped):
            if !(value is NSNull) { try checkUnknownFields(value, schema: wrapped, components: components) }
        case .array(let item):
            if let array = value as? [Any] {
                for value in array { try checkUnknownFields(value, schema: item, components: components) }
            }
        case .object(let properties, _):
            if let object = value as? [String: Any] {
                let unknown = object.keys.filter { properties[$0] == nil }.sorted()
                guard unknown.isEmpty else { throw JSONInputError.unknownFields(unknown) }
                for (key, value) in object {
                    if let schema = properties[key] { try checkUnknownFields(value, schema: schema, components: components) }
                }
            }
        default: break
        }
    }
}

public enum JSONRouteDocumentError: Error, Equatable {
    case duplicateRoute(String, String)
    case duplicateOperationID(String)
    case conflictingPathTemplates(String, String)
    case duplicateParameter(String, String)
    case invalidHeaderName(String)
    case unsupportedPath(String)
}

private struct RecordedOperation {
    let documentPath: String
    let method: HTTPRequest.Method
    let status: HTTPResponse.Status
    let info: JSONRouteInfo
    let hasBody: Bool
    let input: (inout OpenAPISchemas) throws -> JSONSchema
    let output: (inout OpenAPISchemas) throws -> JSONSchema
}
