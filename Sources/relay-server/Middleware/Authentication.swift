import Hummingbird
import RelayCore

struct AuthenticationMiddleware: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: RelayRequestContext,
        next: (Request, RelayRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let authorization = request.headers[.authorization],
              Self.constantTimeEquals(authorization, "Bearer \(token)") else {
            throw APIHTTPError(
                status: .unauthorized,
                code: .invalidAuthentication,
                message: "Provide a valid bearer token."
            )
        }
        return try await next(request, context)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference: UInt8 = left.count == right.count ? 0 : 1
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0)
                ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}
