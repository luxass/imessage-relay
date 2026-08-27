import Hummingbird

struct RedactedRequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        context.logger.info(
            "Request",
            metadata: [
                "hb.request.method": .string(request.method.rawValue),
                "hb.request.path": .string(Self.redactedPath(request.uri.path)),
            ]
        )
        return try await next(request, context)
    }

    private static func redactedPath(_ path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        if components.count >= 2, components[0] == "attachments" {
            components[1] = ":rowid"
        } else if components.count >= 3, components[0] == "chats", components[2] == "messages" {
            components[1] = ":id"
        }
        return "/" + components.joined(separator: "/")
    }
}
