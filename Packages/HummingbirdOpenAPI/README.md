# HummingbirdOpenAPI

Code-first OpenAPI generation for Hummingbird 2. Models describe their JSON fields once. Endpoint values supply both route registration and OpenAPI operations.

The package has no application-specific dependency. Typed and raw endpoints cover JSON, binary bodies, and server-sent events.
The package targets Swift 6.3 or newer. Its implementation uses portable Swift APIs rather than macOS services.

## Model declaration

```swift
import HummingbirdOpenAPIModels

@OpenAPISchema
struct Greeting: Codable, Sendable {
    let message: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case displayName = "display_name"
    }
}
```

The macro adds `OpenAPISchemaProviding` conformance. It does not generate or replace JSON codecs. It reads stored properties and `CodingKeys` rather than a second field list.

Request and response schemas are separate. A synthesized optional property accepts absence or null in a request. A nil optional property is omitted from the encoded response. An optional value inside an array can still be null.

Supported models include String/Int raw-value enums, structs, generic structs, String, Bool, Int, Int64, Double, arrays, string-keyed dictionaries, and optionals.
Recursive models use references. Generic specializations have separate stable component names.
The registry rejects name collisions and rolls back failed expansions. Use `@OpenAPISchema(name: "UniqueName")` to select a name.

Automatic derivation rejects custom codecs unless the author selects `customCoding: .explicitPropertyRules`. This selection asserts that property types and CodingKeys describe the custom wire shape. It does not inspect arbitrary codec bodies or infer business validation.

Use a manual provider for a different wire shape. For example, Relay's `Timestamp` stores a Date but encodes an ISO 8601 string:

```swift
extension Timestamp: OpenAPISchemaProviding {
    public static func openAPISchema(
        in context: SchemaContext,
        direction: SchemaDirection
    ) -> SchemaValue {
        .string(format: .dateTime)
    }
}
```

Custom keyed codecs can annotate exceptional fields with schema-only markers:

```swift
@OpenAPIProperty(response: .requiredNullable)
let text: String?

@OpenAPIProperty(request: .optionalNullable)
let enabled: Bool
```

The second rule describes a custom decoder that accepts missing or null input and supplies a default.
Markers do not add runtime property wrappers or change Codable. Available rules are `inferred`, `required`, `requiredNullable`, `omittedWhenNil`, and `optionalNullable`.

Conditional fields, initialized immutable properties, arbitrary property wrappers, flattened requests, and associated-value enums need explicit providers.
Codec implementations in other extensions or files are not visible to the macro. Their authors must select an explicit strategy and test the wire format.
The macro cannot infer custom JSONEncoder key, date, or data strategies. It does not derive schemas for Date or Data without an explicit provider.

## Endpoint and document

```swift
let greeting = JSONEndpoint<Greeting>(
    method: .get,
    path: "/greeting",
    operationID: "getGreeting",
    summary: "Read a greeting.",
    responses: [.success(.ok, description: "A greeting.")]
)

let builder = OpenAPIDocumentBuilder(title: "Example", apiVersion: "1.0")
builder.add(greeting)
let json = try builder.encodedJSON()
```

Live registration uses `greeting.register(on: router, use: handler)`. The handler must return `JSONResponse<Greeting>`. The response wrapper takes an application-supplied renderer. Use a renderer to retain application codecs, response headers, and request identifiers.

The document builder emits OpenAPI 3.2.1 through OpenAPIKit. It rejects duplicate operations, duplicate response codes, incomplete definitions, and unsupported paths. OpenAPIKit checks document structure and references. It does not validate arbitrary JSON instances against Draft 2020-12.

Endpoint definitions support path, query, header, and cookie parameters, typed JSON request bodies, multiple response statuses, headers, tags, and examples.
Use `:parameter` for a Hummingbird capture. Every capture needs matching path parameter metadata.
The exporter writes `{parameter}` and rejects missing parameters, partial captures, wildcards, and conflicting templates.
Use `endpoint.prefixed(by: "/api")` for a shared prefix in both live registration and export.

`EndpointBody.binary` describes raw media without a JSON string schema.
`RawEndpoint` accepts an `EndpointDefinition` for handlers with binary, streaming, or mixed response variants.
These handlers retain Hummingbird Response bodies and are not buffered by the package.

SSE media uses OpenAPI 3.2 `itemSchema` to describe parsed frames.
Use `context.encodedJSONString(for: Payload.self, direction: .response)` for a JSON-encoded data string.
OpenAPIKit 7 does not model `contentSchema` natively. The intermediate kit document uses a private marker.
The canonical `encodedJSON()` method writes the standard keyword and makes sure that its references resolve.
Use this method for exchange, not a direct JSONEncoder call on `buildValidated()` when encoded JSON strings are present.
The adapter does not modify examples or defaults.

OpenAPI 3.2 support varies between downstream tools. No 3.1 compatibility output is provided.
The package generates documentation, not runtime request validation or client/server code.

## Tests

Run the standalone package tests from the repository root:

```sh
swift test --package-path Packages/HummingbirdOpenAPI
```

Tests cover macro expansions and diagnostics, property presence and nulls, generic models, recursive references, registration, media, and SSE.
