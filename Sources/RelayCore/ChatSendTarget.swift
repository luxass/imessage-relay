public struct ChatSendTarget: Sendable {
    public let chatGuid: String
    public let recipients: [String]

    public init(chatGuid: String, recipients: [String]) {
        self.chatGuid = chatGuid
        self.recipients = recipients
    }
}
