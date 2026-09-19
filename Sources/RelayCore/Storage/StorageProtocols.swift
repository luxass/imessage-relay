import Darwin
import Foundation

public enum MessageSearchMode: String, Codable, Equatable, Sendable {
    case contains
    case exact
}

public struct ConversationListOptions: Equatable, Sendable {
    public let limit: Int
    public let cursor: Cursor?
    public let unreadOnly: Bool
    public let participant: RecipientHandle?

    public init(
        limit: Int = 20,
        cursor: Cursor? = nil,
        unreadOnly: Bool = false,
        participant: RecipientHandle? = nil
    ) {
        self.limit = limit
        self.cursor = cursor
        self.unreadOnly = unreadOnly
        self.participant = participant
    }
}

public struct MessageListOptions: Equatable, Sendable {
    public let limit: Int
    public let cursor: Cursor?
    public let includeAttachments: Bool
    public let search: String?
    public let searchMode: MessageSearchMode

    public init(
        limit: Int = 50,
        cursor: Cursor? = nil,
        includeAttachments: Bool = false,
        search: String? = nil,
        searchMode: MessageSearchMode = .contains
    ) {
        self.limit = limit
        self.cursor = cursor
        self.includeAttachments = includeAttachments
        self.search = search
        self.searchMode = searchMode
    }
}

public protocol ConversationStoring: Sendable {
    func listConversations(
        options: ConversationListOptions
    ) async throws -> PaginatedResponse<Conversation>
    func conversation(id: ConversationID) async throws -> Conversation?
    func sendContext(id: ConversationID) async throws -> ConversationSendContext?
    func sendContexts(
        matchingExactParticipants participants: [RecipientHandle]
    ) async throws -> [ConversationSendContext]
}

public protocol MessageStoring: Sendable {
    func listMessages(
        conversationID: ConversationID,
        options: MessageListOptions
    ) async throws -> PaginatedResponse<Message>
    func message(id: MessageID) async throws -> Message?
}

public final class ReadableMedia: @unchecked Sendable {
    public let reference: MediaReference
    public let byteCount: Int64
    private let descriptor: Int32

    init(reference: MediaReference, descriptor: Int32, byteCount: Int64) {
        self.reference = reference
        self.descriptor = descriptor
        self.byteCount = byteCount
    }

    deinit { close(descriptor) }

    public func readChunk(offset: Int64, maximumBytes: Int = 128 * 1024) throws -> Data {
        guard offset >= 0, maximumBytes > 0, offset < byteCount else { return Data() }
        var data = Data(count: min(maximumBytes, Int(byteCount - offset)))
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let address = bytes.baseAddress else { return 0 }
            return pread(descriptor, address, bytes.count, offset)
        }
        guard readCount >= 0 else {
            throw SQLiteStorageError.queryFailed("Could not read media bytes: \(String(cString: strerror(errno))).")
        }
        data.count = readCount
        return data
    }
}

public protocol MessageMediaStoring: Sendable {
    func media(id: MediaID) async throws -> ReadableMedia?
}

public protocol DatabaseStatusProviding: Sendable {
    func databaseStatus() async -> DatabaseStatus
}

public protocol MessageChangeObserving: Sendable {
    func events() -> AsyncThrowingStream<RelayEvent, any Error>
    func shutdown() async throws
}
