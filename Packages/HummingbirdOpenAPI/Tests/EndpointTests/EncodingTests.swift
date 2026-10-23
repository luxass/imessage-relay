import Foundation
import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import OpenAPIKit
import Testing

@Test
func canonicalEncodingDoesNotRewriteLiteralExamples() throws {
    let example = AnyCodable([
        "type": AnyCodable("string"),
        SchemaContext.contentSchemaMarker: AnyCodable(["$ref": "literal data, not a schema reference"]),
    ])
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(EndpointDefinition(
        method: .get, path: "/hello", operationID: "hello", summary: "Read.",
        responses: [.json(.ok, body: Hello.self, description: "A greeting.", example: example)]
    ))
    let data = try builder.encodedJSON()
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains(SchemaContext.contentSchemaMarker))
    #expect(json.contains("literal data, not a schema reference"))
}

@Test
func canonicalEncodingChecksReferencesUnderEncodedPayloadPropertyMaps() throws {
    let nested = AnyCodable([
        "type": AnyCodable("object"),
        "properties": AnyCodable(["example": ["$ref": "#/components/schemas/Missing"]]),
    ])
    let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
    builder.add(EndpointDefinition(
        method: .get, path: "/events", operationID: "events", summary: "Stream.",
        responses: [EndpointResponse(.ok, description: "Encoded events.") { _ in
            let schema = JSONSchema.string(contentMediaType: .json).with(vendorExtensions: [SchemaContext.contentSchemaMarker: nested])
            return [.eventStream: .b(.init(itemSchema: schema))]
        }]
    ))
    #expect(throws: EndpointError.invalidDefinition("Unresolved or external reference: #/components/schemas/Missing")) {
        try builder.encodedJSON()
    }
}
