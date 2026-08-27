import Hummingbird
import Logging
import RelayCore

func withStoreErrorMapping<T>(
    logger: Logger,
    _ body: () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let error as MessageStore.StoreError {
        if case .invalidCursor = error {
            throw HTTPError(.badRequest, message: "invalid or expired page cursor")
        }
        logger.error("Messages database operation failed", metadata: ["error": "\(error)"])
        if case .cannotOpen = error {
            throw HTTPError(.serviceUnavailable, message: "Messages database unavailable")
        }
        throw HTTPError(.internalServerError, message: "Messages database request failed")
    }
}
