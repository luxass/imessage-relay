import Darwin
import Foundation

public enum SendProcessResult: Equatable, Sendable {
    case launchFailed(String)
    case inputFailed(String)
    case exited(Int32)
    case timedOut
    case failedToTerminate
}

public protocol SendProcessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data,
        timeout: Duration,
        terminationGrace: Duration
    ) async throws -> SendProcessResult
}

public struct FoundationSendProcessRunner: SendProcessRunning {
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data,
        timeout: Duration,
        terminationGrace: Duration
    ) async throws -> SendProcessResult {
        try Task.checkCancellation()
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .launchFailed(String(describing: error))
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: standardInput)
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            return .inputFailed(String(describing: error))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while process.isRunning && clock.now < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: min(.milliseconds(10), clock.now.duration(to: deadline)))
            }
        } catch {
            await stop(process, grace: terminationGrace)
            throw error
        }
        guard process.isRunning else { return .exited(process.terminationStatus) }
        process.terminate()
        let graceDeadline = clock.now.advanced(by: terminationGrace)
        while process.isRunning && clock.now < graceDeadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        let killDeadline = clock.now.advanced(by: terminationGrace)
        while process.isRunning && clock.now < killDeadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        return process.isRunning ? .failedToTerminate : .timedOut
    }

    private func stop(_ process: Process, grace: Duration) async {
        guard process.isRunning else { return }
        process.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        while process.isRunning && clock.now < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
}

public struct MacOSMessageSender: MessageSender, MessageReactionWriting {
    private struct SendTarget {
        let accountID: String
        let kind: String
        let identifier: String
    }

    private let configuredAccountID: String?
    private let osascriptPath: String
    private let timeout: Duration
    private let processRunner: any SendProcessRunning
    private let accessibilityPermissionChecker: any AccessibilityPermissionChecking
    private let accessibilityDriver: any AccessibilityMessagesDriving
    private let accessibilityQueue: AccessibilityOperationQueue

    public init(
        configuredAccountID: String?,
        osascriptPath: String = "/usr/bin/osascript",
        timeout: Duration = .seconds(30),
        processRunner: any SendProcessRunning = FoundationSendProcessRunner(),
        accessibilityPermissionChecker: any AccessibilityPermissionChecking =
            MacOSAccessibilityPermissionChecker(),
        accessibilityDriver: any AccessibilityMessagesDriving =
            MacOSAccessibilityMessagesDriver(),
        accessibilityQueue: AccessibilityOperationQueue = AccessibilityOperationQueue()
    ) {
        let trimmedAccountID = configuredAccountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredAccountID = trimmedAccountID?.isEmpty == false ? trimmedAccountID : nil
        self.osascriptPath = osascriptPath
        self.timeout = timeout
        self.processRunner = processRunner
        self.accessibilityPermissionChecker = accessibilityPermissionChecker
        self.accessibilityDriver = accessibilityDriver
        self.accessibilityQueue = accessibilityQueue
    }

    public func status() async -> Sender {
        guard let senderID = SenderID(rawValue: "local-imessage-sender") else {
            preconditionFailure("The built-in local sender identifier is invalid.")
        }
        let executable = FileManager.default.isExecutableFile(atPath: osascriptPath)
        let configured = configuredAccountID != nil
        let accessibilityTrusted = await accessibilityPermissionChecker.isTrusted()
        let textAvailability: SenderAvailability
        let textReason: String?
        let text: CapabilityAvailability
        if !executable {
            textAvailability = .unavailable
            textReason = "The osascript executable is unavailable."
            text = .unavailable
        } else if !configured {
            textAvailability = .unavailable
            textReason = "Configure RELAY_SENDER_ACCOUNT_ID before direct sends."
            text = .unavailable
        } else {
            textAvailability = .permissionUnknown
            textReason = "Automation permission is not probed by status requests."
            text = .permissionUnknown
        }
        let accessibilityReason = accessibilityTrusted
            ? nil
            : "Grant Accessibility access to send replies, attachments, or reactions."
        return Sender(
            id: senderID,
            accountIdentity: configuredAccountID,
            login: nil,
            configured: configured,
            availability: accessibilityTrusted ? .available : textAvailability,
            reason: [textReason, accessibilityReason].compactMap { $0 }.joined(separator: " "),
            permissions: SenderPermissions(
                automation: .unknown,
                accessibility: accessibilityTrusted ? .granted : .notGranted
            ),
            capabilities: SenderCapabilities(
                text: text,
                media: accessibilityTrusted ? .available : .unavailable,
                nativeReply: accessibilityTrusted ? .available : .unavailable,
                reactions: accessibilityTrusted ? .available : .unavailable,
                groupCreation: text
            )
        )
    }

