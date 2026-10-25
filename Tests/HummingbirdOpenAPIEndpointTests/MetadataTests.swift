import Foundation
import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import HummingbirdTesting
import OpenAPIKit
import Testing

private let octetStream = OpenAPI.ContentType(rawValue: "application/octet-stream")!

@Test
func endpointExportsItsParametersAndBody() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(createThingEndpoint().definition)

    let document = try builder.buildValidated()
    let operation = try #require(document.paths["/things/{id}"]?.b?.post)
    let parameters = try operation.parameters.map { try #require($0.b) }
    let identifier = try #require(parameters.first { $0.name == "id" })

    #expect(parameters.count == 3)
    #expect(Set(parameters.map(\.name)) == ["id", "mode", "X-Key"])
    #expect(identifier.required == true)
    #expect(operation.requestBody?.b?.required == true)
    // Hello has the same request and response schema, so both directions share one component.
    #expect(document.components.schemas.count == 1)
    #expect(document.components.schemas["Hello"] != nil)
}

@Test
func endpointRegistersItsLiveRoute() async throws {
    let router = Router()
    createThingEndpoint().register(on: router) { _, _ in
        JSONResponse(Hello(message: "Created"), status: .created) { _, status in
            Response(status: status)
        }
    }

    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/things/example", method: .post)
        #expect(response.status == .created)
    }
}

@Test
func binaryRequestAndResponseDescribeRawBytes() throws {
    let endpoint = RawEndpoint(EndpointDefinition(
        method: .post,
        path: "/bytes",
        operationID: "uploadBytes",
        summary: "Upload bytes.",
        requestBody: .binary(mediaTypes: [octetStream], description: "Raw file bytes."),
        responses: [EndpointResponse(.ok, description: "Raw bytes.") { _ in
            [octetStream: .b(.init(schema: nil))]
        }]
    ))
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(endpoint.definition)

    let document = try builder.buildValidated()
    let operation = try #require(document.paths["/bytes"]?.b?.post)
    let request = try #require(operation.requestBody?.b?.content[octetStream]?.b)
    let response = try #require(operation.responses[status: 200]?.b?.content[octetStream]?.b)

    #expect(request.schema == nil)
    #expect(response.schema == nil)
}

@Test
func sseFramesDescribeJSONEncodedPayloads() throws {
    let endpoint = RawEndpoint(EndpointDefinition(
        method: .get,
        path: "/events",
        operationID: "readEvents",
        summary: "Read events.",
        responses: [EndpointResponse(.ok, description: "Events.") { context in
            let frame = JSONSchema.object(properties: [
                "event": .string(allowedValues: "greeting"),
                "data": try context.encodedJSONString(for: Hello.self, direction: .response),
            ])
            return [.eventStream: .b(.init(itemSchema: frame))]
        }]
    ))
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(endpoint.definition)

    let data = try builder.encodedJSON()
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json.contains("itemSchema"))
    #expect(json.contains("contentSchema"))
    #expect(json.contains("contentMediaType"))
    #expect(!json.contains(SchemaContext.contentSchemaMarker))
    #expect(!json.contains("base64"))

    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: data)
    try document.validate(strict: true)
}

@Test
func missingPathParameterIsRejected() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(readItemEndpoint(path: "/items/:id"))

    #expect(throws: EndpointError.invalidDefinition("Path captures must have exactly one matching required path parameter.")) {
        try builder.buildValidated()
    }
}

@Test
func headerParameterNamesAreCaseInsensitive() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(readItemEndpoint(path: "/items", parameters: [
        .init(name: "X-Key", location: .header, description: "Key.", schema: .string),
        .init(name: "x-key", location: .header, description: "Key.", schema: .string),
    ]))

    #expect(throws: EndpointError.invalidDefinition("Duplicate parameter: x-key")) {
        try builder.buildValidated()
    }
}

@Test
func equivalentPathTemplatesAreRejected() throws {
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    for name in ["id", "other"] {
        builder.add(readItemEndpoint(
            path: "/items/:" + name,
            operationID: name,
            parameters: [.init(name: name, location: .path, description: "ID.", schema: .string)]
        ))
    }

    #expect(throws: EndpointError.invalidDefinition("Equivalent path templates: /items/{id} and /items/{other}")) {
        try builder.buildValidated()
    }
}

private func createThingEndpoint() -> JSONEndpoint<Hello> {
    JSONEndpoint(
        method: .post,
        path: "/things/:id",
        operationID: "createThing",
        summary: "Create one thing.",
        tags: ["Things"],
        parameters: [
            .init(name: "id", location: .path, description: "Thing ID.", schema: .string),
            .init(name: "mode", location: .query, description: "Creation mode.", schema: .string(defaultValue: "normal")),
            .init(name: "X-Key", location: .header, description: "Client operation key.", schema: .string),
        ],
        requestBody: .json(Hello.self, description: "The greeting.", example: AnyCodable(["message": "Hello"])),
        responses: [.success(.created, description: "Created.")]
    )
}

private func readItemEndpoint(
    path: String,
    operationID: String = "readItem",
    parameters: [EndpointParameter] = []
) -> EndpointDefinition {
    EndpointDefinition(
        method: .get,
        path: path,
        operationID: operationID,
        summary: "Read an item.",
        parameters: parameters,
        responses: [.json(.ok, body: Hello.self, description: "An item.")]
    )
}
