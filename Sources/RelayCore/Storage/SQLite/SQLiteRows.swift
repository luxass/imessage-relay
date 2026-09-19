import Foundation
import SQLite3

struct ConversationRow: Sendable {
    let rowID: Int64
    let guid: String
    let identifier: String?
    let displayName: String?
    let service: String?
    let roomName: String?
    let accountID: String?
    let accountLogin: String?
    let lastDate: SQLiteNumber?
    let unreadCount: Int
}

struct MessageRow: Sendable {
    let rowID: Int64
    let guid: String
    let conversationGUID: String
    let text: String?
    let attributedBody: Data?
    let handle: String?
    let originalHandle: String?
    let isFromMe: Bool
    let date: SQLiteNumber?
    let error: Int64?
    let isSent: Bool?
    let isDelivered: Bool?
    let isRead: Bool?
    let dateDelivered: SQLiteNumber?
    let dateRead: SQLiteNumber?
    let replyToGUID: String?
    let threadOriginatorGUID: String?
    let partCount: Int64?
}

private struct AttributedPart {
    let index: Int
    var text: String?
    var attachmentGUID: String?
}

enum SQLiteRows {
    static func timestamp(_ value: SQLiteNumber?) -> Timestamp? {
        guard let raw = value?.doubleValue, raw > 0 else { return nil }
        let seconds = abs(raw) > 10_000_000_000 ? raw / 1_000_000_000 : raw
        return Timestamp(Date(timeIntervalSinceReferenceDate: seconds))
    }

    static func bool(_ statement: OpaquePointer, _ index: Int32) -> Bool? {
        SQLiteValue.optionalInt64(statement, index).map { $0 != 0 }
    }

    static func attributedText(_ data: Data?) -> String? {
        guard let attributed = attributedString(data) else { return nil }
        let text = attributed.string
            .replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func messageParts(
        _ row: MessageRow,
        attachmentsByGUID: [String: MediaReference] = [:],
        attachmentsLoaded: Bool = false
    ) -> [MessagePart]? {
        if let attributed = attributedParts(row.attributedBody), !attributed.isEmpty {
            var mapped = Dictionary(uniqueKeysWithValues: attributed.map { part in
                let value: MessagePart
                if let guid = part.attachmentGUID {
                    value = .attachment(index: part.index, attachment: attachmentsByGUID[guid])
                } else if let text = part.text, !text.isEmpty {
                    value = .text(index: part.index, text: text)
                } else {
                    value = .unknown(index: part.index)
                }
                return (part.index, value)
            })
            if let count = validPartCount(row.partCount),
               mapped.keys.allSatisfy({ $0 < count }) {
                for index in 0..<count where mapped[index] == nil {
                    mapped[index] = .unknown(index: index)
                }
            }
            return mapped.keys.sorted().compactMap { mapped[$0] }
        }

        let text = row.text ?? attributedText(row.attributedBody)
        if let text, validPartCount(row.partCount) == 1 {
            return [.text(index: 0, text: text)]
        }
        if text == nil, validPartCount(row.partCount) == 0 { return [] }
        if validPartCount(row.partCount) == 1, attachmentsLoaded {
            guard attachmentsByGUID.count == 1, let attachment = attachmentsByGUID.values.first else {
                return [.unknown(index: 0)]
            }
            return [.attachment(index: 0, attachment: attachment)]
        }
        return nil
    }

    private static func validPartCount(_ value: Int64?) -> Int? {
        guard let value, value >= 0, value <= Int.max else { return nil }
        return Int(value)
    }

    private static func attributedString(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }

        // Messages stores attributedBody as a legacy typedstream archive. NSKeyedUnarchiver
        // cannot decode that format, so invoke the deprecated Foundation decoder dynamically.
        let selector = NSSelectorFromString("unarchiveObjectWithData:")
        guard let unarchiver = NSClassFromString("NSUnarchiver") as? NSObject.Type,
              unarchiver.responds(to: selector),
              let result = unarchiver.perform(selector, with: data) else {
            return nil
        }
        return result.takeUnretainedValue() as? NSAttributedString
    }

    private static func attributedParts(_ data: Data?) -> [AttributedPart]? {
        guard let attributed = attributedString(data) else { return nil }
        let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")
        let transferKey = NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
        var parts: [Int: AttributedPart] = [:]
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            guard let index = partIndex(attributes[partKey]), index >= 0 else { return }
            let raw = (attributed.string as NSString).substring(with: range)
            let text = raw.replacingOccurrences(of: "\u{fffc}", with: "")
            let transferGUID = attributes[transferKey] as? String
            var part = parts[index] ?? AttributedPart(index: index, text: nil, attachmentGUID: nil)
            if !text.isEmpty { part.text = (part.text ?? "") + text }
            if let transferGUID, !transferGUID.isEmpty { part.attachmentGUID = transferGUID }
            parts[index] = part
        }
        return parts.keys.sorted().compactMap { parts[$0] }
    }

    private static func partIndex(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func handle(value: String?, original: String?) -> RecipientHandle? {
        guard let value, !value.isEmpty else { return nil }
        return try? RecipientHandle.stored(value: value, originalValue: original)
    }

    static func message(_ row: MessageRow) throws -> Message {
        let messageID = try MessageID(validating: row.guid)
        let conversationID = try ConversationID(validating: row.conversationGUID)
        let thread: ThreadReference?
        let root = try row.threadOriginatorGUID.map(MessageID.init(validating:))
        if let root {
            thread = ThreadReference(
                replyToMessageID: nil,
                threadOriginatorMessageID: root
            )
        } else {
            thread = nil
        }
        return Message(
            id: messageID,
            providerGUID: row.guid,
            conversationID: conversationID,
            text: row.text ?? attributedText(row.attributedBody),
            sender: handle(value: row.handle, original: row.originalHandle),
            isFromMe: row.isFromMe,
            createdAt: timestamp(row.date),
            deliveryState: deliveryState(row),
            readState: readState(row),
            deliveredAt: row.isFromMe ? timestamp(row.dateDelivered) : nil,
            readAt: row.isFromMe ? timestamp(row.dateRead) : nil,
            thread: thread,
            parts: messageParts(row),
            reactions: [],
            attachments: []
        )
    }

    static func deliveryState(_ row: MessageRow) -> DeliveryState {
        if row.error.map({ $0 != 0 }) == true { return .failed }
        if row.isDelivered == true { return .delivered }
        if row.isSent == true { return .sent }
        if row.isFromMe { return .notSent }
        return .unknown
    }

    static func readState(_ row: MessageRow) -> ReadState {
        guard let isRead = row.isRead else { return .unknown }
        return isRead || timestamp(row.dateRead) != nil ? .read : .unread
    }
}
