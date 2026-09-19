import Foundation

public enum RelayJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder { JSONDecoder() }
}

public struct Timestamp: Codable, Equatable, Hashable, Sendable {
    public let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let date = Self.parse(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected an ISO 8601 timestamp."
            )
        }
        self.date = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.format(date))
    }

    private static func parse(_ value: String) -> Date? {
        formatter(options: [.withInternetDateTime, .withFractionalSeconds]).date(from: value)
            ?? formatter(options: [.withInternetDateTime]).date(from: value)
    }

    private static func format(_ date: Date) -> String {
        formatter(options: [.withInternetDateTime, .withFractionalSeconds]).string(from: date)
    }

    private static func formatter(
        options: ISO8601DateFormatter.Options
    ) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
