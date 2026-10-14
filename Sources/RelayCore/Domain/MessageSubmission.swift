import HummingbirdOpenAPIModels

/// The flat HTTP representation. Decode first, then validate the domain request.
/// The generated schema and the HTTP decoder both use these stored properties.
@OpenAPIModel
public struct MessageSubmission: Codable, Equatable, Sendable {
    public let to: String?
    public let participants: [String]?
    public let conversationID: String?
    public let text: String?
    public let media: [SubmittedMedia]?
    public let replyTo: SubmittedReply?

    private enum CodingKeys: String, CodingKey {
        case to, participants, text, media
        case conversationID = "conversation_id"
        case replyTo = "reply_to"
    }

    public init(request: SendMessageRequest) {
        switch request.destination {
        case .conversation(let id):
            conversationID = id.rawValue
            to = nil
            participants = nil
        case .recipient(let handle):
            conversationID = nil
            to = handle.displayValue ?? handle.value
            participants = nil
        case .participants(let handles):
            conversationID = nil
            to = nil
            participants = handles.map { $0.displayValue ?? $0.value }
        }
        text = request.content.text
        media = request.content.media.isEmpty ? nil : request.content.media.map { SubmittedMedia(mediaID: $0.mediaID.rawValue) }
        replyTo = request.replyTo.map { SubmittedReply(messageID: $0.messageID.rawValue) }
    }

    public func validated() throws -> SendMessageRequest {
        let conversationID = try conversationID.map(ConversationID.init(validating:))
        let recipient = try to.map(RecipientHandle.resolvable(value:))
        let participants = try participants?.map(RecipientHandle.resolvable(value:))
        let count = [conversationID != nil, recipient != nil, participants != nil].filter { $0 }.count
        guard count > 0 else { throw SendMessageRequest.ValidationError.missingDestination }
        guard count == 1 else { throw SendMessageRequest.ValidationError.ambiguousDestination }
        let destination: MessageDestination
        if let conversationID {
            destination = .conversation(conversationID)
        } else if let recipient {
            destination = .recipient(recipient)
        } else if let participants {
            guard participants.count >= 2 else { throw SendMessageRequest.ValidationError.invalidParticipantCount }
            var seen: Set<String> = []
            for (index, participant) in participants.enumerated() {
                let key = "\(participant.type.rawValue)\u{0}\(participant.value)"
                guard seen.insert(key).inserted else {
                    throw SendMessageRequest.ValidationError.duplicateParticipant(index)
                }
            }
            destination = .participants(participants)
        } else {
            throw SendMessageRequest.ValidationError.missingDestination
        }
        return SendMessageRequest(
            destination: destination,
            content: MessageContent(
                text: text,
                media: try media?.map { SendMediaReference(mediaID: try MediaID(validating: $0.mediaID)) } ?? []
            ),
            replyTo: try replyTo.map { ReplyTarget(messageID: try MessageID(validating: $0.messageID)) }
        )
    }
}

@OpenAPIModel
public struct SubmittedMedia: Codable, Equatable, Sendable {
    public let mediaID: String
    private enum CodingKeys: String, CodingKey { case mediaID = "media_id" }
}

@OpenAPIModel
public struct SubmittedReply: Codable, Equatable, Sendable {
    public let messageID: String
    private enum CodingKeys: String, CodingKey { case messageID = "message_id" }
}
