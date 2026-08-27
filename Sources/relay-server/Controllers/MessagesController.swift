import Hummingbird
import HummingbirdRouter
import RelayCore

struct MessagesController: RouterController {
    typealias Context = RelayRequestContext

    private struct AfterQuery: Decodable {
        let sinceRowid: Int64?
        let chatID: Int64?
        let limit: Int?
        let attachments: Bool?
        let includeReactions: Bool?

        enum CodingKeys: String, CodingKey {
            case sinceRowid = "since_rowid"
            case chatID = "chat_id"
            case limit, attachments
            case includeReactions = "include_reactions"
        }
    }

    private struct SearchQuery: Decodable {
        let query: String?
        let match: String?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case query = "q"
            case match, limit
        }
    }

    let store: StoreProvider

    var body: some RouterMiddleware<Context> {
        RouteGroup("messages") {
            Get("after", handler: after)
            Get("search", handler: search)
        }
    }

    @Sendable private func after(
        _ request: Request,
        context: Context
    ) throws -> MessagesPage {
        let query = try request.uri.decodeQuery(as: AfterQuery.self, context: context)
        guard let since = query.sinceRowid, since >= 0 else {
            throw HTTPError(
                .badRequest,
                message: "query parameter since_rowid is required and must be a non-negative integer"
            )
        }
        return try withStoreErrorMapping {
            try store.withStore {
                try $0.messagesAfter(
                    sinceRowid: since,
                    chatID: query.chatID,
                    limit: query.limit ?? 100,
                    includeAttachments: query.attachments ?? false,
                    includeReactions: query.includeReactions ?? false
                )
            }
        }
    }

    @Sendable private func search(
        _ request: Request,
        context: Context
    ) throws -> [Message] {
        let parameters = try request.uri.decodeQuery(as: SearchQuery.self, context: context)
        guard let query = parameters.query, !query.isEmpty else {
            throw HTTPError(.badRequest, message: "query parameter q is required")
        }
        return try withStoreErrorMapping {
            try store.withStore {
                try $0.search(
                    query: query,
                    exactMatch: parameters.match == "exact",
                    limit: parameters.limit ?? 50
                )
            }
        }
    }
}
