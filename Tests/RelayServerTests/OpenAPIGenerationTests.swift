import Foundation
import HummingbirdOpenAPIModels
import RelayCore
import Testing

@testable import RelayServer

@Test
func generatedOpenAPIHasOnlyTheMigratedRoutesAndTheirActualModels() throws {
    let data = try relayOpenAPIDocument()
    #expect(data == (try relayOpenAPIDocument()))
    let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(document["openapi"] as? String == "3.1.0")
    let paths = try #require(document["paths"] as? [String: Any])
    #expect(Set(paths.keys) == Set(["/v1/status", "/v1/messages"]))
    let operation = try #require((paths["/v1/messages"] as? [String: Any])?["post"] as? [String: Any])
    let responses = try #require(operation["responses"] as? [String: Any])
    #expect(responses["202"] != nil)
    #expect(operation["requestBody"] != nil)
    let components = try #require(document["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])
    let submission = try #require(schemas["RelayCore.MessageSubmission"] as? [String: Any])
    let properties = try #require(submission["properties"] as? [String: Any])
    #expect(Set(properties.keys) == Set(MessageSubmission.jsonPropertyNames))
    #expect(submission["additionalProperties"] as? Bool == false)
    #expect((document["security"] as? [[String: [String]]]) == [["bearerAuth": []]])
}

@Test
func typedStatusPayloadPreservesTheExistingWireRepresentation() async throws {
    let status = ServiceStatus(
        version: packageVersion,
        healthy: true,
        database: DatabaseStatus(ready: true, identity: "database", error: nil),
        sender: await FakeMessageSender.available().status()
    )
    #expect(try RelayJSON.encoder.encode(StatusPayload(status)) == RelayJSON.encoder.encode(status))
}

@Test
func typedSendReceiptPreservesNullMediaIdentifiersAndOptionalFields() throws {
    let response = SendMessageResponse.tracking(
        requestID: try RequestID(validating: "request-id"),
        status: .accepted,
        media: [MediaReceipt(
            requestedMediaID: try MediaID(validating: "upload-id"), mediaID: nil, messageID: nil
        )]
    )
    #expect(try RelayJSON.encoder.encode(SendReceiptPayload(response)) == RelayJSON.encoder.encode(response))
    var schemas = OpenAPISchemas()
    let reference = try schemas.schema(for: MediaReceiptPayload.self)
    guard case .reference(let name) = reference,
          case .object(let properties, let required) = schemas.components[name] else {
        Issue.record("Missing generated media receipt schema")
        return
    }
    #expect(Set(required) == Set(MediaReceiptPayload.jsonPropertyNames))
    #expect(properties["media_id"] == .nullable(.string))
}

@Test
func generatedSubmissionRoundTripsThroughTheDomainDecoder() throws {
    let raw = Data(#"{"participants":["person@example.com","+15005550006"],"text":"hi"}"#.utf8)
    let wire = try RelayJSON.decoder.decode(MessageSubmission.self, from: raw)
    let domain = try wire.validated()
    let encoded = try RelayJSON.encoder.encode(domain)
    #expect(try RelayJSON.decoder.decode(MessageSubmission.self, from: encoded) == wire)
    #expect(try RelayJSON.decoder.decode(SendMessageRequest.self, from: encoded) == domain)
}
