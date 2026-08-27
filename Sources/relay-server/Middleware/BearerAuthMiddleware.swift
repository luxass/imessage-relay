import Foundation
import Hummingbird

/// Requires `Authorization: Bearer <token>` on every request. Installed only
/// when RELAY_TOKEN is configured; otherwise the loopback binding is the only
/// gate.
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    private let token: String

    init(token: String) {
        self.token = token
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let presented = request.headers[.authorization]
        guard let presented, Self.constantTimeEquals(presented, "Bearer \(token)") else {
            throw HTTPError(.unauthorized, message: "missing or invalid bearer token")
        }
        return try await next(request, context)
    }

    /// Compare all bytes regardless of early mismatches so response timing
    /// does not leak how much of the token was correct.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for index in 0..<max(a.count, b.count) {
            let leftByte = index < a.count ? a[index] : 0
            let rightByte = index < b.count ? b[index] : 0
            diff |= leftByte ^ rightByte
        }
        return diff == 0
    }
}
