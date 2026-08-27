import Foundation
import Darwin

struct SendRequest: Sendable {
    let chatID: Int64?
    let chatGuid: String?
    let to: String?
    let text: String
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

protocol MessageSending: Sendable {
    var capabilities: [String] { get }
    var isAvailable: Bool { get }
    func send(_ request: SendRequest) async throws -> SendResult
}

enum SendProcessResult: Equatable, Sendable {
    case launchFailed(String)
    case exited(Int32)
    case timedOut
    case failedToTerminate
}

protocol SendProcessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        terminationGrace: Duration
    ) async throws -> SendProcessResult
}

protocol SendProcess: Sendable {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func run() throws
    func terminate()
    func forceKill()
}

private final class FoundationProcess: SendProcess, @unchecked Sendable {
    private let process: Process

    init(executablePath: String, arguments: [String]) {
        process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }
    func run() throws { try process.run() }
    func terminate() { process.terminate() }
    func forceKill() { _ = kill(process.processIdentifier, SIGKILL) }
}

struct FoundationSendProcessRunner: SendProcessRunning {
    private let pollInterval: Duration = .milliseconds(10)
    private let makeProcess: @Sendable (String, [String]) -> any SendProcess

    init(makeProcess: @escaping @Sendable (String, [String]) -> any SendProcess = {
        FoundationProcess(executablePath: $0, arguments: $1)
    }) {
        self.makeProcess = makeProcess
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        terminationGrace: Duration
    ) async throws -> SendProcessResult {
        try Task.checkCancellation()
        let process = makeProcess(executablePath, arguments)
        try Task.checkCancellation()

        do {
            try process.run()
        } catch {
            return .launchFailed(String(describing: error))
        }

        do {
            if try await waitForExit(process, timeout: timeout) {
                return .exited(process.terminationStatus)
            }
        } catch is CancellationError {
            await stop(process, terminationGrace: terminationGrace)
            throw CancellationError()
        }

        process.terminate()
        if await waitForExitIgnoringCancellation(process, timeout: terminationGrace) {
            return .timedOut
        }

        process.forceKill()
        if await waitForExitIgnoringCancellation(process, timeout: terminationGrace) {
            return .timedOut
        }
        return .failedToTerminate
    }

    private func waitForExit(_ process: any SendProcess, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning && clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: min(pollInterval, clock.now.duration(to: deadline)))
        }
        try Task.checkCancellation()
        return !process.isRunning
    }

    private func waitForExitIgnoringCancellation(
        _ process: any SendProcess,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning && clock.now < deadline {
            let delay = min(pollInterval, clock.now.duration(to: deadline))
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        return !process.isRunning
    }

    private func stop(_ process: any SendProcess, terminationGrace: Duration) async {
        guard process.isRunning else { return }
        process.terminate()
        if await waitForExitIgnoringCancellation(process, timeout: terminationGrace) { return }
        process.forceKill()
        _ = await waitForExitIgnoringCancellation(process, timeout: terminationGrace)
    }
}

struct MessageSender: MessageSending {
    let timeout: Duration

    private let osascriptPath: String
    private let terminationGrace: Duration
    private let processRunner: any SendProcessRunning

    init(
        timeout: Duration = .seconds(30),
        terminationGrace: Duration = .seconds(1),
        osascriptPath: String = "/usr/bin/osascript",
        processRunner: any SendProcessRunning = FoundationSendProcessRunner()
    ) {
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.osascriptPath = osascriptPath
        self.processRunner = processRunner
    }

    var capabilities: [String] { ["text"] }
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: osascriptPath) }

    func send(_ request: SendRequest) async throws -> SendResult {
        let script: String
        if let chatGuid = request.chatGuid {
            script = Self.chatSendScript(chatGuid: chatGuid, text: request.text)
        } else if let to = request.to {
            script = Self.directSendScript(handle: to, text: request.text)
        } else if let chatID = request.chatID {
            throw SenderError.unavailable("chat_id \(chatID) was not resolved to a chat_guid before dispatch.")
        } else {
            throw SenderError.unavailable("No destination provided.")
        }

        let result = try await processRunner.run(
            executablePath: osascriptPath,
            arguments: ["-e", script],
            timeout: timeout,
            terminationGrace: terminationGrace
        )
        switch result {
        case .exited(0):
            return SendResult(ok: true, guid: nil)
        case .launchFailed(let detail):
            throw SenderError.notStarted(detail: "Could not launch osascript. \(detail)")
        case .exited(let exitCode):
            throw SenderError.uncertain(detail: "osascript exited \(exitCode).")
        case .timedOut:
            throw SenderError.uncertain(detail: "osascript exceeded the send deadline and was terminated.")
        case .failedToTerminate:
            throw SenderError.uncertain(detail: "osascript did not stop after forced termination.")
        }
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

}
