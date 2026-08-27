import Hummingbird

/// GET /chats · GET /chats/:id/messages
enum ChatsRoutes {
    static func register(_ router: Router<BasicRequestContext>, store: StoreProvider) {
        router.get("chats") { request, _ in
            let limit = Int(request.queryInt("limit") ?? 20)
            let unreadOnly = request.queryBool("unread_only") ?? false
            return try API.storeError {
                try store.withStore { try $0.chats(limit: limit, unreadOnly: unreadOnly) }
            }
        }

        router.get("chats/:id/messages") { request, context in
            guard let chatID = context.parameters.get("id", as: Int64.self), chatID > 0 else {
                throw HTTPError(.badRequest, message: "path parameter :id must be a positive integer chat rowid")
            }
            let limit = Int(request.queryInt("limit") ?? 50)
            let before = request.queryInt("before")
            let attachments = request.queryBool("attachments") ?? false
            let reactions = request.queryBool("include_reactions") ?? false
            return try API.storeError {
                try store.withStore {
                    try $0.messages(
                        chatID: chatID,
                        limit: limit,
                        before: before,
                        includeAttachments: attachments,
                        includeReactions: reactions
                    )
                }
            }
        }
    }
}
