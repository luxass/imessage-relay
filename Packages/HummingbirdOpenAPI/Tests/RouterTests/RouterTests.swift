import Foundation
import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import HummingbirdTesting
import NIOCore
import Testing

@OpenAPIModel
private struct Input: Codable, Sendable {
    let text: String
    let metadata: Metadata?
}
@OpenAPIModel
private struct Metadata: Codable, Sendable { let label: String }
@OpenAPIModel
private struct Output: Codable, Sendable { let echo: String }
@OpenAPIModel
private struct Failure: Codable, Sendable { let message: String }

private struct Errors: RouterMiddleware {
    typealias Context = BasicRequestContext
    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do { return try await next(request, context) }
        catch is JSONInputError { return Response(status: .unprocessableContent) }
        catch is DecodingError { return Response(status: .badRequest) }
    }
}

private func configure(_ routes: JSONRoutes<BasicRequestContext>) throws {
    try routes.get("/health", info: try .init(operationID: "health", summary: "Health", tag: "Status")) { _, _ in
        Output(echo: "healthy")
    }
    try routes.post(
        "/echo/:id", info: try .init(operationID: "echo", summary: "Echo", tag: "Messages"), status: .accepted
    ) { (input: Input, _, _) in
        Output(echo: input.text)
    }
}

@Test func sameDeclarationsGenerateTheDocumentAndRegisterWorkingHandlers() async throws {
    let router = Router(context: BasicRequestContext.self)
    router.middlewares.add(Errors())
    let live = JSONRoutes(router: router)
    try configure(live)
    let recorder = JSONRoutes<BasicRequestContext>()
    try configure(recorder)
    let liveDocument = try live.document(title: "Test", version: "1", serverURL: "http://localhost", errorModel: Failure.self)
    let recordedDocument = try recorder.document(title: "Test", version: "1", serverURL: "http://localhost", errorModel: Failure.self)
    #expect(try liveDocument.json() == recordedDocument.json())
    let json = try #require(JSONSerialization.jsonObject(with: liveDocument.json()) as? [String: Any])
    let paths = try #require(json["paths"] as? [String: Any])
    #expect(Set(paths.keys) == Set(["/health", "/echo/{id}"]))
    let post = try #require((paths["/echo/{id}"] as? [String: Any])?["post"] as? [String: Any])
    #expect((post["responses"] as? [String: Any])?["202"] != nil)
    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/echo/one", method: .post, body: ByteBuffer(string: #"{"text":"hello"}"#))
        #expect(response.status == .accepted)
        #expect(try JSONDecoder().decode(Output.self, from: Data(response.body.readableBytesView)).echo == "hello")
        let malformed = try await client.execute(uri: "/echo/one", method: .post, body: ByteBuffer(string: "{"))
        #expect(malformed.status == .badRequest)
        let unknown = try await client.execute(uri: "/echo/one", method: .post, body: ByteBuffer(string: #"{"text":"hi","typo":true}"#))
        #expect(unknown.status == .unprocessableContent)
        let nested = try await client.execute(
            uri: "/echo/one", method: .post,
            body: ByteBuffer(string: #"{"text":"hi","metadata":{"label":"x","typo":true}}"#)
        )
        #expect(nested.status == .unprocessableContent)
    }
}

@Test func duplicateAndUnsupportedRoutesFailDocumentGeneration() throws {
    let duplicate = JSONRoutes<BasicRequestContext>()
    try configure(duplicate)
    #expect(throws: JSONRoutes<BasicRequestContext>.DocumentError.self) {
        try configure(duplicate)
    }
    _ = try? duplicate.document(title: "Test", version: "1", serverURL: "http://localhost", errorModel: Failure.self)
    let wildcard = JSONRoutes<BasicRequestContext>()
    #expect(throws: JSONRoutes<BasicRequestContext>.DocumentError.self) {
        try wildcard.get("/*", info: try .init(operationID: "wildcard", summary: "Wildcard", tag: "Test")) { _, _ in Output(echo: "") }
    }
}
