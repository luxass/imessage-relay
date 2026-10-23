import Hummingbird
import HummingbirdOpenAPIModels
import OpenAPIKit

public enum EndpointError: Error, Equatable {
    case invalidDefinition(String)
    case duplicateOperation(String)
    case undeclaredResponseStatus(Int)
    case rendererStatusMismatch
}

/// Carries a success payload and HTTP status from a route handler to Hummingbird.
///
/// The payload type lets JSONEndpoint require its declared output model at compile time.
/// Hummingbird calls response(from:context:) to render the payload into an HTTP response.
/// The supplied renderer owns JSON encoding and headers. This wrapper calls that renderer
/// and rejects a response whose status differs from the status declared by the handler.
public struct JSONResponse<Value: Encodable & Sendable>: ResponseGenerator, Sendable {
    public let value: Value
    public let status: HTTPResponse.Status
    private let render: @Sendable (Value, HTTPResponse.Status) throws -> Response

    public init(
        _ value: Value,
        status: HTTPResponse.Status = .ok,
        render: @escaping @Sendable (Value, HTTPResponse.Status) throws -> Response
    ) {
        self.value = value
        self.status = status
        self.render = render
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        let response = try render(value, status)
        guard response.status == status else { throw EndpointError.rendererStatusMismatch }
        return response
    }
}

public struct JSONEndpoint<Output: Encodable & Sendable & OpenAPISchemaProviding>: Sendable {
    public struct ResponseDefinition: Sendable {
        let status: HTTPResponse.Status
        let description: String
        let isSuccess: Bool
        let schema: @Sendable (SchemaContext) throws -> SchemaValue

        public static func success(_ status: HTTPResponse.Status, description: String) -> Self {
            Self(status: status, description: description, isSuccess: true) {
                try $0.schema(for: Output.self, direction: .response)
            }
        }

        public static func error<Body: OpenAPISchemaProviding>(
            _ status: HTTPResponse.Status, body: Body.Type, description: String
        ) -> Self {
            Self(status: status, description: description, isSuccess: false) {
                try $0.schema(for: Body.self, direction: .response)
            }
        }
    }

    public let definition: EndpointDefinition
    private let responses: [ResponseDefinition]
    public var method: HTTPRequest.Method { definition.method }
    public var path: String { definition.path }
    public var operationID: String { definition.operationID }

    public init(
        method: HTTPRequest.Method, path: String, operationID: String, summary: String,
        description: String? = nil, tags: [String] = [], parameters: [EndpointParameter] = [],
        requestBody: EndpointBody? = nil, responses: [ResponseDefinition], responseHeaders: OpenAPI.Header.Map = [:]
    ) {
        self.responses = responses
        self.definition = EndpointDefinition(
            method: method, path: path, operationID: operationID, summary: summary,
            description: description, tags: tags, parameters: parameters, requestBody: requestBody,
            responses: responses.map { response in
                EndpointResponse(response.status, description: response.description) { context in
                    guard response.isSuccess == (200...299).contains(response.status.code) else {
                        throw EndpointError.invalidDefinition("Response status does not match its success/error declaration.")
                    }
                    return [.json: .b(.init(schema: try response.schema(context)))]
                }
            },
            responseHeaders: responseHeaders
        )
    }

    private init(definition: EndpointDefinition, responses: [ResponseDefinition]) {
        self.definition = definition
        self.responses = responses
    }

    public func prefixed(by prefix: String) -> Self {
        Self(definition: definition.prefixed(by: prefix), responses: responses)
    }

    public func register<Routes: RouterMethods>(
        on router: Routes,
        use handler: @escaping @Sendable (Request, Routes.Context) async throws -> JSONResponse<Output>
    ) {
        router.on(RouterPath(path), method: method) { request, context in
            let response = try await handler(request, context)
            guard responses.contains(where: { $0.isSuccess && $0.status == response.status }) else {
                throw EndpointError.undeclaredResponseStatus(response.status.code)
            }
            return response
        }
    }
}

/// Explicit metadata for handlers whose response is not one JSON model, such as binary downloads and SSE.
public struct RawEndpoint: Sendable {
    public let definition: EndpointDefinition

    public init(_ definition: EndpointDefinition) { self.definition = definition }

    public func prefixed(by prefix: String) -> Self { Self(definition.prefixed(by: prefix)) }

    public func register<Routes: RouterMethods>(
        on router: Routes,
        use handler: @escaping @Sendable (Request, Routes.Context) async throws -> Response
    ) {
        router.on(RouterPath(definition.path), method: definition.method) { request, context in
            let response = try await handler(request, context)
            guard definition.responses.contains(where: { $0.status == response.status }) else {
                throw EndpointError.undeclaredResponseStatus(response.status.code)
            }
            return response
        }
    }
}
