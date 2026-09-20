import CryptoKit
import Foundation

public struct RecipientAllowlist: Sendable {
    private struct Key: Hashable, Sendable {
        let type: RecipientHandleType
        let value: String
    }

    private let values: Set<Key>

    public init(values: [String]) {
        self.values = Set(values.compactMap { raw in
            guard let handle = try? RecipientHandle.stored(value: raw) else { return nil }
            return Key(type: handle.type, value: handle.value)
        })
    }

    public func allows(_ handle: RecipientHandle) -> Bool {
        values.contains(Key(type: handle.type, value: handle.value))
    }

    public func allowsAll(_ handles: [RecipientHandle]) -> Bool {
        !handles.isEmpty && handles.allSatisfy(allows)
    }
}

public struct MessageService: Sendable {
    private struct PreparedSend: Sendable {
        let destination: MessageDestination
        let accountID: String?
        let text: String?
        let context: ConversationSendContext?
        let conversationAnchorMessageID: MessageID?
        let media: [OutboundMedia]
        let replyContext: ReplySendContext?
    }

    private let conversations: any ConversationStoring
    private let messages: any MessageStoring
    private let sender: any MessageSender
    private let media: MediaService
    private let recipientResolver: any RecipientResolving
    private let allowlist: RecipientAllowlist
    private let sendRequests: any SendRequestStoring
    private let correlator: (any SendCorrelating)?
    private let identificationGate: SendIdentificationGate
    private let identificationTimeout: Duration
    private let identificationPollInterval: Duration
    private let typing: (any TypingLeaseStopping)?

    public init(
        conversations: any ConversationStoring,
        messages: any MessageStoring,
        sender: any MessageSender,
        media: MediaService,
        recipientResolver: any RecipientResolving = DirectRecipientResolver(),
        allowlist: RecipientAllowlist,
        sendRequests: any SendRequestStoring = InMemorySendRequestStore(),
        correlator: (any SendCorrelating)? = nil,
        identificationGate: SendIdentificationGate = SendIdentificationGate(),
        identificationTimeout: Duration = .seconds(3),
        identificationPollInterval: Duration = .milliseconds(100),
        typing: (any TypingLeaseStopping)? = nil
    ) {
        self.conversations = conversations
        self.messages = messages
        self.sender = sender
        self.media = media
        self.recipientResolver = recipientResolver
        self.allowlist = allowlist
        self.sendRequests = sendRequests
        self.correlator = correlator
        self.identificationGate = identificationGate
        self.identificationTimeout = identificationTimeout
        self.identificationPollInterval = identificationPollInterval
        self.typing = typing
    }

    public func list(
        conversationID: ConversationID,
        options: MessageListOptions
    ) async throws -> PaginatedResponse<Message> {
        try await messages.listMessages(conversationID: conversationID, options: options)
    }

    public func get(id: MessageID) async throws -> Message {
        guard let message = try await messages.message(id: id) else {
            throw RelayServiceError.unknownMessage
        }
        return message
    }

    public func request(id: RequestID) async throws -> SendMessageResponse {
        do {
            guard let response = try await sendRequests.response(requestID: id) else {
                throw RelayServiceError.unknownRequest
            }
            return try await reconcile(response)
        } catch let error as SendRequestStorageError {
            throw Self.mapStorageError(error)
        }
    }

    public func send(
        _ request: SendMessageRequest,
        requestID: RequestID,
        idempotencyKey: String?
    ) async throws -> SendMessageResponse {
        let prepared = try await prepare(request)
        let key = try Self.normalizedIdempotencyKey(idempotencyKey)
        try await typing?.stopActiveTyping()
        if let replay = try await reserve(request, prepared: prepared, requestID: requestID, key: key) {
            return replay
        }
        let operation = SenderDispatchRequest(
            requestID: requestID,
            destination: prepared.destination,
            conversationContext: prepared.context,
            conversationAnchorMessageID: prepared.conversationAnchorMessageID,
            text: prepared.text,
            media: prepared.media,
            replyTarget: request.replyTo,
            replyContext: prepared.replyContext
        )
        guard correlator != nil else { return try await dispatch(operation) }
        return try await identificationGate.run {
            try await dispatchAndIdentify(operation, prepared: prepared)
        }
    }

