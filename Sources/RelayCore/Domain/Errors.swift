import HummingbirdOpenAPIModels

@OpenAPISchema
public struct APIFieldError: Codable, Equatable, Sendable {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
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
