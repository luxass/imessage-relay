import Foundation
import Hummingbird
import HummingbirdOpenAPI
import HummingbirdOpenAPIModels
import HummingbirdTesting
import Testing

@OpenAPIModel
private struct ValidationPayload: Codable, Sendable { let value: String }

private typealias Routes = JSONRoutes<BasicRequestContext>

private func routeInfo(_ operationID: String, headers: [StringHeader] = []) throws -> JSONRouteInfo {
    try .init(operationID: operationID, summary: "Test", tag: "Test", headers: headers)
}

private func document(_ routes: Routes) throws -> OpenAPIDocument {
    try routes.document(title: "Test", version: "1", serverURL: "http://localhost", errorModel: ValidationPayload.self)
}

@Test(arguments: [false, true])
func equivalentTemplatesFailEvenAcrossDifferentMethods(usePost: Bool) throws {
    let routes = Routes()
    try routes.get("/items/:id", info: try routeInfo("first")) { _, _ in ValidationPayload(value: "first") }
    #expect(throws: Routes.DocumentError.conflictingPathTemplates("/items/{id}", "/items/{name}")) {
        if usePost {
            try routes.post("/items/:name", info: try routeInfo("second")) { (_: ValidationPayload, _, _) in
                ValidationPayload(value: "second")
            }
        } else {
            try routes.get("/items/:name", info: try routeInfo("second")) { _, _ in ValidationPayload(value: "second") }
        }
    }
    _ = try document(routes)
}

@Test(arguments: [
    ("/items", "/items/", "/items"),
    ("//items//", "/items", "/items"),
    ("/", "///", "/"),
])
func normalizedDuplicatePathsFail(first: String, second: String, normalized: String) throws {
    let routes = Routes()
    try routes.get(first, info: try routeInfo("first")) { _, _ in ValidationPayload(value: "first") }
    #expect(throws: Routes.DocumentError.duplicateRoute("get", normalized)) {
        try routes.get(second, info: try routeInfo("second"), use: { _, _ in ValidationPayload(value: "second") })
    }
}

@Test func repeatedPathParametersFail() {
    let routes = Routes()
    #expect(throws: Routes.DocumentError.duplicateParameter("path", "id")) {
        try routes.get("/items/:id/:id", info: try routeInfo("first")) { _, _ in ValidationPayload(value: "first") }
    }
}

@Test(arguments: ["X-Test", "x-test"])
func duplicateHeadersFailCaseInsensitively(secondName: String) {
    let routes = Routes()
    #expect(throws: Routes.DocumentError.duplicateParameter("header", secondName)) {
        try routes.get("/items", info: try routeInfo("first", headers: [
            .init("X-Test", description: "First"), .init(secondName, description: "Second"),
        ])) { _, _ in ValidationPayload(value: "first") }
    }
}

@Test(arguments: ["", "Bad Header", "Bad:Header", "Bad\nHeader"])
func invalidHeaderNamesFail(name: String) {
    let routes = Routes()
    #expect(throws: Routes.DocumentError.invalidHeaderName(name)) {
        try routes.get("/items", info: try routeInfo("first", headers: [.init(name, description: "Invalid")])) { _, _ in
            ValidationPayload(value: "first")
        }
    }
}

@Test func duplicateOperationIDsStillFailForDifferentRoutes() throws {
    let routes = Routes()
    try routes.get("/one", info: try routeInfo("same")) { _, _ in ValidationPayload(value: "first") }
    #expect(throws: Routes.DocumentError.duplicateOperationID("same")) {
        try routes.get("/two", info: try routeInfo("same")) { _, _ in ValidationPayload(value: "second") }
    }
}

@Test func normalizedPathsMatchLiveRoutingAndAllowDifferentMethods() async throws {
    let router = Router(context: BasicRequestContext.self)
    let routes = Routes(router: router)
    try routes.get("//items//:id//", info: try routeInfo("get", headers: [
        .init("X-First", description: "First"), .init("X-Second", description: "Second"),
    ])) { _, _ in ValidationPayload(value: "get") }
    try routes.post("/items/:id", info: try routeInfo("post")) { (input: ValidationPayload, _, _) in input }
    let json = try #require(JSONSerialization.jsonObject(with: document(routes).json()) as? [String: Any])
    let paths = try #require(json["paths"] as? [String: Any])
    #expect(Set(paths.keys) == ["/items/{id}"])
    let path = try #require(paths["/items/{id}"] as? [String: Any])
    #expect(Set(path.keys) == ["get", "post"])
    let get = try #require(path["get"] as? [String: Any])
    let parameters = try #require(get["parameters"] as? [[String: Any]])
    #expect(parameters.compactMap { $0["name"] as? String } == ["id", "X-First", "X-Second"])
    #expect(parameters.compactMap { $0["in"] as? String } == ["path", "header", "header"])
    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/items/one", method: .get)
        #expect(response.status == .ok)
        let payload = try JSONDecoder().decode(ValidationPayload.self, from: Data(response.body.readableBytesView))
        #expect(payload.value == "get")
    }
}

@Test func requiredHeadersAppearAsRequiredInTheDocument() throws {
    let routes = Routes()
    try routes.get("/items", info: try routeInfo("first", headers: [
        .init("X-Optional", description: "Optional"),
        .init("X-Mandatory", description: "Mandatory", required: true),
    ])) { _, _ in ValidationPayload(value: "first") }
    let json = try #require(JSONSerialization.jsonObject(with: document(routes).json()) as? [String: Any])
    let operation = try #require((json["paths"] as? [String: Any])?["/items"] as? [String: Any])
    let get = try #require(operation["get"] as? [String: Any])
    let parameters = try #require(get["parameters"] as? [[String: Any]])
    let byName = [String: [String: Any]](
        uniqueKeysWithValues: parameters.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return (name, $0.mapValues { $0 as Any })
        }
    )
    #expect((byName["X-Optional"]?["required"] as? Bool) == false)
    #expect((byName["X-Mandatory"]?["required"] as? Bool) == true)
}
