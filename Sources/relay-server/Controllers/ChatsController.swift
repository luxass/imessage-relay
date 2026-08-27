import Hummingbird
import HummingbirdRouter
import RelayCore

private struct ChatListQuery: Decodable {
    let limit: Int?
    let unreadOnly: Bool?
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case limit, cursor
        case unreadOnly = "unread_only"
    }
}

private struct ChatMessagesQuery: Decodable {
    let limit: Int?
    let cursor: String?
    let attachments: Bool?
    let includeReactions: Bool?
    let query: String?
    let match: String?

    enum CodingKeys: String, CodingKey {
        case limit, cursor, attachments, match
        case query = "q"
        case includeReactions = "include_reactions"
    }
}

struct ChatsController: RouterController {
    typealias Context = RelayRequestContext

    let store: MessageStore

    var body: some RouterMiddleware<Context> {
        RouteGroup("chats") {
            Get(handler: list)
            Get(":id", handler: detail)
            Get(":id/messages", handler: messages)
        }
    }

    @Sendable private func detail(
        _ request: Request,
        context: Context
    ) async throws -> Chat {
        let chatID = try chatID(from: context)
        return try await withStoreErrorMapping(logger: context.logger) {
            guard let chat = try await store.chat(id: chatID) else {
                throw HTTPError(.notFound, message: "chat not found")
            }
            return chat
        }
    }

    @Sendable private func list(
        _ request: Request,
        context: Context
    ) async throws -> Page<Chat> {
        let query = try request.uri.decodeQuery(as: ChatListQuery.self, context: context)
        return try await withStoreErrorMapping(logger: context.logger) {
            try await store.chats(
                limit: query.limit ?? 20,
                unreadOnly: query.unreadOnly ?? false,
                cursor: query.cursor
            )
        }
    }

    @Sendable private func messages(
        _ request: Request,
        context: Context
    ) async throws -> Page<Message> {
        let chatID = try chatID(from: context)
        let query = try request.uri.decodeQuery(as: ChatMessagesQuery.self, context: context)
        return try await withStoreErrorMapping(logger: context.logger) {
            guard try await store.chat(id: chatID) != nil else {
                throw HTTPError(.notFound, message: "chat not found")
            }
            return try await store.messages(
                chatID: chatID,
                limit: query.limit ?? 50,
                cursor: query.cursor,
                includeAttachments: query.attachments ?? false,
                includeReactions: query.includeReactions ?? false,
                query: query.query,
                exactMatch: query.match == "exact"
            )
        }
    }

    private func chatID(from context: Context) throws -> Int64 {
        guard let chatID = context.parameters.get("id", as: Int64.self), chatID > 0 else {
            throw HTTPError(.badRequest, message: "path parameter :id must be a positive integer chat rowid")
        }
        return chatID
    }
}