    public func send(_ request: SenderDispatchRequest) async throws -> SenderDispatchResult {
        if case .participants = request.destination {
            return try await sendGroupWithAppleScript(request)
        }
        if request.replyTarget != nil || !request.media.isEmpty {
            return try await sendWithAccessibility(request)
        }
        return try await sendWithAppleScript(request)
    }

    public func setReaction(_ request: ReactionDispatchRequest) async throws {
        guard await accessibilityPermissionChecker.isTrusted() else {
            throw MessageSenderError.unavailable(
                "Grant Accessibility access before changing reactions."
            )
        }
        try await accessibilityQueue.run {
            try await accessibilityDriver.setReaction(AccessibilityReactionRequest(
                conversationGUID: request.conversationGUID,
                messageGUID: request.messageGUID,
                useOverlay: request.useOverlay,
                reaction: request.reaction,
                enabled: request.enabled
            ))
        }
    }

    private func sendWithAppleScript(
        _ request: SenderDispatchRequest
    ) async throws -> SenderDispatchResult {
        try validateAppleScript(request)
        let target = try sendTarget(request)
        let arguments = ["-", target.accountID, target.kind, target.identifier, request.text ?? ""]

        let result = try await processRunner.run(
            executablePath: osascriptPath,
            arguments: arguments,
            standardInput: Data(Self.sendScript.utf8),
            timeout: timeout,
            terminationGrace: .seconds(1)
        )
        return try Self.dispatchResult(result)
    }

    private func sendGroupWithAppleScript(
        _ request: SenderDispatchRequest
    ) async throws -> SenderDispatchResult {
        guard case .participants(let participants) = request.destination,
              participants.count >= 2 else {
            throw MessageSenderError.notStarted("A group send requires at least two participants.")
        }
        guard request.text?.isEmpty == false else {
            throw MessageSenderError.notStarted("A group send requires initial text.")
        }
        guard request.media.isEmpty, request.replyTarget == nil else {
            throw MessageSenderError.unsupported(
                "Initial group attachments and replies are unsupported."
            )
        }
        guard FileManager.default.isExecutableFile(atPath: osascriptPath) else {
            throw MessageSenderError.unavailable("The osascript executable is unavailable.")
        }
        guard let configuredAccountID else {
            throw MessageSenderError.unavailable(
                "A group send requires RELAY_SENDER_ACCOUNT_ID."
            )
        }
        let arguments = ["-", configuredAccountID, request.text ?? ""]
            + participants.map(\.value)
        let result = try await processRunner.run(
            executablePath: osascriptPath,
            arguments: arguments,
            standardInput: Data(Self.groupSendScript.utf8),
            timeout: timeout,
            terminationGrace: .seconds(1)
        )
        return try Self.dispatchResult(result)
    }

    private func validateAppleScript(_ request: SenderDispatchRequest) throws {
        guard request.text?.isEmpty == false else {
            throw MessageSenderError.notStarted("The AppleScript sender requires text.")
        }
        guard FileManager.default.isExecutableFile(atPath: osascriptPath) else {
            throw MessageSenderError.unavailable("The osascript executable is unavailable.")
        }
    }

