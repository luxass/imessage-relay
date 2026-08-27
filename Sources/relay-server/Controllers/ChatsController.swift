import Hummingbird
import HummingbirdRouter
import RelayCore

struct ChatsController: RouterController {
    typealias Context = RelayRequestContext

    private struct ListQuery: Decodable {
        let limit: Int?
        let unreadOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case limit
            case unreadOnly = "unread_only"
        }
    }

    private struct MessagesQuery: Decodable {
        let limit: Int?
        let before: Int64?
        let attachments: Bool?
        let includeReactions: Bool?

        enum CodingKeys: String, CodingKey {
            case limit, before, attachments
            case includeReactions = "include_reactions"
        }
    }

    let store: StoreProvider

    var body: some RouterMiddleware<Context> {
        RouteGroup("chats") {
            Get(handler: list)
            Get(":id/messages", handler: messages)
        }
    }

    @Sendable private func list(
        _ request: Request,
        context: Context
    ) throws -> [Chat] {
        let query = try request.uri.decodeQuery(as: ListQuery.self, context: context)
        return try withStoreErrorMapping {
            try store.withStore {
                try $0.chats(limit: query.limit ?? 20, unreadOnly: query.unreadOnly ?? false)
            }
        }
    }

    @Sendable private func messages(
        _ request: Request,
        context: Context
    ) throws -> [Message] {
        guard let chatID = context.parameters.get("id", as: Int64.self), chatID > 0 else {
            throw HTTPError(.badRequest, message: "path parameter :id must be a positive integer chat rowid")
        }
        let query = try request.uri.decodeQuery(as: MessagesQuery.self, context: context)
        return try withStoreErrorMapping {
            try store.withStore {
                try $0.messages(
                    chatID: chatID,
                    limit: query.limit ?? 50,
                    before: query.before,
                    includeAttachments: query.attachments ?? false,
                    includeReactions: query.includeReactions ?? false
                )
            }
        }
    }
}
