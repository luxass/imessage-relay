import Foundation
import Hummingbird
import HummingbirdOpenAPIModels
import HummingbirdTesting
import OpenAPIKit
import RelayCore
import Testing

@testable import RelayServer

@Test
func openAPIExportsAValidDeterministicCompleteDocument() throws {
    let data = try relayOpenAPIDocumentData()
    #expect(data == (try relayOpenAPIDocumentData()))
    #expect(data.last == 0x0A)
    let document = try JSONDecoder().decode(OpenAPI.Document.self, from: data)
    try document.validate(strict: true)
    #expect(document.openAPIVersion == .v3_2_1)
    #expect(document.info.version == packageVersion)
    let sender = try #require(document.paths["/v1/sender"]?.b?.get)
    #expect(sender.operationId == "getSender")
    #expect(sender.responses.count == 3)
    #expect(sender.responses[status: 200] != nil)
    #expect(sender.responses[status: 401] != nil)
    #expect(sender.responses[status: 500] != nil)
    #expect(document.components.securitySchemes["relayToken"] != nil)
    #expect(document.security.count == 1)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("field_details"))
    #expect(!json.contains("RELAY_TOKEN"))
}

@Test
func senderRouteKeepsItsJSONContract() async throws {
    let harness = ServerTestHarness()
    let router = harness.router()
    try router.validate()
    let expected = try RelayJSON.encoder.encode(await harness.sender.status())
    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/v1/sender", method: .get, headers: authorizationHeaders())
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
        #expect(response.headers[.init("x-request-id")!] != nil)
        #expect(Data(response.body.readableBytesView) == expected)
    }
    #expect(harness.sender.requests.isEmpty)
}

@Test
func openAPISenderSchemaMatchesEncodedFieldsAndAuthenticationErrors() async throws {
    let object = try #require(JSONSerialization.jsonObject(with: relayOpenAPIDocumentData()) as? [String: Any])
    let components = try #require(object["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: [String: Any]])
    let sender = try #require(schemas["Sender"])
    let properties = try #require(sender["properties"] as? [String: Any])
    let required = Set(try #require(sender["required"] as? [String]))
    #expect(Set(properties.keys) == [
        "id", "account_identity", "login", "configured", "availability", "reason", "permissions", "capabilities",
    ])
    #expect(required == ["id", "configured", "availability", "permissions", "capabilities"])
    #expect((properties["id"] as? [String: Any])?["type"] as? String == "string")
    #expect(sender["additionalProperties"] == nil)

    let harness = ServerTestHarness()
    try await Application(router: harness.router()).test(.router) { client in
        let response = try await client.execute(uri: "/v1/sender", method: .get)
        #expect(response.status == .unauthorized)
        #expect(try errorBody(response.body).code == .invalidAuthentication)
        #expect(response.headers[.init("x-request-id")!] != nil)
    }
}

@Test
func openAPITimestampOverrideDescribesTheExistingStringCodec() throws {
    let schema = Timestamp.openAPISchema(in: SchemaContext(), direction: .response)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
    #expect(object["type"] as? String == "string")
    #expect(object["format"] as? String == "date-time")
    let value = Timestamp(Date(timeIntervalSince1970: 0))
    let data = try RelayJSON.encoder.encode(value)
    #expect(String(data: data, encoding: .utf8) == #""1970-01-01T00:00:00.000Z""#)
    #expect(try RelayJSON.decoder.decode(Timestamp.self, from: data) == value)
}
