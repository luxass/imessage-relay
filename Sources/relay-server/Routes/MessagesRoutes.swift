import Hummingbird

/// GET /messages/after · GET /messages/search
enum MessagesRoutes {
    static func register(_ router: Router<BasicRequestContext>, store: StoreProvider) {
        router.get("messages/after") { request, _ in
            guard let since = request.queryInt("since_rowid"), since >= 0 else {
                throw HTTPError(.badRequest, message: "query parameter since_rowid is required and must be a non-negative integer")
            }
            let chatID = request.queryInt("chat_id")
            let limit = Int(request.queryInt("limit") ?? 100)
            let attachments = request.queryBool("attachments") ?? false
            let reactions = request.queryBool("include_reactions") ?? false
            return try API.storeError {
                try store.withStore {
                    try $0.messagesAfter(
                        sinceRowid: since,
                        chatID: chatID,
                        limit: limit,
                        includeAttachments: attachments,
                        includeReactions: reactions
                    )
                }
            }
        }

        router.get("messages/search") { request, _ in
            guard let query = request.queryString("q"), !query.isEmpty else {
                throw HTTPError(.badRequest, message: "query parameter q is required")
            }
            let exactMatch = (request.queryString("match") == "exact")
            let limit = Int(request.queryInt("limit") ?? 50)
            return try API.storeError {
                try store.withStore { try $0.search(query: query, exactMatch: exactMatch, limit: limit) }
            }
        }
    }
}