    private func sendWithAccessibility(
        _ request: SenderDispatchRequest
    ) async throws -> SenderDispatchResult {
        guard case .conversation = request.destination else {
            throw MessageSenderError.unsupported(
                "Replies and attachments require an existing conversation."
            )
        }
        guard let context = request.conversationContext else {
            throw MessageSenderError.notStarted(
                "The conversation context is missing from the Accessibility send."
            )
        }
        if !request.media.isEmpty,
           request.replyTarget == nil,
           request.conversationAnchorMessageID == nil {
            throw MessageSenderError.notStarted(
                "A media send requires a stable message anchor in the conversation."
            )
        }
        guard await accessibilityPermissionChecker.isTrusted() else {
            throw MessageSenderError.unavailable(
                "Grant Accessibility access to the relay process before sending replies or attachments."
            )
        }

        let operation = AccessibilitySendRequest(
            conversationGUID: context.providerGUID,
            conversationAnchorMessageGUID: request.replyTarget == nil
                ? request.conversationAnchorMessageID?.rawValue
                : nil,
            text: request.text,
            mediaURLs: request.media.map(\.fileURL),
            replyMessageGUID: request.replyContext?.messageID.rawValue
                ?? request.replyTarget?.messageID.rawValue,
            replyThreadOriginatorGUID: request.replyContext?.threadOriginatorMessageID?.rawValue
        )
        try await accessibilityQueue.run {
            try await accessibilityDriver.send(operation)
        }
        return SenderDispatchResult(messageID: nil, status: .accepted)
    }

    private func sendTarget(_ request: SenderDispatchRequest) throws -> SendTarget {
        switch request.destination {
        case .conversation:
            guard let context = request.conversationContext,
                  let conversationAccount = context.accountID else {
                throw MessageSenderError.unavailable("The conversation has no local iMessage account identifier.")
            }
            return SendTarget(
                accountID: conversationAccount,
                kind: "chat",
                identifier: context.providerGUID
            )
        case .recipient(let handle):
            guard let configuredAccountID else {
                throw MessageSenderError.unavailable("A direct send requires RELAY_SENDER_ACCOUNT_ID.")
            }
            return SendTarget(
                accountID: configuredAccountID,
                kind: "recipient",
                identifier: handle.value
            )
        case .participants:
            throw MessageSenderError.notStarted(
                "A group destination must use the group AppleScript path."
            )
        }
    }

    private static func dispatchResult(_ result: SendProcessResult) throws -> SenderDispatchResult {
        switch result {
        case .exited(0): return SenderDispatchResult(messageID: nil, status: .accepted)
        case .launchFailed(let detail):
            throw MessageSenderError.notStarted("Could not launch osascript. \(detail)")
        case .inputFailed(let detail):
            throw MessageSenderError.uncertain("Could not pass the send command to osascript. \(detail)")
        case .exited(let code):
            throw MessageSenderError.uncertain("osascript exited with status \(code).")
        case .timedOut:
            throw MessageSenderError.uncertain("osascript exceeded the send deadline and was terminated.")
        case .failedToTerminate:
            throw MessageSenderError.uncertain("osascript did not stop after forced termination.")
        }
    }

    static let sendScript =
        """
        on run arguments
            set configuredAccountID to item 1 of arguments
            set targetKind to item 2 of arguments
            set targetIdentifier to item 3 of arguments
            set messageText to item 4 of arguments

            tell application "Messages"
                set targetAccount to first account whose id is configuredAccountID
                if service type of targetAccount is not iMessage then error "Selected account is not iMessage."
                if enabled of targetAccount is false then error "Selected account is disabled."

                if targetKind is "chat" then
                    set sendTarget to first chat of targetAccount whose id is targetIdentifier
                else
                    set sendTarget to participant targetIdentifier of targetAccount
                end if

                send messageText to sendTarget
            end tell
        end run
        """

    static let groupSendScript =
        """
        on run arguments
            set configuredAccountID to item 1 of arguments
            set messageText to item 2 of arguments
            set participantHandles to items 3 thru -1 of arguments

            tell application "Messages"
                set targetAccount to first account whose id is configuredAccountID
                if service type of targetAccount is not iMessage then error "Selected account is not iMessage."
                if enabled of targetAccount is false then error "Selected account is disabled."

                set targetParticipants to {}
                repeat with participantHandle in participantHandles
                    set end of targetParticipants to participant (contents of participantHandle) of targetAccount
                end repeat
                set targetChat to make new chat at targetAccount with properties {participants:targetParticipants}
                send messageText to targetChat
            end tell
        end run
        """
}
