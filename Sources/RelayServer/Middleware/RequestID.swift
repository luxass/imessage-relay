import Hummingbird

struct RequestIDMiddleware: RouterMiddleware {
    func handle(
        _ request: Request,
        context: RelayRequestContext,
        next: (Request, RelayRequestContext) async throws -> Response
    ) async throws -> Response {
        var response = try await next(request, context)
        response.headers[.init("x-request-id")!] = context.requestID.rawValue
        return response
    }
}
