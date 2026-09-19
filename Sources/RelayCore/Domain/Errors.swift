public enum APIErrorCode: String, Codable, Equatable, Sendable {
    case malformedJSON = "malformed_json"
    case invalidAuthentication = "invalid_authentication"
    case invalidDestination = "invalid_destination"
    case ambiguousDestination = "ambiguous_destination"
    case ambiguousConversation = "ambiguous_conversation"
    case disallowedRecipient = "disallowed_recipient"
    case unknownConversation = "unknown_conversation"
    case unknownMessage = "unknown_message"
    case unknownMedia = "unknown_media"
    case unknownRequest = "unknown_request"
    case unsupportedCapability = "unsupported_capability"
    case senderUnavailable = "sender_unavailable"
    case databaseUnavailable = "database_unavailable"
    case invalidCursor = "invalid_cursor"
    case unsafeMedia = "unsafe_media"
    case mediaTooLarge = "media_too_large"
    case duplicateRequest = "duplicate_request"
    case sendResultUnknown = "send_result_unknown"
    case reactionResultUnknown = "reaction_result_unknown"
    case readResultUnknown = "read_result_unknown"
    case messagesUnavailable = "messages_unavailable"
    case typingConflict = "typing_conflict"
    case typingResultUnknown = "typing_result_unknown"
    case requestTrackingUnavailable = "request_tracking_unavailable"
    case invalidRequest = "invalid_request"
    case internalError = "internal_error"
    case notFound = "not_found"
}

public struct APIFieldError: Codable, Equatable, Sendable {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

public struct APIError: Error, Codable, Equatable, Sendable {
    public let code: APIErrorCode
    public let message: String
    public let requestID: RequestID
    public let fieldDetails: [APIFieldError]?

    private enum CodingKeys: String, CodingKey {
        case code, message
        case requestID = "request_id"
        case fieldDetails = "field_details"
    }

    public init(
        code: APIErrorCode,
        message: String,
        requestID: RequestID,
        fieldDetails: [APIFieldError]? = nil
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.fieldDetails = fieldDetails
    }
}

public enum RelayServiceError: Error, Equatable, Sendable {
    case invalidDestination([APIFieldError])
    case ambiguousDestination
    case ambiguousConversation
    case disallowedRecipient
    case unknownConversation
    case unknownMessage
    case unknownMedia
    case unknownRequest
    case unsupportedCapability(String)
    case senderUnavailable(String)
    case databaseUnavailable(String)
    case invalidCursor
    case unsafeMedia(String)
    case mediaTooLarge(maximumBytes: Int64)
    case duplicateRequest(RequestID)
    case invalidRequest([APIFieldError])
    case uncertainSend(String)
    case uncertainReaction(String)
    case uncertainRead(String)
    case messagesUnavailable(String)
    case typingConflict(String)
    case uncertainTyping(String)
    case requestTrackingUnavailable(String)
}
