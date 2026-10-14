# HummingbirdOpenAPI

A code-first OpenAPI prototype for Hummingbird 2 and Swift 6.3. This package has
no dependency on imessage-relay. It stays in this repository while we test its
API against real endpoints.

The same route declarations register HTTP handlers and generate OpenAPI 3.1.
Handlers return typed JSON models, not opaque HTTP responses.

## Models

Use `@OpenAPIModel` on a Codable wire model. A wire model represents the JSON
that crosses HTTP, rather than the application's internal data.

```swift
import HummingbirdOpenAPIModels

@OpenAPIModel
struct MessageInput: Codable, Sendable {
    let text: String
    let clientID: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case clientID = "client_id"
    }
}

@OpenAPIModel
struct MessageOutput: Codable, Sendable {
    let accepted: Bool
}

@OpenAPIModel
struct Failure: Codable, Sendable {
    let message: String
}
```

The macro generates the JSON encoder, decoder, field names, and schema from the
same properties and CodingKeys. It supports strings, booleans, Int, Int64,
Double, optional values, arrays, nested models, and String/Int raw-value enums.
Recursive models use component references. Optional properties accept missing
keys or null and are omitted when encoding nil.

Use `@OpenAPIModel(encodeNil: true)` when optional keys must appear as null.
That mode generates both the required nullable schema and the corresponding
codec. Its decoder requires those keys.

Custom encoders and decoders fail compilation. This also applies to codecs
in another extension because they conflict with the generated methods.
Property wrappers, conditional members, initialized let properties, sparse
CodingKeys, and associated-value enums are unsupported. A nested type without
schema support also fails compilation. Do not add a second list of schema
fields to bypass these checks. Use a supported wire model and map it to the
domain model after decoding.

## Routes

Define routes once in a function that accepts `JSONRoutes`:

```swift
import Hummingbird
import HummingbirdOpenAPI

func register(on routes: JSONRoutes<BasicRequestContext>) {
    routes.post(
        "/messages",
        info: .init(operationID: "sendMessage", summary: "Send a message", tag: "Messages"),
        status: .accepted
    ) { (input: MessageInput, _, _) in
        MessageOutput(accepted: !input.text.isEmpty)
    }
}

let router = Router(context: BasicRequestContext.self)
register(on: JSONRoutes(router: router))

// Record the same declarations without invoking handlers or starting a server.
let recorder = JSONRoutes<BasicRequestContext>()
register(on: recorder)
let document = try recorder.document(
    title: "Messages", version: "1", serverURL: "http://127.0.0.1:8080",
    errorModel: Failure.self
)
let json = try document.json()
```

GET routes have no request body. POST routes decode their declared input before
calling the handler. Unknown JSON fields, including nested fields, throw
`JSONInputError.unknownFields`. The application's middleware must map that
error to an HTTP response. Response status codes come from the same declaration
that sends the live response. Body size limits are enforced before decoding.

The recorder never calls handlers. The relay exporter uses placeholder handlers
with the same types, so it needs no database, native provider, or API token.

## Scope

This is not a complete OpenAPI integration yet. The prototype supports JSON GET
and POST routes and string path captures in `:name` form. Wildcards, duplicate
routes, and duplicate operation IDs fail document generation.

Summaries, tags, documentation anchors, and header descriptions remain route
metadata. Authentication and error handling remain the application's middleware.
The `bearerAuthentication` document option describes that middleware. It does
not install authentication. `errorModel` must be the actual middleware payload.

Query parameters, binary bodies, SSE streams, field descriptions, custom scalar
formats, and business validation are not generated yet. The schema describes
structural JSON types, not destination exclusivity, allowlists, native
permissions, or idempotency rules. Do not publish it as a complete API contract.

## Tests

From the repository root, run:

```sh
just test-openapi
just openapi
just check-openapi
```

The package has its own tests and dependency lockfile. Tests cover model
changes, CodingKeys, enums, optional/null behavior, recursive schemas, rejected
custom codecs, nested unknown fields, live handlers, and deterministic output.
The relay tests compare the new payloads with the existing JSON representations.

The relay pilot covers `GET /v1/status` and `POST /v1/messages`. Its other routes
still use their existing handlers. Expand the pilot only after each route's
wire format passes compatibility tests.
