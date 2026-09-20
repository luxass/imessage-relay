import Hummingbird
import RelayCore

struct SenderRoutes {
    let sender: any MessageSender

    func register(on router: Router<RelayRequestContext>) {
        router.get("/v1/sender", use: get)
    }

    @Sendable private func get(_ request: Request, context: RelayRequestContext) async throws -> Response {
        try jsonResponse(await sender.status(), requestID: context.requestID)
    }
}
