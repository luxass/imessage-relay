import Foundation

struct SendRequest: Sendable {
    let chatID: Int64?
    let chatGuid: String?
    let to: String?
    let text: String?
    let file: String?
    let service: String?
}

struct SendResult: Encodable, Sendable {
    let ok: Bool
    let guid: String?
}

enum SenderError: Error, CustomStringConvertible {
    case unavailable(String)
    case uncertain(detail: String)
    case notStarted(detail: String)

    var description: String {
        switch self {
        case .unavailable(let detail): detail
        case .uncertain(let detail): "Send may have completed; do not retry blindly. \(detail)"
        case .notStarted(let detail): "Send was never started (retry safe). \(detail)"
        }
    }
}

struct MessageSender: Sendable {
    let timeout: TimeInterval

    private let osascriptPath: String

    init(timeout: TimeInterval = 30, osascriptPath: String = "/usr/bin/osascript") {
        self.timeout = timeout
        self.osascriptPath = osascriptPath
    }

    var capabilities: [String] { ["text"] }

    func send(_ request: SendRequest) async throws -> SendResult {
        guard let text = request.text, !text.isEmpty else {
            throw SenderError.unavailable("Only text sends are supported; file sends are not implemented.")
        }

        let script: String
        if let chatGuid = request.chatGuid {
            script = Self.chatSendScript(chatGuid: chatGuid, text: text)
        } else if let to = request.to {
            script = Self.directSendScript(handle: to, text: text)
        } else if let chatID = request.chatID {
            throw SenderError.unavailable("chat_id \(chatID) was not resolved to a chat_guid before dispatch.")
        } else {
            throw SenderError.unavailable("No destination provided.")
        }

        let exitCode = try await runOscript(script)
        guard exitCode == 0 else {
            throw SenderError.notStarted(detail: "osascript exited \(exitCode). " +
                "If this is the first send from this process, approve the Automation > Messages prompt.")
        }
        return SendResult(ok: true, guid: nil)
    }

    static func directSendScript(handle: String, text: String) -> String {
        """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetParticipant to participant "\(escape(handle))" of targetService
            send "\(escape(text))" to targetParticipant
        end tell
        """
    }

    static func chatSendScript(chatGuid: String, text: String) -> String {
        """
        tell application "Messages"
            send "\(escape(text))" to chat id "\(escape(chatGuid))"
        end tell
        """
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runOscript(_ script: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()

        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning {
                process.terminate()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        return process.terminationStatus
    }
}
