import Foundation
import HummingbirdOpenAPIModels

public struct OpenAPIDocument: Encodable, Sendable {
    let openapi = "3.1.0"
    let info: Info
    let servers: [Server]
    let paths: [String: [String: Operation]]
    let components: Components
    let security: [[String: [String]]]

    init(
        title: String, version: String, description: String, serverURL: String,
        paths: [String: [String: Operation]], schemas: [String: JSONSchema], bearerAuthentication: Bool
    ) {
        info = Info(title: title, version: version, description: description)
        servers = [Server(url: serverURL)]
        self.paths = paths
        components = Components(
            schemas: schemas,
            securitySchemes: bearerAuthentication ? ["bearerAuth": .init(type: "http", scheme: "bearer")] : [:]
        )
        security = bearerAuthentication ? [["bearerAuth": []]] : []
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data([0x0A])
    }

    struct Info: Encodable, Sendable {
        let title: String
        let version: String
        let description: String
    }
    struct Server: Encodable, Sendable { let url: String }
    struct SecurityScheme: Encodable, Sendable {
        let type: String
        let scheme: String
    }
    struct Components: Encodable, Sendable {
        let schemas: [String: JSONSchema]
        let securitySchemes: [String: SecurityScheme]
    }
    struct Parameter: Encodable, Sendable {
        let name: String
        let location: String
        let required: Bool
        let description: String
        let schema: JSONSchema
        enum CodingKeys: String, CodingKey {
            case name, required, description, schema
            case location = "in"
        }
    }
    struct MediaType: Encodable, Sendable { let schema: JSONSchema }
    struct Body: Encodable, Sendable {
        let required = true
        let content: [String: MediaType]
        init(schema: JSONSchema) { content = ["application/json": MediaType(schema: schema)] }
    }
    struct Response: Encodable, Sendable {
        let description: String
        let content: [String: MediaType]
        init(description: String, schema: JSONSchema) {
            self.description = description
            content = ["application/json": MediaType(schema: schema)]
        }
    }
    struct Operation: Encodable, Sendable {
        let operationId: String
        let summary: String
        let tags: [String]
        let anchor: String?
        let parameters: [Parameter]
        let requestBody: Body?
        let responses: [String: Response]
        enum CodingKeys: String, CodingKey {
            case operationId, summary, tags, parameters, requestBody, responses
            case anchor = "x-doc-anchor"
        }
    }
}
