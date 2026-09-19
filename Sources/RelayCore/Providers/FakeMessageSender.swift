import Foundation

public final class FakeMessageSender: MessageSender, @unchecked Sendable {
    public enum Outcome: Sendable {
        case result(SenderDispatchResult)
        case error(MessageSenderError)
    }

    private let lock = NSLock()
    private let senderStatus: Sender
    private let outcome: Outcome
    private var storedRequests: [SenderDispatchRequest] = []

    public init(sender: Sender, outcome: Outcome = .result(.init(messageID: nil, status: .accepted))) {
        senderStatus = sender
        self.outcome = outcome
    }

    public var requests: [SenderDispatchRequest] {
        lock.withLock { storedRequests }
    }

    public func status() async -> Sender { senderStatus }

    public func send(_ request: SenderDispatchRequest) async throws -> SenderDispatchResult {
        lock.withLock { storedRequests.append(request) }
        switch outcome {
        case .result(let result): return result
        case .error(let error): throw error
        }
    }

    public static func available(
        capabilities: SenderCapabilities = .init(
            text: .available,
            media: .available,
            nativeReply: .available,
            reactions: .available,
            groupCreation: .available
        )
    ) -> FakeMessageSender {
        guard let id = SenderID(rawValue: "fake-local-sender") else {
            preconditionFailure("The built-in fake sender identifier is invalid.")
        }
        let sender = Sender(
            id: id,
            accountIdentity: "fake-account",
            login: nil,
            configured: true,
            availability: .available,
            reason: nil,
            capabilities: capabilities
        )
        return FakeMessageSender(sender: sender)
    }
}