    private func dispatchAndIdentify(
        _ operation: SenderDispatchRequest,
        prepared: PreparedSend
    ) async throws -> SendMessageResponse {
        guard let correlator else { return try await dispatch(operation) }
        let checkpoint: OutgoingMessageCheckpoint
        do {
            checkpoint = try await correlator.checkpoint()
        } catch {
            throw RelayServiceError.databaseUnavailable(String(describing: error))
        }
        let correlation = SendCorrelationCriteria(
            checkpoint: checkpoint,
            destination: operation.destination,
            text: prepared.text,
            media: prepared.media.map {
                SendCorrelationMedia(
                    requestedMediaID: $0.reference.mediaID,
                    filename: $0.reference.filename,
                    mimeType: $0.reference.mimeType,
                    byteSize: $0.reference.byteSize
                )
            },
            replyToMessageID: prepared.replyContext?.messageID,
            threadOriginatorMessageID: prepared.replyContext.map {
                $0.threadOriginatorMessageID ?? $0.messageID
            },
            accountID: prepared.accountID
        )
        do {
            try await sendRequests.recordCorrelation(correlation, requestID: operation.requestID)
        } catch let error as SendRequestStorageError {
            throw Self.mapStorageError(error)
        }

        let response = try await dispatch(operation)
        guard response.correlationStatus != .complete else { return response }
        return try await identify(response, correlation: correlation, wait: true)
    }

    private func reconcile(_ response: SendMessageResponse) async throws -> SendMessageResponse {
        if response.correlationStatus == .pending || response.correlationStatus == .partial {
            if correlator != nil,
               let correlation = try await sendRequests.correlation(requestID: response.requestID) {
                return try await identify(response, correlation: correlation, wait: false)
            }
        }
        guard response.status != .resultUnknown,
              response.status != .failed,
              response.status != .unsupported else { return response }
        return try await refresh(response)
    }

