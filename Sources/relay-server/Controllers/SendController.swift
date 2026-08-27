import Hummingbird
import HummingbirdRouter
import RelayCore

struct SendRequestBody: Decodable {
    let chatID: Int64?
    let to: String?
    let text: String?
    let file: String?
    let service: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case to, text, file, service
    }
}

struct SendController: RouterController {
    typealias Context = RelayRequestContext

    let store: StoreProvider
    let sender: MessageSender
    let config: ServerConfig

    var body: some RouterMiddleware<Context> {
        Post("send", handler: send)
    }

    @Sendable private func send(
        _ request: Request,
        context: Context
    ) async throws -> SendResult {
        let payload = try await request.decode(as: SendRequestBody.self, context: context)
        let targetCount = (payload.chatID == nil ? 0 : 1) + (payload.to == nil ? 0 : 1)
        if targetCount != 1 || payload.to?.isEmpty == true {
            throw HTTPError(.badRequest, message: "provide exactly one of chat_id or to")
        }
        if payload.text == nil && payload.file == nil {
            throw HTTPError(.badRequest, message: "provide text or file")
        }

        let recipients: [String]
        let chatGuid: String?
        if let chatID = payload.chatID {
            let target = try withStoreErrorMapping {
                try store.withStore { try $0.sendTarget(chatID: chatID) }
            }
            guard let target else {
                throw HTTPError(.notFound, message: "no chat with id \(chatID)")
            }
            recipients = target.recipients
            chatGuid = target.chatGuid
        } else {
            recipients = [payload.to!]
            chatGuid = nil
        }

        guard config.allowsAll(recipients: recipients) else {
            throw HTTPError(.forbidden, message: """
                recipient not allowed by RELAY_ALLOWED_RECIPIENTS. Configure the \
                allowlist to enable sending.
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
            throw HTTPError(.badGateway, message: "Send was never started (retry safe). \(detail)")
        } catch let error as SenderError {
            throw HTTPError(.internalServerError, message: String(describing: error))
        }
    }
}
