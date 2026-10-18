import HummingbirdOpenAPIModels
import RelayCore

@OpenAPIModel
struct StatusPayload: Codable, Sendable {
    let version: String
    let healthy: Bool
    let database: DatabaseStatus
    let sender: SenderPayload

    init(_ status: ServiceStatus) {
        version = status.version
        healthy = status.healthy
        database = status.database
        sender = SenderPayload(status.sender)
    }
}

@OpenAPIModel
struct SenderPayload: Codable, Sendable {
    let id: String
    let accountIdentity: String?
    let login: HandlePayload?
    let configured: Bool
    let availability: SenderAvailability
    let reason: String?
    let permissions: SenderPermissions
    let capabilities: SenderCapabilities

    private enum CodingKeys: String, CodingKey {
        case id, login, configured, availability, reason, permissions, capabilities
        case accountIdentity = "account_identity"
    }

    init(_ sender: Sender) {
        id = sender.id.rawValue
        accountIdentity = sender.accountIdentity
        login = sender.login.map(HandlePayload.init)
        configured = sender.configured
        availability = sender.availability
        reason = sender.reason
        permissions = sender.permissions
        capabilities = sender.capabilities
    }
}

@OpenAPIModel
struct HandlePayload: Codable, Sendable {
    let type: RecipientHandleType
    let value: String
    let displayValue: String?
    private enum CodingKeys: String, CodingKey {
        case type, value
        case displayValue = "display_value"
    }

    init(_ handle: RecipientHandle) {
        type = handle.type
        value = handle.value
        displayValue = handle.displayValue
    }
}

@OpenAPIModel
struct SendReceiptPayload: Codable, Sendable {
    let requestID: String
    let status: MessageStatus
    let correlationStatus: SendCorrelationStatus
    let conversationID: String?
    let messages: [MessageReceiptPayload]
    let media: [MediaReceiptPayload]
    let pollURL: String?

    private enum CodingKeys: String, CodingKey {
        case status, messages, media
        case requestID = "request_id"
        case correlationStatus = "correlation_status"
        case conversationID = "conversation_id"
        case pollURL = "poll_url"
    }

    init(_ response: SendMessageResponse) {
        requestID = response.requestID.rawValue
        status = response.status
        correlationStatus = response.correlationStatus
        conversationID = response.conversationID?.rawValue
        messages = response.messages.map(MessageReceiptPayload.init)
        media = response.media.map(MediaReceiptPayload.init)
        pollURL = response.pollURL
    }
}

@OpenAPIModel
struct MessageReceiptPayload: Codable, Sendable {
    let messageID: String
    let status: MessageStatus
    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case status
    }

    init(_ receipt: MessageReceipt) {
        messageID = receipt.messageID.rawValue
        status = receipt.status
    }
}

// Null attachment/message IDs distinguish unmatched media from omitted metadata.
@OpenAPIModel(encodeNil: true)
struct MediaReceiptPayload: Codable, Sendable {
    let requestedMediaID: String
    let mediaID: String?
    let messageID: String?
    private enum CodingKeys: String, CodingKey {
        case requestedMediaID = "requested_media_id"
        case mediaID = "media_id"
        case messageID = "message_id"
    }

    init(_ receipt: MediaReceipt) {
        requestedMediaID = receipt.requestedMediaID.rawValue
        mediaID = receipt.mediaID?.rawValue
        messageID = receipt.messageID?.rawValue
    }
}

@OpenAPIModel
struct ErrorPayload: Codable, Sendable {
    let code: APIErrorCode
    let message: String
    let requestID: String
    let fieldDetails: [APIFieldError]?
    private enum CodingKeys: String, CodingKey {
        case code, message
        case requestID = "request_id"
        case fieldDetails = "field_details"
    }
}
