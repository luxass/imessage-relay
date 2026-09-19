import Foundation

public actor TypingService: TypingLeaseStopping {
    private struct ActiveLease: Sendable {
        let conversationID: ConversationID
        let nativeRequest: ConversationTypingWriteRequest
        let generation: UUID
    }

    private let conversations: any ConversationStoring
    private let messages: any MessageStoring
    private let writer: any ConversationTypingWriting
    private let leaseDuration: Duration
    private let operationGate = TypingOperationGate()
    private var activeLease: ActiveLease?
    private var expirationTask: Task<Void, Never>?

    public init(
        conversations: any ConversationStoring,
        messages: any MessageStoring,
        writer: any ConversationTypingWriting,
        leaseDuration: Duration = .seconds(5)
    ) {
        self.conversations = conversations
        self.messages = messages
        self.writer = writer
        self.leaseDuration = leaseDuration
    }

    public func start(
        conversationID: ConversationID,
        requestID: RequestID
    ) async throws -> ConversationTypingResponse {
        await operationGate.acquire()
        do {
            let response = try await startLocked(
                conversationID: conversationID,
                requestID: requestID
            )
            await operationGate.release()
            return response
        } catch {
            await operationGate.release()
            throw error
        }
    }

    public func stop(
        conversationID: ConversationID,
        requestID: RequestID
    ) async throws -> ConversationTypingResponse {
        await operationGate.acquire()
        do {
            let response = try await stopLocked(
                conversationID: conversationID,
                requestID: requestID
            )
            await operationGate.release()
            return response
        } catch {
            await operationGate.release()
            throw error
        }
    }

    public func stopActiveTyping() async throws {
        await operationGate.acquire()
        do {
            try await stopActiveLease()
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func startLocked(
        conversationID: ConversationID,
        requestID: RequestID
    ) async throws -> ConversationTypingResponse {
        let nativeRequest = try await target(conversationID: conversationID)
        if let activeLease, activeLease.conversationID != conversationID {
            try await stopActiveLease()
        }
        do {
            try await writer.startTyping(nativeRequest)
        } catch {
            throw Self.map(error)
        }

        expirationTask?.cancel()
        let generation = UUID()
        activeLease = ActiveLease(
            conversationID: conversationID,
            nativeRequest: nativeRequest,
            generation: generation
        )
        let expiration = Timestamp(Date().addingTimeInterval(Self.seconds(leaseDuration)))
        expirationTask = Task { [weak self, leaseDuration] in
            try? await Task.sleep(for: leaseDuration)
            guard !Task.isCancelled else { return }
            await self?.expire(generation: generation)
        }
        return ConversationTypingResponse(
            requestID: requestID,
            conversationID: conversationID,
            status: .active,
            expiresAt: expiration
        )
    }

    private func stopLocked(
        conversationID: ConversationID,
        requestID: RequestID
    ) async throws -> ConversationTypingResponse {
        guard try await conversations.conversation(id: conversationID) != nil else {
            throw RelayServiceError.unknownConversation
        }
        if activeLease?.conversationID == conversationID {
            try await stopActiveLease()
        }
        return ConversationTypingResponse(
            requestID: requestID,
            conversationID: conversationID,
            status: .inactive,
            expiresAt: nil
        )
    }

    private func stopActiveLease() async throws {
        guard let lease = activeLease else { return }
        do {
            try await writer.stopTyping(lease.nativeRequest)
        } catch {
            throw Self.map(error)
        }
        expirationTask?.cancel()
        expirationTask = nil
        activeLease = nil
    }

    private func expire(generation: UUID) async {
        await operationGate.acquire()
        guard activeLease?.generation == generation else {
            await operationGate.release()
            return
        }
        let lease = activeLease
        activeLease = nil
        expirationTask = nil
        if let lease {
            try? await writer.stopTyping(lease.nativeRequest)
        }
        await operationGate.release()
    }

    private func target(
        conversationID: ConversationID
    ) async throws -> ConversationTypingWriteRequest {
        guard let conversation = try await conversations.conversation(id: conversationID) else {
            throw RelayServiceError.unknownConversation
        }
        guard let conversationGUID = conversation.providerGUID else {
            throw RelayServiceError.unsupportedCapability(
                "The conversation has no provider GUID for a safe typing operation."
            )
        }
        let page = try await messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(limit: 1)
        )
        guard let anchorMessageGUID = page.items.first?.providerGUID else {
            throw RelayServiceError.unsupportedCapability(
                "The conversation has no provider message anchor for a safe typing operation."
            )
        }
        return ConversationTypingWriteRequest(
            conversationGUID: conversationGUID,
            anchorMessageGUID: anchorMessageGUID,
            isGroup: conversation.isGroup
        )
    }

    private static func map(_ error: Error) -> RelayServiceError {
        switch error {
        case ConversationTypingWriterError.draftConflict(let detail):
            .typingConflict(detail)
        case ConversationTypingWriterError.unsupported(let detail):
            .unsupportedCapability(detail)
        case ConversationTypingWriterError.unavailable(let detail),
             ConversationTypingWriterError.notStarted(let detail):
            .messagesUnavailable(detail)
        case ConversationTypingWriterError.uncertain(let detail):
            .uncertainTyping(detail)
        default:
            .messagesUnavailable(String(describing: error))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private actor TypingOperationGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available = true
        } else {
            waiters.removeFirst().resume()
        }
    }
}
