import Foundation
import HummingbirdOpenAPI
import OpenAPIKit

enum RelayAPIDocument {
    static var endpoints: [EndpointDefinition] {
        [StatusRoutes.endpoint.definition, SenderRoutes.endpoint.definition]
            + ConversationRoutes.endpoints + MessageRoutes.endpoints + MediaRoutes.endpoints
            + [EventRoutes.endpoint.definition]
    }

    static func builder() -> OpenAPIDocumentBuilder {
        let builder = OpenAPIDocumentBuilder(
            title: "iMessage Relay", apiVersion: packageVersion,
            servers: [.init(url: URL(string: "http://127.0.0.1:8080")!)]
        )
        builder.requireHTTPBearerAuthentication(named: "relayToken")
        for endpoint in endpoints { builder.add(endpoint) }
        return builder
    }
}

/// Generate the complete API description without creating runtime resources or reading environment configuration.
public func relayOpenAPIDocumentData() throws -> Data {
    try RelayAPIDocument.builder().encodedJSON()
}
