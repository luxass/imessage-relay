import Hummingbird
import HummingbirdOpenAPI
import HummingbirdTesting
import Testing

@Test
func rendererStatusMismatchThrowsTheExpectedError() async throws {
    let response = mismatchedRendererResponse()

    try await expectResponderError(.rendererStatusMismatch) { request, context in
        try response.response(from: request, context: context)
    }
}

@Test
func rendererStatusMismatchProducesAnInternalServerError() async throws {
    let router = Router()
    router.get("/hello") { _, _ in mismatchedRendererResponse() }

    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/hello", method: .get)
        #expect(response.status == .internalServerError)
    }
}

@Test
func undeclaredJSONStatusThrowsTheExpectedError() async throws {
    let responder = routerWithUndeclaredJSONStatus().buildResponder()

    try await expectResponderError(.undeclaredResponseStatus(201)) { request, context in
        try await responder.respond(to: request, context: context)
    }
}

@Test
func undeclaredJSONStatusProducesAnInternalServerError() async throws {
    let router = routerWithUndeclaredJSONStatus()

    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/hello", method: .get)
        #expect(response.status == .internalServerError)
    }
}

@Test
func undeclaredRawStatusThrowsTheExpectedError() async throws {
    let responder = routerWithUndeclaredRawStatus().buildResponder()

    try await expectResponderError(.undeclaredResponseStatus(201)) { request, context in
        try await responder.respond(to: request, context: context)
    }
}

@Test
func undeclaredRawStatusProducesAnInternalServerError() async throws {
    let router = routerWithUndeclaredRawStatus()

    try await Application(router: router).test(.router) { client in
        let response = try await client.execute(uri: "/hello", method: .get)
        #expect(response.status == .internalServerError)
    }
}

private func mismatchedRendererResponse() -> JSONResponse<Hello> {
    JSONResponse(Hello(message: "Hello"), status: .ok) { _, _ in
        Response(status: .created)
    }
}

private func routerWithUndeclaredJSONStatus() -> Router<BasicRequestContext> {
    let router = Router()
    greetingEndpoint().register(on: router) { _, _ in
        JSONResponse(Hello(message: "Hello"), status: .created) { _, status in
            Response(status: status)
        }
    }
    return router
}

private func routerWithUndeclaredRawStatus() -> Router<BasicRequestContext> {
    let router = Router()
    RawEndpoint(greetingEndpoint().definition).register(on: router) { _, _ in
        Response(status: .created)
    }
    return router
}

/// Use the framework's request/context fixture, but check the error before its client maps it to HTTP 500.
private func expectResponderError(
    _ expected: EndpointError,
    operation: @escaping @Sendable (Request, BasicRequestContext) async throws -> Response
) async throws {
    let harness = Router()
    harness.get("/hello") { request, context -> Response in
        await #expect(throws: expected) {
            try await operation(request, context)
        }
        return Response(status: .noContent)
    }

    try await Application(router: harness).test(.router) { client in
        let response = try await client.execute(uri: "/hello", method: .get)
        #expect(response.status == .noContent)
    }
}
