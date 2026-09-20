import Foundation

extension SQLiteEventSnapshotStore {
    struct ObservedMessage: Equatable, Sendable {
        let rowID: Int64
        let messageID: MessageID
        let conversationID: ConversationID
        let isFromMe: Bool
        let deliveryState: DeliveryState
        let readState: ReadState
    }

    struct ObservedReaction: Equatable, Sendable {
        let rowID: Int64
        let messageID: MessageID
        let reactionID: MessageID
        let action: ReactionAction
    }

    struct MediaKey: Hashable, Sendable {
        let messageID: MessageID
        let mediaID: MediaID
    }

    struct ObservedMedia: Sendable {
        let key: MediaKey
        let path: String?
    }

    struct Snapshot: Sendable {
        let databaseIdentity: String
        let fileIdentity: String
        let dataVersion: Int64
        let messages: [MessageID: ObservedMessage]
        let reactions: [MessageID: ObservedReaction]
        let media: [MediaKey: ObservedMedia]
    }

    struct DatabaseState: Sendable {
        let fileIdentity: String
        let dataVersion: Int64
    }

    enum SnapshotResult: Sendable {
        case snapshot(Snapshot)
        case databaseChanged
    }

    static func events(
        from previous: Snapshot,
        to current: Snapshot,
        newlyAvailableMedia: Set<MediaKey>,
        observedAt: Timestamp
    ) -> [RelayEvent] {
        var values: [RelayEvent] = []
        let newMessages = current.messages.values
            .filter { previous.messages[$0.messageID] == nil }
            .sorted { $0.rowID < $1.rowID }
        values += newMessages.map {
            .messageCreated(MessageCreatedEvent(
                messageID: $0.messageID,
                conversationID: $0.conversationID,
                isFromMe: $0.isFromMe,
                observedAt: observedAt
            ))
        }

        let updatedMessages = current.messages.values
            .compactMap { currentValue -> (ObservedMessage, [MessageChangedField])? in
                guard let oldValue = previous.messages[currentValue.messageID] else { return nil }
                var fields: [MessageChangedField] = []
                if oldValue.deliveryState != currentValue.deliveryState { fields.append(.deliveryState) }
                if oldValue.readState != currentValue.readState { fields.append(.readState) }
                return fields.isEmpty ? nil : (currentValue, fields)
            }
            .sorted { $0.0.rowID < $1.0.rowID }
        values += updatedMessages.map {
            .messageUpdated(MessageUpdatedEvent(
                messageID: $0.0.messageID,
                conversationID: $0.0.conversationID,
                changedFields: $0.1,
                observedAt: observedAt
            ))
        }

        let newReactions = current.reactions.values
            .filter { previous.reactions[$0.reactionID] == nil }
            .sorted { $0.rowID < $1.rowID }
        values += newReactions.map {
            let payload = ReactionChangedEvent(
                messageID: $0.messageID,
                reactionID: $0.reactionID,
                observedAt: observedAt
            )
            return $0.action == .added ? .reactionAdded(payload) : .reactionRemoved(payload)
        }

        let availableMedia = newlyAvailableMedia.sorted {
            ($0.messageID.rawValue, $0.mediaID.rawValue)
                < ($1.messageID.rawValue, $1.mediaID.rawValue)
        }
        values += availableMedia.map {
            .mediaAvailable(MediaAvailableEvent(
                messageID: $0.messageID,
                mediaID: $0.mediaID,
                observedAt: observedAt
            ))
        }
        return values
    }
}
