import Hummingbird
import HummingbirdRouter
import RelayCore

struct SendRequestBody: Decodable {
    let chatID: Int64?
    let to: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case to, text
    }

    enum BodyError: Error {
        case unsupportedFields([String])
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unsupported = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unsupported.isEmpty else {
            throw BodyError.unsupportedFields(unsupported)
        }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try values.decodeIfPresent(Int64.self, forKey: .chatID)
        to = try values.decodeIfPresent(String.self, forKey: .to)
        text = try values.decodeIfPresent(String.self, forKey: .text)
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

extension SendRequestBody.CodingKeys: CaseIterable {}

struct SendController: RouterController {
    typealias Context = RelayRequestContext

    let store: MessageStore
    let sender: any MessageSending
    let config: ServerConfig

    var body: some RouterMiddleware<Context> {
        Post("send", handler: send)
    }

    @Sendable private func send(
        _ request: Request,
        context: Context
    ) async throws -> SendResult {
        let payload: SendRequestBody
        do {
            payload = try await request.decode(as: SendRequestBody.self, context: context)
        } catch SendRequestBody.BodyError.unsupportedFields(let fields) {
            let label = fields.count == 1 ? "field" : "fields"
            throw HTTPError(.badRequest, message: "unsupported \(label): \(fields.joined(separator: ", "))")
        }
        let targetCount = (payload.chatID == nil ? 0 : 1) + (payload.to == nil ? 0 : 1)
        if targetCount != 1 || payload.to?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            throw HTTPError(.badRequest, message: "provide exactly one of chat_id or to")
        }
        guard let text = payload.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError(.badRequest, message: "provide non-empty text")
        }

        let recipients: [String]
        let chatGuid: String?
        if let chatID = payload.chatID {
            let target = try await withStoreErrorMapping(logger: context.logger) {
                try await store.sendTarget(chatID: chatID)
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
            text: text
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
