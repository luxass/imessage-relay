import Foundation
import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import HummingbirdTesting
import OpenAPIKit
import Testing

private let octetStream = OpenAPI.ContentType(rawValue: "application/octet-stream")!

@Test
func parameterizedGroupedRoutesExportBodiesAndRequiredParameters() async throws {
    let endpoint = JSONEndpoint<Hello>(
        method: .post, path: "/things/:id", operationID: "createThing", summary: "Create one thing.",
        tags: ["Things"],
        parameters: [
            .init(name: "id", location: .path, description: "Thing ID.", schema: .string),
            .init(name: "mode", location: .query, description: "Creation mode.", schema: .string(defaultValue: "normal")),
            .init(name: "X-Key", location: .header, description: "Client operation key.", schema: .string),
        ],
        requestBody: .json(Hello.self, description: "The greeting.", example: AnyCodable(["message": "Hello"])),
        responses: [.success(.created, description: "Created.")]
    ).prefixed(by: "/api")
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(endpoint)
    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: builder.encodedJSON())
    let operation = try #require(document.paths["/api/things/{id}"]?.b?.post)
    #expect(operation.parameters.count == 3)
    #expect(operation.parameters.first?.b?.required == true)
    #expect(operation.requestBody?.b?.required == true)
    #expect(document.components.schemas["Hello_request"] != nil)
    #expect(document.components.schemas["Hello_response"] != nil)
    let router = Router()
    endpoint.register(on: router) { _, _ in
        JSONResponse(Hello(message: "Created"), status: .created) { _, status in Response(status: status) }
    }
    try await Application(router: router).test(.router) { client in
        let result = try await client.execute(uri: "/api/things/example", method: .post)
        #expect(result.status == .created)
    }
}

@Test
func rawBinaryAndSSEDescriptionsUseStandardMediaSemantics() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(RawEndpoint(EndpointDefinition(
        method: .get, path: "/events", operationID: "events", summary: "Read events.",
        responses: [EndpointResponse(.ok, description: "Events.") { context in
            let frame = JSONSchema.object(properties: [
                "event": .string(allowedValues: "greeting"),
                "data": try context.encodedJSONString(for: Hello.self, direction: .response),
            ])
            return [.eventStream: .b(.init(itemSchema: frame))]
        }]
    )))
    builder.add(RawEndpoint(EndpointDefinition(
        method: .post, path: "/bytes", operationID: "bytes", summary: "Upload bytes.",
        requestBody: .binary(mediaTypes: [octetStream], description: "Raw file bytes."),
        responses: [EndpointResponse(.ok, description: "Raw bytes.") { _ in
            [octetStream: .b(.init(schema: nil))]
        }]
    )))
    let data = try builder.encodedJSON()
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("contentSchema"))
    #expect(json.contains("contentMediaType"))
    #expect(!json.contains(SchemaContext.contentSchemaMarker))
    #expect(!json.contains("base64"))
    #expect(json.contains("itemSchema"))
    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: data)
    try document.validate(strict: true)
    #expect(document.paths["/bytes"]?.b?.post?.requestBody?.b?.content[octetStream]?.b?.schema == nil)
}

@Test
func missingOrEquivalentPathParametersAndCaseInsensitiveHeaderDuplicatesFail() throws {
    let missing = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    missing.add(EndpointDefinition(method: .get, path: "/items/:id", operationID: "read", summary: "Read.",
                                   responses: [.json(.ok, body: Hello.self, description: "An item.")]))
    #expect(throws: EndpointError.self) { try missing.buildValidated() }

    let duplicate = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    duplicate.add(EndpointDefinition(method: .get, path: "/items", operationID: "items", summary: "Items.", parameters: [
        .init(name: "X-Key", location: .header, description: "Key.", schema: .string),
        .init(name: "x-key", location: .header, description: "Key.", schema: .string),
    ], responses: [.json(.ok, body: Hello.self, description: "Items.")]))
    #expect(throws: EndpointError.self) { try duplicate.buildValidated() }

    let equivalent = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    for name in ["id", "other"] {
        equivalent.add(EndpointDefinition(method: .get, path: "/items/:" + name, operationID: name, summary: "Read.", parameters: [
            .init(name: name, location: .path, description: "ID.", schema: .string),
        ], responses: [.json(.ok, body: Hello.self, description: "Item.")]))
    }
    #expect(throws: EndpointError.self) { try equivalent.buildValidated() }
}
