import Foundation

public struct OutgoingMessageCheckpoint: Codable, Equatable, Sendable {
    public let rowID: Int64

    public init(rowID: Int64) {
        self.rowID = rowID
    }
}

public struct SendCorrelationCriteria: Codable, Equatable, Sendable {
    public let checkpoint: OutgoingMessageCheckpoint
    public let destination: MessageDestination
    public let text: String?
    public let media: [SendCorrelationMedia]
    public let replyToMessageID: MessageID?
    public let threadOriginatorMessageID: MessageID?
    public let accountID: String?

    public init(
        checkpoint: OutgoingMessageCheckpoint,
        destination: MessageDestination,
        text: String?,
        media: [SendCorrelationMedia],
        replyToMessageID: MessageID?,
        threadOriginatorMessageID: MessageID?,
        accountID: String? = nil
    ) {
        self.checkpoint = checkpoint
        self.destination = destination
        self.text = text
        self.media = media
        self.replyToMessageID = replyToMessageID
        self.threadOriginatorMessageID = threadOriginatorMessageID
        self.accountID = accountID
    }
}

public struct SendCorrelationMedia: Codable, Equatable, Sendable {
    public let requestedMediaID: MediaID
    public let filename: String?
    public let mimeType: String?
    public let byteSize: Int64?

    private enum CodingKeys: String, CodingKey {
        case requestedMediaID = "requested_media_id"
        case filename
        case mimeType = "mime_type"
        case byteSize = "byte_size"
    }

    public init(
        requestedMediaID: MediaID,
        filename: String?,
        mimeType: String?,
        byteSize: Int64?
    ) {
        self.requestedMediaID = requestedMediaID
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
    }
}

public struct SendCorrelationSnapshot: Equatable, Sendable {
    public let messages: [Message]
    public let media: [MediaReceipt]

    public init(messages: [Message], media: [MediaReceipt]) {
        self.messages = messages
        self.media = media
    }
}

public enum SendCorrelationOutcome: Equatable, Sendable {
    case pending
    case partial(SendCorrelationSnapshot)
    case complete(SendCorrelationSnapshot)
    case mismatched
    case ambiguous
}

public protocol SendCorrelating: Sendable {
    func checkpoint() async throws -> OutgoingMessageCheckpoint
    func correlate(_ criteria: SendCorrelationCriteria) async throws -> SendCorrelationOutcome
}
