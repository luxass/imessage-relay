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

@Test
func documentUsesTheRequestedOpenAPIVersion() throws {
    let document = try greetingDocumentBuilder().buildValidated()

    #expect(document.openAPIVersion == .v3_2_1)
}

@Test
func documentContainsTheDeclaredOperation() throws {
    let document = try greetingDocumentBuilder().buildValidated()
    let operation = try #require(document.paths["/hello"]?.b?.get)

    #expect(document.paths.count == 1)
    #expect(operation.operationId == "hello")
}

@Test
func documentRegistersTheResponseModel() throws {
    let document = try greetingDocumentBuilder().buildValidated()

    #expect(document.components.schemas.count == 1)
    #expect(document.components.schemas["Hello_response"] != nil)
}

@Test
func documentIncludesBearerAuthentication() throws {
    let builder = greetingDocumentBuilder()
    builder.requireHTTPBearerAuthentication(named: "token")

    let document = try builder.buildValidated()

    #expect(document.components.securitySchemes.count == 1)
    #expect(document.components.securitySchemes["token"] != nil)
    #expect(document.security.count == 1)
}

@Test
func exportedDocumentDecodesWithOpenAPIKit() throws {
    let data = try greetingDocumentBuilder().encodedJSON()
    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: data)

    try document.validate(strict: true)
}

@Test
func registeredEndpointReturnsItsDeclaredPayload() async throws {
    let router = Router()
    greetingEndpoint().register(on: router) { _, _ in
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
        let payload = try JSONDecoder().decode(Hello.self, from: Data(response.body.readableBytesView))

        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        #expect(payload.message == "Hello")
    }
}

@Test
func duplicateOperationsAreRejected() throws {
    let builder = greetingDocumentBuilder()
    builder.add(greetingEndpoint())

    #expect(throws: EndpointError.duplicateOperation("GET /hello")) {
        try builder.buildValidated()
    }
}

@Test
func duplicateResponseCodesAreRejected() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(greetingEndpoint(responses: [
        .success(.ok, description: "One"),
        .success(.ok, description: "Two"),
    ]))

    #expect(throws: EndpointError.invalidDefinition("Duplicate response status 200 for hello.")) {
        try builder.buildValidated()
    }
}

@Test
func missingSuccessResponseIsRejected() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(greetingEndpoint(responses: []))

    #expect(throws: EndpointError.invalidDefinition("An endpoint needs an operation ID, summary, and success response.")) {
        try builder.buildValidated()
    }
}

@Test
func repeatedExportsProduceIdenticalJSON() throws {
    let builder = greetingDocumentBuilder()

    let first = try builder.encodedJSON()
    let second = try builder.encodedJSON()

    #expect(first == second)
}

func greetingEndpoint(
    responses: [JSONEndpoint<Hello>.ResponseDefinition] = [.success(.ok, description: "A greeting.")]
) -> JSONEndpoint<Hello> {
    JSONEndpoint(
        method: .get,
        path: "/hello",
        operationID: "hello",
        summary: "Read a greeting.",
        responses: responses
    )
}

private func greetingDocumentBuilder() -> OpenAPIDocumentBuilder {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(greetingEndpoint())
    return builder
}
