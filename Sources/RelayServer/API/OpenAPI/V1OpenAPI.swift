import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import OpenAPIKit
import RelayCore

enum V1OpenAPI {
    static let responseHeaders: OpenAPI.Header.Map = [
        "X-Request-ID": .b(.init(schema: .string, description: "Request correlation identifier.", required: true)),
    ]

    static func responses<Output>(
        success: HTTPResponse.Status = .ok, description: String, errors: [HTTPResponse.Status] = []
    ) -> [JSONEndpoint<Output>.ResponseDefinition] {
        [.success(success, description: description)] + errorStatuses(errors).map {
            .error($0, body: APIError.self, description: errorDescription($0))
        }
    }

    static func rawErrors(_ errors: [HTTPResponse.Status]) -> [EndpointResponse] {
        errorStatuses(errors).map { .json($0, body: APIError.self, description: errorDescription($0)) }
    }

    static func identifier<Value: RelayIdentifier>(_ name: String, type: Value.Type) -> EndpointParameter {
        .init(name: name, location: .path, description: "Percent-encoded public resource identifier, not a database row ID.", type: type)
    }

    static func limit(default value: Int) -> EndpointParameter {
        .init(name: "limit", location: .query, description: "Maximum number of items in this page.",
              schema: .integer(
                maximum: (V1Query.limitRange.upperBound, exclusive: false),
                minimum: (V1Query.limitRange.lowerBound, exclusive: false),
                defaultValue: AnyCodable(value)
              ))
    }

    static func messageOptions(requiresSearch: Bool = false) -> [EndpointParameter] {
        [
            limit(default: ConversationRoutes.messagePageLimit), cursor,
            boolean("include_attachments", description: "Include attachment metadata in messages and attachment parts."),
            .init(name: "q", location: .query,
                  description: "Case- and diacritic-insensitive search of current decoded message text.",
                  required: requiresSearch, schema: .string(minLength: requiresSearch ? 1 : nil)),
            .init(name: "search_mode", location: .query, description: "Text search matching mode.",
                  schema: .string(
                    allowedValues: MessageSearchMode.allCases.map { AnyCodable($0.rawValue) },
                    defaultValue: AnyCodable(MessageSearchMode.contains.rawValue)
                  )),
        ]
    }

    static let cursor = EndpointParameter(
        name: "cursor", location: .query,
        description: "Opaque next_cursor from the previous page, bound to the route, query, and database.", type: Cursor.self
    )

    static func boolean(_ name: String, description: String) -> EndpointParameter {
        .init(name: name, location: .query,
              description: description + " Accepts true, false, 1, or 0. Word spellings are case-insensitive.",
              schema: .string(pattern: #"^([Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[01])$"#, defaultValue: "false"))
    }

    private static func errorStatuses(_ statuses: [HTTPResponse.Status]) -> [HTTPResponse.Status] {
        var seen: Set<Int> = []
        return ([.unauthorized] + statuses + [.internalServerError]).filter { seen.insert($0.code).inserted }
    }

    private static func errorDescription(_ status: HTTPResponse.Status) -> String {
        switch status.code {
        case 400: "Malformed JSON, query parameter, cursor, destination selection, or resource identifier."
        case 401: "Missing or invalid bearer token."
        case 403: "One or more destination recipients are not allowlisted."
        case 404: "The requested resource was not found."
        case 409: "A conflicting request, ambiguous conversation, or protected typing draft prevents the operation."
        case 413: "The request body or media exceeds its configured size limit."
        case 422: "A destination, payload field, filename, or media file failed validation."
        case 501: "The sender or platform does not support the requested capability."
        case 502: "The native operation result is uncertain. Refetch its resource before retrying."
        case 503: "The database, sender, Messages access, or request store is unavailable."
        default: "The request failed."
        }
    }
}