    private func identify(
        _ response: SendMessageResponse,
        correlation: SendCorrelationCriteria,
        wait: Bool
    ) async throws -> SendMessageResponse {
        guard let correlator else { return response }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: identificationTimeout)
        var current = response
        repeat {
            let outcome: SendCorrelationOutcome
            do {
                outcome = try await correlator.correlate(correlation)
            } catch {
                let unknown = SendMessageResponse.tracking(
                    requestID: response.requestID,
                    status: .resultUnknown,
                    correlationStatus: .ambiguous,
                    conversationID: current.conversationID,
                    messages: current.messages,
                    media: current.media
                )
                do {
                    try await sendRequests.record(unknown)
                } catch {
                    throw RelayServiceError.uncertainSend(
                        "The provider result is unknown and its durable status could not be recorded."
                    )
                }
                return unknown
            }
            switch outcome {
            case .pending:
                break
            case .partial(let snapshot):
                let partial = makeResponse(
                    requestID: response.requestID,
                    status: .partial,
                    snapshot: snapshot
                )
                if partial != current {
                    try await record(partial, afterSend: wait)
                    current = partial
                }
                if !wait { return current }
            case .complete(let snapshot):
                let complete = makeResponse(
                    requestID: response.requestID,
                    status: .complete,
                    snapshot: snapshot
                )
                if complete != current { try await record(complete, afterSend: wait) }
                return complete
            case .mismatched, .ambiguous:
                let ambiguous = SendMessageResponse.tracking(
                    requestID: response.requestID,
                    status: .resultUnknown,
                    correlationStatus: .ambiguous,
                    conversationID: current.conversationID,
                    messages: current.messages,
                    media: current.media
                )
                try await record(ambiguous, afterSend: wait)
                return ambiguous
            }
            guard wait, clock.now < deadline else { return current }
            do {
                try await Task.sleep(for: min(
                    identificationPollInterval,
                    clock.now.duration(to: deadline)
                ))
            } catch {
                return current
            }
        } while true
    }

    private func refresh(_ response: SendMessageResponse) async throws -> SendMessageResponse {
        var receipts: [MessageReceipt] = []
        for receipt in response.messages {
            if let message = try await messages.message(id: receipt.messageID) {
                receipts.append(MessageReceipt(messageID: message.id, status: Self.status(message)))
            } else {
                receipts.append(receipt)
            }
        }
        let updated = SendMessageResponse.tracking(
            requestID: response.requestID,
            status: response.correlationStatus == .complete
                ? Self.aggregateStatus(receipts)
                : response.status,
            correlationStatus: response.correlationStatus,
            conversationID: response.conversationID,
            messages: receipts,
            media: response.media
        )
        if updated != response { try await record(updated, afterSend: false) }
        return updated
    }

    private func makeResponse(
        requestID: RequestID,
        status: SendCorrelationStatus,
        snapshot: SendCorrelationSnapshot
    ) -> SendMessageResponse {
        let receipts = snapshot.messages.map {
            MessageReceipt(messageID: $0.id, status: Self.status($0))
        }
        return .tracking(
            requestID: requestID,
            status: status == .complete ? Self.aggregateStatus(receipts) : .accepted,
            correlationStatus: status,
            conversationID: Self.conversationID(snapshot.messages),
            messages: receipts,
            media: snapshot.media
        )
    }

    private func record(_ response: SendMessageResponse, afterSend: Bool) async throws {
        do {
            try await sendRequests.record(response)
        } catch let error as SendRequestStorageError {
            if afterSend {
                throw RelayServiceError.uncertainSend(
                    "The provider message was identified, but its durable status could not be recorded."
                )
            }
            throw Self.mapStorageError(error)
        }
    }

    private static func status(_ message: Message) -> MessageStatus {
        if message.deliveryState == .failed { return .failed }
        if message.readState == .read { return .read }
        switch message.deliveryState {
        case .failed: return .failed
        case .delivered: return .delivered
        case .sent: return .sent
        case .notSent: return .sending
        case .unknown: return .accepted
        }
    }

    private static func aggregateStatus(_ messages: [MessageReceipt]) -> MessageStatus {
        guard !messages.isEmpty else { return .accepted }
        let values = messages.map(\.status)
        if values.contains(.failed) { return .failed }
        if values.contains(.resultUnknown) { return .resultUnknown }
        if values.contains(.unsupported) { return .unsupported }
        if values.allSatisfy({ $0 == .read }) { return .read }
        if values.allSatisfy({ $0 == .read || $0 == .delivered }) { return .delivered }
        if values.allSatisfy({ $0 == .read || $0 == .delivered || $0 == .sent }) { return .sent }
        if values.contains(.sending) { return .sending }
        if values.allSatisfy({ $0 == .queued }) { return .queued }
        return .accepted
    }

    private func prepare(_ request: SendMessageRequest) async throws -> PreparedSend {
        let text = request.content.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text?.isEmpty == false || !request.content.media.isEmpty else {
            throw RelayServiceError.invalidRequest([
                APIFieldError(field: "text", message: "Provide text, media, or both.")
            ])
        }
        let requestedDestination = try await resolve(request.destination)
        let participantDestination: Bool
        if case .participants = requestedDestination {
            participantDestination = true
            guard text?.isEmpty == false else {
                throw RelayServiceError.invalidRequest([
                    APIFieldError(field: "text", message: "A new group requires initial text.")
                ])
            }
            guard request.content.media.isEmpty else {
                throw RelayServiceError.unsupportedCapability(
                    "Initial group media is unsupported. Send it after the group has a conversation_id."
                )
            }
            guard request.replyTo == nil else {
                throw RelayServiceError.unsupportedCapability(
                    "A group creation request cannot be a reply."
                )
            }
        } else {
            participantDestination = false
        }

        if case .participants(let participants) = requestedDestination,
           !allowlist.allowsAll(participants) {
            throw RelayServiceError.disallowedRecipient
        }
        let destination = try await destinationContext(requestedDestination)
        let createsGroup = participantDestination && destination.context == nil
        guard allowlist.allowsAll(destination.recipients) else {
            throw RelayServiceError.disallowedRecipient
        }

        var outboundMedia: [OutboundMedia] = []
        for item in request.content.media {
            outboundMedia.append(try await media.outbound(id: item.mediaID))
        }
        let replyContext = try await replyContext(request.replyTo, destination: destination.destination)
        let senderStatus = await sender.status()
        try validateCapabilities(
            status: senderStatus,
            media: outboundMedia,
            replyTo: request.replyTo,
            createsGroup: createsGroup
        )
        let conversationAnchorMessageID = try await conversationAnchor(
            destination: destination.destination,
            media: outboundMedia
        )
        return PreparedSend(
            destination: destination.destination,
            accountID: destination.context?.accountID ?? senderStatus.accountIdentity,
            text: text,
            context: destination.context,
            conversationAnchorMessageID: conversationAnchorMessageID,
            media: outboundMedia,
            replyContext: replyContext
        )
    }

    private func conversationAnchor(
        destination: MessageDestination,
        media: [OutboundMedia]
    ) async throws -> MessageID? {
        guard !media.isEmpty, case .conversation(let conversationID) = destination else {
            return nil
        }
        let page = try await messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(limit: 1)
        )
        guard let messageID = page.items.first?.id else {
            throw RelayServiceError.invalidRequest([
                APIFieldError(
                    field: "conversation_id",
                    message: "The conversation has no message that can anchor a safe media send."
                )
            ])
        }
        return messageID
    }

    private func resolve(_ destination: MessageDestination) async throws -> MessageDestination {
        do {
            switch destination {
            case .conversation:
                return destination
            case .recipient(let candidate):
                return .recipient(try await recipientResolver.resolve(candidate))
            case .participants(let candidates):
                var recipients: [RecipientHandle] = []
                for candidate in candidates {
                    recipients.append(try await recipientResolver.resolve(candidate))
                }
                let keys = recipients.map { "\($0.type.rawValue)\u{0}\($0.value)" }
                guard Set(keys).count == recipients.count else {
                    throw RelayServiceError.invalidDestination([
                        APIFieldError(
                            field: "participants",
                            message: "Each resolved participant must be unique."
                        )
                    ])
                }
                return .participants(recipients)
            }
        } catch RecipientResolutionError.ambiguous(let query) {
            throw RelayServiceError.invalidDestination([
                APIFieldError(field: "destination", message: "Multiple contacts match \(query).")
            ])
        } catch RecipientResolutionError.contactsUnavailable {
            throw RelayServiceError.invalidDestination([
                APIFieldError(field: "destination", message: "Contacts access is unavailable.")
            ])
        } catch RecipientResolutionError.notFound(let query) {
            throw RelayServiceError.invalidDestination([
                APIFieldError(field: "destination", message: "No recipient matches \(query).")
            ])
        }
    }

    private func destinationContext(
        _ destination: MessageDestination
    ) async throws -> (
        destination: MessageDestination,
        context: ConversationSendContext?,
        recipients: [RecipientHandle]
    ) {
        switch destination {
        case .recipient(let recipient):
            guard recipient.type == .phone || recipient.type == .email else {
                throw RelayServiceError.invalidDestination([
                    APIFieldError(field: "to.type", message: "Direct sends support phone or email recipients.")
                ])
            }
            return (destination, nil, [recipient])
        case .conversation(let id):
            guard let found = try await conversations.sendContext(id: id) else {
                throw RelayServiceError.unknownConversation
            }
            return (destination, found, found.recipients)
        case .participants(let participants):
            guard participants.allSatisfy({ $0.type == .phone || $0.type == .email }) else {
                throw RelayServiceError.invalidDestination([
                    APIFieldError(
                        field: "participants",
                        message: "Group participants must be phone numbers or email addresses."
                    )
                ])
            }
            let matches = try await conversations.sendContexts(
                matchingExactParticipants: participants
            )
            switch matches.count {
            case 0:
                return (destination, nil, participants)
            case 1:
                let context = matches[0]
                return (.conversation(context.conversationID), context, participants)
            default:
                throw RelayServiceError.ambiguousConversation
            }
        }
    }

    private func replyContext(
        _ reply: ReplyTarget?,
        destination: MessageDestination
    ) async throws -> ReplySendContext? {
        guard let reply else { return nil }
        guard let target = try await messages.message(id: reply.messageID) else {
            throw RelayServiceError.unknownMessage
        }
        if case .conversation(let id) = destination, target.conversationID != id {
            throw RelayServiceError.invalidRequest([
                APIFieldError(field: "reply_to.message_id", message: "The reply target belongs to another conversation.")
            ])
        }
        return ReplySendContext(
            messageID: target.id,
            threadOriginatorMessageID: target.thread?.threadOriginatorMessageID
        )
    }

    private func validateCapabilities(
        status: Sender,
        media: [OutboundMedia],
        replyTo: ReplyTarget?,
        createsGroup: Bool
    ) throws {
        if createsGroup,
           status.capabilities.groupCreation != .available,
           status.capabilities.groupCreation != .permissionUnknown {
            throw RelayServiceError.unsupportedCapability(
                "Group creation is unsupported by the local sender."
            )
        }
        if !media.isEmpty,
           status.capabilities.media != .available,
           status.capabilities.media != .permissionUnknown {
            throw RelayServiceError.unsupportedCapability("Media sending is unsupported by the local sender.")
        }
        if replyTo != nil, status.capabilities.nativeReply != .available {
            throw RelayServiceError.unsupportedCapability("Native iMessage replies are unsupported by the local sender.")
        }
    }

    private static func normalizedIdempotencyKey(_ idempotencyKey: String?) throws -> String? {
        let trimmedKey = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedKey?.isEmpty == false ? trimmedKey : nil
        if let key {
            guard key.utf8.count <= 128,
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RelayServiceError.invalidRequest([
                    APIFieldError(field: "Idempotency-Key", message: "Use 1 to 128 visible characters.")
                ])
            }
        }
        return key
    }

    private func reserve(
        _ request: SendMessageRequest,
        prepared: PreparedSend,
        requestID: RequestID,
        key: String?
    ) async throws -> SendMessageResponse? {
        do {
            let reservation = try await sendRequests.reserve(
                requestID: requestID,
                idempotencyKey: key,
                fingerprint: Self.fingerprint(
                    destination: request.destination,
                    text: prepared.text,
                    media: request.content.media,
                    replyTo: request.replyTo
                )
            )
            if case .replay(let response) = reservation { return response }
            return nil
        } catch let error as SendRequestStorageError {
            throw Self.mapStorageError(error)
        }
    }

    private func dispatch(_ dispatch: SenderDispatchRequest) async throws -> SendMessageResponse {
        do {
            let result = try await sender.send(dispatch)
            let receipts = result.messageID.map {
                [MessageReceipt(messageID: $0, status: result.status)]
            } ?? []
            let media = dispatch.media.map {
                MediaReceipt(
                    requestedMediaID: $0.reference.mediaID,
                    mediaID: nil,
                    messageID: nil
                )
            }
            let correlationStatus: SendCorrelationStatus = switch result.status {
            case .failed, .unsupported: .complete
            case .resultUnknown: .ambiguous
            default:
                if result.messageID != nil {
                    media.isEmpty ? .complete : .partial
                } else {
                    .pending
                }
            }
            let response = SendMessageResponse.tracking(
                requestID: dispatch.requestID,
                status: result.status,
                correlationStatus: correlationStatus,
                conversationID: Self.conversationID(dispatch.destination),
                messages: receipts,
                media: media
            )
            do {
                try await sendRequests.record(response)
            } catch {
                throw RelayServiceError.uncertainSend(
                    "The sender accepted the operation, but its durable request status could not be recorded."
                )
            }
            return response
        } catch MessageSenderError.notStarted(let detail) {
            try? await sendRequests.record(.tracking(
                requestID: dispatch.requestID,
                status: .failed,
                correlationStatus: .complete
            ))
            throw RelayServiceError.senderUnavailable(detail)
        } catch MessageSenderError.unavailable(let detail) {
            try? await sendRequests.record(.tracking(
                requestID: dispatch.requestID,
                status: .failed,
                correlationStatus: .complete
            ))
            throw RelayServiceError.senderUnavailable(detail)
        } catch MessageSenderError.unsupported(let detail) {
            try? await sendRequests.record(.tracking(
                requestID: dispatch.requestID,
                status: .unsupported,
                correlationStatus: .complete
            ))
            throw RelayServiceError.unsupportedCapability(detail)
        } catch MessageSenderError.uncertain(let detail) {
            try? await sendRequests.record(.tracking(
                requestID: dispatch.requestID,
                status: .resultUnknown,
                correlationStatus: .ambiguous
            ))
            throw RelayServiceError.uncertainSend(detail)
        }
    }

    private static func fingerprint(
        destination: MessageDestination,
        text: String?,
        media: [SendMediaReference],
        replyTo: ReplyTarget?
    ) -> String {
        let destinationValue = switch destination {
        case .conversation(let id): "conversation:\(id.rawValue)"
        case .recipient(let handle): "recipient:\(handle.type.rawValue):\(handle.value)"
        case .participants(let handles):
            "participants:" + handles
                .map { "\($0.type.rawValue):\($0.value)" }
                .sorted()
                .joined(separator: ",")
        }
        let value = [
            destinationValue,
            "text:\(text ?? "")",
            "media:\(media.map(\.mediaID.rawValue).joined(separator: ","))",
            "reply:\(replyTo?.messageID.rawValue ?? "")",
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func conversationID(_ destination: MessageDestination) -> ConversationID? {
        if case .conversation(let conversationID) = destination { return conversationID }
        return nil
    }

    private static func conversationID(_ messages: [Message]) -> ConversationID? {
        guard let first = messages.first?.conversationID,
              messages.allSatisfy({ $0.conversationID == first }) else { return nil }
        return first
    }

    private static func mapStorageError(_ error: SendRequestStorageError) -> RelayServiceError {
        switch error {
        case .conflict(let requestID): .duplicateRequest(requestID)
        case .unavailable(let detail): .requestTrackingUnavailable(detail)
        }
    }
}
