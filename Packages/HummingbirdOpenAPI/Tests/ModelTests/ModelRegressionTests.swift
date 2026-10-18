import Foundation
import HummingbirdOpenAPIModels
import Testing

@OpenAPIModel
private struct EncoderNames: Codable, Sendable {
    let encoder: String
    let container: String?
    let decoder: String
}

@OpenAPIModel(encodeNil: true)
private struct NullableEncoderNames: Codable, Sendable {
    let encoder: String?
    let container: String?
}

@OpenAPIModel
private struct EmptyModel: Codable, Sendable {}

@Test func generatedCodecLocalsDoNotShadowModelProperties() throws {
    let value = EncoderNames(encoder: "encoder value", container: "container value", decoder: "decoder value")
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(EncoderNames.self, from: data)
    #expect(decoded.encoder == value.encoder)
    #expect(decoded.container == value.container)
    #expect(decoded.decoder == value.decoder)

    let omitted = try JSONEncoder().encode(EncoderNames(encoder: "value", container: nil, decoder: "value"))
    let object = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
    #expect(object["container"] == nil)

    let nullable = try JSONEncoder().encode(NullableEncoderNames(encoder: "value", container: nil))
    let nullableObject = try #require(JSONSerialization.jsonObject(with: nullable) as? [String: Any])
    #expect(nullableObject["encoder"] as? String == "value")
    #expect(nullableObject["container"] is NSNull)
    let nullableDecoded = try JSONDecoder().decode(NullableEncoderNames.self, from: nullable)
    #expect(nullableDecoded.encoder == "value")
    #expect(nullableDecoded.container == nil)
}

@Test func emptyModelsEncodeDecodeAndGenerateClosedObjectSchemas() throws {
    let data = try JSONEncoder().encode(EmptyModel())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object.isEmpty)
    _ = try JSONDecoder().decode(EmptyModel.self, from: data)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(EmptyModel.self, from: Data("[]".utf8))
    }
    #expect(EmptyModel.jsonPropertyNames.isEmpty)
    var schemas = OpenAPISchemas()
    guard case .reference(let name) = try schemas.schema(for: EmptyModel.self) else {
        Issue.record("Missing empty model reference")
        return
    }
    #expect(schemas.components[name] == .object(properties: [:], required: []))
}
