import Foundation

public enum RecipientHandleType: String, Codable, Equatable, Hashable, Sendable {
    case phone
    case email
    case other
}

public struct RecipientHandle: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case invalidPhone
        case invalidEmail
        case invalidOther
    }

    public let type: RecipientHandleType
    public let value: String
    public let displayValue: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case displayValue = "display_value"
    }

    public init(type: RecipientHandleType, value: String, displayValue: String? = nil) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        let normalized: String
        switch type {
        case .phone:
            normalized = try Self.normalizePhone(trimmed)
        case .email:
            normalized = try Self.normalizeEmail(trimmed)
        case .other:
            guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ValidationError.invalidOther
            }
            normalized = trimmed
        }

        self.type = type
        self.value = normalized
        let preferredDisplay = displayValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayValue = preferredDisplay.flatMap { $0.isEmpty ? nil : $0 }
            ?? (trimmed == normalized ? nil : trimmed)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: container.decode(RecipientHandleType.self, forKey: .type),
            value: container.decode(String.self, forKey: .value),
            displayValue: container.decodeIfPresent(String.self, forKey: .displayValue)
        )
    }

    public func matches(_ other: RecipientHandle) -> Bool {
        type == other.type && value == other.value
    }

    public static func stored(value: String, originalValue: String? = nil) throws -> Self {
        let type: RecipientHandleType
        if (try? normalizePhone(value)) != nil {
            type = .phone
        } else if (try? normalizeEmail(value)) != nil {
            type = .email
        } else {
            type = .other
        }
        return try Self(type: type, value: value, displayValue: originalValue)
    }

    public static func direct(value: String) throws -> Self {
        if let phone = try? Self(type: .phone, value: value) {
            return phone
        }
        if let email = try? Self(type: .email, value: value) {
            return email
        }
        throw ValidationError.invalidOther
    }

    public static func resolvable(value: String) throws -> Self {
        if let direct = try? direct(value: value) { return direct }
        return try Self(type: .other, value: value)
    }

    private static func normalizePhone(_ value: String) throws -> String {
        let removable = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "()-.")
        )
        let scalars = value.unicodeScalars.filter { !removable.contains($0) }
        let normalized = String(String.UnicodeScalarView(scalars))
        let digits = normalized.hasPrefix("+") ? String(normalized.dropFirst()) : normalized
        guard (3...15).contains(digits.count),
              digits.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) else {
            throw ValidationError.invalidPhone
        }
        return normalized
    }

    private static func normalizeEmail(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        }) else {
            throw ValidationError.invalidEmail
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].contains(".") else {
            throw ValidationError.invalidEmail
        }
        return value.lowercased()
    }
}

public enum MessageDestination: Codable, Equatable, Sendable {
    case conversation(ConversationID)
    case recipient(RecipientHandle)
    case participants([RecipientHandle])

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case to
        case participants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let conversation = try container.decodeIfPresent(ConversationID.self, forKey: .conversationID)
        let recipient = try container.decodeIfPresent(RecipientHandle.self, forKey: .to)
        let participants = try container.decodeIfPresent([RecipientHandle].self, forKey: .participants)
        switch (conversation, recipient, participants) {
        case let (.some(id), .none, .none): self = .conversation(id)
        case let (.none, .some(handle), .none): self = .recipient(handle)
        case let (.none, .none, .some(handles)): self = .participants(handles)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .conversationID,
                in: container,
                debugDescription: "Provide exactly one of conversation_id or to."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conversation(let id): try container.encode(id, forKey: .conversationID)
        case .recipient(let handle): try container.encode(handle, forKey: .to)
        case .participants(let handles): try container.encode(handles, forKey: .participants)
        }
    }
}
