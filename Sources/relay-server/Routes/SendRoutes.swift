import Foundation
import Hummingbird
import RelayCore
import RelaySender

struct SendRequestBody: Decodable {
    var chatID: Int64?
    var to: String?
    var text: String?
    var file: String?
    var service: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case to, text, file, service
    }
}

/// POST /send — dispatches through the configured `MessageSender`.
enum SendRoutes {
    /// 1 MiB is plenty for a JSON send payload.
    private static let maxBodyBytes = 1024 * 1024

    static func register(
        _ router: Router<BasicRequestContext>,
        store: StoreProvider,
        sender: any MessageSender,
        policy: SendPolicy
    ) {
        router.post("send") { request, _ in
            try await send(request, store: store, sender: sender, policy: policy)
        }
    }

    private static func send(
        _ request: Request,
        store: StoreProvider,
        sender: any MessageSender,
        policy: SendPolicy
    ) async throws -> SendResult {
        var request = request
        let buffer = try await request.collectBody(upTo: maxBodyBytes)
        guard let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes), !data.isEmpty else {
            throw HTTPError(.badRequest, message: "request body must be JSON")
        }
        var payload: SendRequestBody
        do {
            payload = try JSONDecoder().decode(SendRequestBody.self, from: data)
        } catch {
            throw HTTPError(.badRequest, message: "invalid JSON body: \(error.localizedDescription)")
        }
        if payload.chatID == nil && (payload.to == nil || payload.to!.isEmpty) {
            throw HTTPError(.badRequest, message: "provide exactly one of chat_id or to")
        }
        if payload.text == nil && payload.file == nil {
            throw HTTPError(.badRequest, message: "provide text or file")
        }

        // Resolve the destination into every address it would reach.
        var recipients: [String]
        var chatGuid: String?
        if let chatID = payload.chatID {
            let targets = try API.storeError { try store.withStore { try $0.sendTargets(chatID: chatID) } }
            guard !targets.isEmpty else {
                throw HTTPError(.notFound, message: "no chat with id \(chatID)")
            }
            recipients = targets
            chatGuid = targets.first
        } else {
            recipients = [payload.to!]
        }

        // Deny-by-default: without an allowlist nothing is ever sent.
        guard policy.allows(recipients: recipients) else {
            throw HTTPError(.forbidden, message: """
                recipient not allowed by RELAY_ALLOWED_RECIPIENTS. Configure the \
                allowlist (e.g. RELAY_ALLOWED_RECIPIENTS='+4512345678') to enable sending.
                """)
        }

        let sendRequest = SendRequest(
            chatID: payload.chatID,
            chatGuid: chatGuid,
            to: payload.to,
            text: payload.text,
            file: payload.file,
            service: payload.service
        )
        do {
            return try await sender.send(sendRequest)
        } catch SenderError.unavailable(let detail) {
            throw HTTPError(.notImplemented, message: detail)
        } catch SenderError.notStarted(let detail) {
            // Transport proved dispatch never happened; retrying is safe.
            throw HTTPError(.badGateway, message: "Send was never started (retry safe). \(detail)")
        } catch let error as SenderError {
            throw HTTPError(.internalServerError, message: String(describing: error))
        }
    }
}
