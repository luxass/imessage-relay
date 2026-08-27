import Foundation
import Hummingbird
import RelayCore
import RelaySender

// Hummingbird encodes handler return values through `ResponseEncodable`.
extension Chat: ResponseEncodable {}
extension Message: ResponseEncodable {}
extension MessagesPage: ResponseEncodable {}
extension StatusResponse: ResponseEncodable {}
extension SenderStatus: ResponseEncodable {}
extension SendResult: ResponseEncodable {}

/// Route registry. Each resource lives in its own file and registers itself.
enum API {
    static func register(
        on router: Router<BasicRequestContext>,
        store: StoreProvider,
        sender: any MessageSender,
        policy: SendPolicy,
        token: String?
    ) {
        // When RELAY_TOKEN is set, every route requires the bearer token.
        if let token {
            router.add(middleware: BearerAuthMiddleware(token: token))
        }

        StatusRoutes.register(router, store: store, capabilities: sender.capabilities)
        ChatsRoutes.register(router, store: store)
        MessagesRoutes.register(router, store: store)
        StreamRoutes.register(router, store: store)
        AttachmentsRoutes.register(router, store: store)
        SendRoutes.register(router, store: store, sender: sender, policy: policy)
    }

    /// Maps store failures onto HTTP. A database that cannot be opened is a
    /// setup problem (Full Disk Access, missing path) and gets a distinct
    /// status so clients can tell it apart from query errors.
    static func storeError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as MessageStore.StoreError {
            if case .cannotOpen = error {
                throw HTTPError(.serviceUnavailable, message: error.description)
            }
            throw HTTPError(.internalServerError, message: error.description)
        }
    }
}
