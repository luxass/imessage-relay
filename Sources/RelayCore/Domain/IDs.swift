import Foundation

public enum IdentifierValidationError: Error, Equatable, Sendable {
    case empty
    case containsControlCharacter
}

private func validateIdentifier(_ value: String) throws -> String {
    guard !value.isEmpty else { throw IdentifierValidationError.empty }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw IdentifierValidationError.containsControlCharacter
    }
    return value
}

public protocol RelayIdentifier: Codable, Hashable, RawRepresentable, Sendable
where RawValue == String {
    init(validating value: String) throws
}

extension RelayIdentifier {
    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ConversationID: RelayIdentifier {
    public let rawValue: String
    public init(validating value: String) throws { rawValue = try validateIdentifier(value) }
    public init?(rawValue: String) { try? self.init(validating: rawValue) }
}

public struct MessageID: RelayIdentifier {
    public let rawValue: String
    public init(validating value: String) throws { rawValue = try validateIdentifier(value) }
    public init?(rawValue: String) { try? self.init(validating: rawValue) }
}

public struct SenderID: RelayIdentifier {
    public let rawValue: String
    public init(validating value: String) throws { rawValue = try validateIdentifier(value) }
    public init?(rawValue: String) { try? self.init(validating: rawValue) }
}

public struct MediaID: RelayIdentifier {
    public let rawValue: String
    public init(validating value: String) throws { rawValue = try validateIdentifier(value) }
    public init?(rawValue: String) { try? self.init(validating: rawValue) }
}

public struct RequestID: RelayIdentifier {
    public let rawValue: String
    public init(validating value: String) throws { rawValue = try validateIdentifier(value) }
    public init?(rawValue: String) { try? self.init(validating: rawValue) }

    public static func generate() -> Self {
        guard let id = Self(rawValue: UUID().uuidString.lowercased()) else {
            preconditionFailure("UUID generation produced an invalid request identifier.")
        }
        return id
    }
}

public struct Cursor: RelayIdentifier {
    public let rawValue: String
    public init(validating value: String) throws { rawValue = try validateIdentifier(value) }
    public init?(rawValue: String) { try? self.init(validating: rawValue) }
}
