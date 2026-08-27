import Hummingbird
import NIOCore

/// GET /messages/stream — Server-Sent Events feed of newly-arrived messages.
///
/// Reuses the same catch-up path behind `/messages/after`: an internal poll
/// loop (~1s cadence) advances a local ROWID cursor through
/// `MessageStore.messagesAfter` and emits each new message as an SSE event.
///
/// Disconnect handling needs no bookkeeping: the loop runs inside the
/// response body's write task, so a closed channel throws out of
/// `writer.write` (or cancels `Task.sleep`) and unwinds the whole stream.
enum StreamRoutes {
    private static let pollInterval: Duration = .seconds(1)
    /// Silence window after which a keepalive comment is emitted so proxies
    /// don't drop the connection.
    private static let keepaliveInterval: Duration = .seconds(15)

    static func register(_ router: Router<BasicRequestContext>, store: StoreProvider) {
        router.get("messages/stream") { request, context -> Response in
            let chatID = request.queryInt("chat_id")
            let reactions = request.queryBool("include_reactions") ?? false

            // Default cursor: current MAX(message.ROWID), i.e. only messages
            // arriving after this connect are streamed.
            let start: Int64 = try API.storeError {
                try request.queryInt("since_rowid") ?? store.withStore { try $0.maxRowid() }
            }

            let logger = context.logger
            let body = ResponseBody { writer in
                var cursor = start
                var lastEmit = ContinuousClock.now

                try await writer.write(ByteBuffer(string: SSE.ready(nextRowid: cursor)))

                while true {
                    do {
                        let page = try API.storeError {
                            try store.withStore {
                                try $0.messagesAfter(
                                    sinceRowid: cursor,
                                    chatID: chatID,
                                    includeReactions: reactions
                                )
                            }
                        }

                        for message in page.messages {
                            try await writer.write(ByteBuffer(string: try SSE.message(message)))
                        }

                        cursor = SSE.advance(cursor, pageNextRowid: page.nextRowid)
                        if !page.messages.isEmpty {
                            lastEmit = ContinuousClock.now
                        }

                        // A full page means more may be waiting; drain again
                        // immediately instead of waiting out the interval.
                        if page.hasMore { continue }
                    } catch {
                        // Keep the stream alive across transient database
                        // failures; StoreProvider recovers on its own (e.g.
                        // Full Disk Access granted mid-flight). Clients keep
                        // their cursor either way.
                        logger.error("messages/stream poll failed: \(error)")
                    }

                    if ContinuousClock.now - lastEmit >= keepaliveInterval {
                        try await writer.write(ByteBuffer(string: SSE.keepalive))
                        lastEmit = ContinuousClock.now
                    }
                    try await Task.sleep(for: pollInterval)
                }
            }

            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/event-stream",
                    .cacheControl: "no-cache",
                ],
                body: body
            )
        }
    }
}
