import Foundation
import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import HummingbirdTesting
import OpenAPIKit
import Testing

@OpenAPISchema
struct Hello: Codable, Sendable {
    let message: String
}

private func endpoint(operationID: String = "hello", path: String = "/hello") -> JSONEndpoint<Hello> {
    JSONEndpoint(
        method: .get,
        path: path,
        operationID: operationID,
        summary: "Read a greeting.",
        responses: [.success(.ok, description: "A greeting.")]
    )
}

@Test
func declarationRegistersALiveHandlerAndExportsWithoutCallingIt() async throws {
    let declaration = endpoint()
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.requireHTTPBearerAuthentication(named: "token")
    builder.add(declaration)
    let document = try builder.buildValidated()
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(OpenAPI.Document.self, from: data)
    try decoded.validate()
    #expect(decoded.openAPIVersion == .v3_2_1)
    #expect(decoded.paths.count == 1)
    #expect(decoded.components.schemas.count == 1)
    #expect(decoded.components.securitySchemes.count == 1)

    let router = Router()
    declaration.register(on: router) { _, _ in
        JSONResponse(Hello(message: "Hello")) { value, status in
            Response(
                status: status,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(bytes: try JSONEncoder().encode(value)))
            )
        }
    }
    try router.validate()
    #expect(router.routes.count == 1)
    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/hello", method: .get)
        #expect(response.status == .ok)
        let hello = try JSONDecoder().decode(Hello.self, from: Data(response.body.readableBytesView))
        #expect(hello.message == "Hello")
    }
}

@Test
func rejectsDuplicateOperationsAndParameterizedPathsWithoutMetadata() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(endpoint())
    builder.add(endpoint())
    #expect(throws: EndpointError.duplicateOperation("GET /hello")) {
        try builder.buildValidated()
    }
    let incomplete = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    incomplete.add(endpoint(path: "/hello/:id"))
    #expect(throws: EndpointError.self) { try incomplete.buildValidated() }
}

@Test
func rejectsDuplicateResponseCodesAndMissingSuccess() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(JSONEndpoint<Hello>(
        method: .get, path: "/hello", operationID: "hello", summary: "Hello",
        responses: [.success(.ok, description: "One"), .success(.ok, description: "Two")]
    ))
    #expect(throws: EndpointError.self) { try builder.buildValidated() }
    let empty = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    empty.add(JSONEndpoint<Hello>(method: .get, path: "/hello", operationID: "hello", summary: "Hello", responses: []))
    #expect(throws: EndpointError.self) { try empty.buildValidated() }
}

@Test
func repeatedBuildsProduceIdenticalDocuments() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(endpoint())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(builder.buildValidated()) == encoder.encode(builder.buildValidated()))
}
