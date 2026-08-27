import Foundation

/// Sends through Messages.app's AppleScript surface — the same transport imsg
/// and BlueBubbles use in practice on stock macOS.
///
/// Requires Automation → Messages permission (TCC prompts on first send).
/// Limitations: text only (attachment sends are rejected), no delivery GUID
/// observation, and a hang (e.g. Messages showing a sign-in dialog) is cut off
/// at `timeout` seconds.
public struct AppleScriptSender: MessageSender {
    public let timeout: TimeInterval

    /// osascript binary path; injectable for testing.
    private let osascriptPath: String

    public init(timeout: TimeInterval = 30, osascriptPath: String = "/usr/bin/osascript") {
        self.timeout = timeout
        self.osascriptPath = osascriptPath
    }

    public var capabilities: [String] { ["text"] }

    public func send(_ request: SendRequest) async throws -> SendResult {
        guard let text = request.text, !text.isEmpty else {
            throw SenderError.unavailable("AppleScriptSender supports text only; file sends are not implemented.")
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
            // AppleScript errors happen before dispatch in practice, so this
            // is treated as retry-safe (not_started disposition).
            throw SenderError.notStarted(detail: "osascript exited \(exitCode). " +
                "If this is the first send from this process, approve the Automation → Messages prompt.")
        }
        return SendResult(ok: true, guid: nil)
    }

    // MARK: - Script building

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

    /// Escapes a value for embedding in an AppleScript double-quoted string.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Process execution

    private func runOscript(_ script: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()

        // Cut the process loose if Messages blocks in a dialog.
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
