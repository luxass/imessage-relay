import Foundation

/// Abstraction over whatever transport actually delivers messages.
///
/// v1 ships with `UnimplementedSender`; candidates for the real transport are:
/// - AppleScript via Messages.app (works on stock macOS, needs Automation TCC)
/// - Delegating to the `imsg` CLI's send surface
/// - IMCore injection (requires SIP off)
public protocol MessageSender: Sendable {
    /// Feature strings advertised through GET /status so clients can
    /// degrade gracefully instead of guessing.
    var capabilities: [String] { get }

    func send(_ request: SendRequest) async throws -> SendResult
}

public struct SendRequest: Sendable {
    /// Exactly one of these identifies the destination.
    /// `chatGuid` takes precedence over `chatID`.
    public var chatID: Int64?
    public var chatGuid: String?
    public var to: String?

    public var text: String?
    /// Local file path to send as an attachment.
    public var file: String?
    /// "imessage", "sms", or nil for auto.
    public var service: String?

    public init(
        chatID: Int64? = nil,
        chatGuid: String? = nil,
        to: String? = nil,
        text: String? = nil,
        file: String? = nil,
        service: String? = nil
    ) {
        self.chatID = chatID
        self.chatGuid = chatGuid
        self.to = to
        self.text = text
        self.file = file
        self.service = service
    }
}

public struct SendResult: Encodable, Sendable {
    public var ok: Bool
    /// Best-effort message GUID when the outgoing row could be observed.
    public var guid: String?

    public init(ok: Bool, guid: String? = nil) {
        self.ok = ok
        self.guid = guid
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        if let guid {
            try c.encode(guid, forKey: .guid)
        }
    }

    private enum CodingKeys: String, CodingKey { case ok, guid }
}

public enum SenderError: Error, CustomStringConvertible {
    /// No transport configured or capability missing. Safe to report as 501.
    case unavailable(String)
    /// Transport could not prove whether delivery happened. Callers must not
    /// auto-retry (`may_have_completed` disposition from imsg semantics).
    case uncertain(detail: String)
    /// Transport proved it never dispatched. Retry is safe.
    case notStarted(detail: String)

    public var description: String {
        switch self {
        case .unavailable(let detail): return detail
        case .uncertain(let detail): return "Send may have completed; do not retry blindly. \(detail)"
        case .notStarted(let detail): return "Send was never started (retry safe). \(detail)"
        }
    }
}

public struct UnimplementedSender: MessageSender {
    public init() {}

    public var capabilities: [String] { [] }

    public func send(_ request: SendRequest) async throws -> SendResult {
        throw SenderError.unavailable(
            "No sender transport configured yet. POST /send returns 501 until one is chosen."
        )
    }
}
