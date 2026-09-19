import Foundation
import Testing

@testable import RelayCore

@Test
func fakeSenderRecordsEveryDispatchField() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let mediaID = try MediaID(validating: "media-guid")
    let replyID = try MessageID(validating: "reply-guid")
    let requestID = try RequestID(validating: "request-guid")
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    let request = SenderDispatchRequest(
        requestID: requestID,
        destination: .conversation(conversationID),
        conversationContext: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: "sender@example.com",
            recipients: [recipient]
        ),
        text: "Hello",
        media: [OutboundMedia(
            reference: MediaReference(
                mediaID: mediaID,
                filename: "file.pdf",
                mimeType: "application/pdf",
                byteSize: 12,
                source: .upload
            ),
            fileURL: URL(fileURLWithPath: "/synthetic/file.pdf")
        )],
        replyTarget: ReplyTarget(messageID: replyID)
    )
    let acceptedID = try MessageID(validating: "accepted-guid")
    let sender = FakeMessageSender(
        sender: await FakeMessageSender.available().status(),
        outcome: .result(.init(messageID: acceptedID, status: .sent))
    )

    let result = try await sender.send(request)

    #expect(result == SenderDispatchResult(messageID: acceptedID, status: .sent))
    #expect(sender.requests == [request])
}

@Test
func macOSSenderStatusDoesNotRunAutomationAndReportsUnverifiedCapabilities() async throws {
    let runner = RecordingProcessRunner()
    let accessibility = RecordingAccessibilityPermissionChecker(trusted: false)
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        osascriptPath: "/usr/bin/osascript",
        processRunner: runner,
        accessibilityPermissionChecker: accessibility
    )

    let status = await sender.status()

    #expect(status.configured)
    #expect(status.availability == .permissionUnknown)
    #expect(status.capabilities.text == .permissionUnknown)
    #expect(status.capabilities.media == .unavailable)
    #expect(status.capabilities.nativeReply == .unavailable)
    #expect(status.capabilities.reactions == .unavailable)
    #expect(status.capabilities.groupCreation == .permissionUnknown)
    #expect(status.permissions.automation == .unknown)
    #expect(status.permissions.accessibility == .notGranted)
    #expect(await accessibility.calls == 1)
    #expect(await runner.calls == 0)
}

@Test
func macOSSenderReportsGrantedAccessibilityCapabilities() async throws {
    let accessibility = RecordingAccessibilityPermissionChecker(trusted: true)
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: accessibility
    )

    let status = await sender.status()

    #expect(status.permissions.accessibility == .granted)
    #expect(status.capabilities.media == .available)
    #expect(status.capabilities.nativeReply == .available)
    #expect(status.capabilities.reactions == .available)
    #expect(await accessibility.calls == 1)
}

@Test
func unconfiguredMacOSSenderFailsBeforeRunningAutomation() async throws {
    let runner = RecordingProcessRunner()
    let sender = MacOSMessageSender(
        configuredAccountID: nil,
        processRunner: runner,
        accessibilityPermissionChecker: RecordingAccessibilityPermissionChecker(trusted: false)
    )
    let status = await sender.status()

    #expect(!status.configured)
    #expect(status.availability == .unavailable)
    #expect(status.capabilities.text == .unavailable)
    #expect(status.capabilities.groupCreation == .unavailable)
    await #expect(throws: MessageSenderError.unavailable(
        "A direct send requires RELAY_SENDER_ACCOUNT_ID."
    )) {
        try await sender.send(SenderDispatchRequest(
            requestID: RequestID(validating: "request-guid"),
            destination: .recipient(RecipientHandle(type: .email, value: "friend@example.com")),
            conversationContext: nil,
            text: "Synthetic text",
            media: [],
            replyTarget: nil
        ))
    }
    #expect(await runner.calls == 0)
}

@Test
func macOSSenderPassesPlainTextToOneFixedScript() async throws {
    let runner = RecordingProcessRunner()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        osascriptPath: "/usr/bin/osascript",
        processRunner: runner,
        accessibilityPermissionChecker: RecordingAccessibilityPermissionChecker(trusted: false)
    )

    let result = try await sender.send(SenderDispatchRequest(
        requestID: RequestID(validating: "request-guid"),
        destination: .recipient(RecipientHandle(type: .email, value: "friend@example.com")),
        conversationContext: nil,
        text: "Synthetic text",
        media: [],
        replyTarget: nil
    ))

    #expect(result.status == .accepted)
    let call = try #require(await runner.recordedCalls.first)
    #expect(call.executablePath == "/usr/bin/osascript")
    #expect(call.arguments == [
        "-", "account-guid", "recipient", "friend@example.com", "Synthetic text",
    ])
    #expect(String(data: call.standardInput, encoding: .utf8)?.contains("on run arguments") == true)
}

@Test
func macOSSenderCreatesAGroupThroughTheConfiguredAccount() async throws {
    let runner = RecordingProcessRunner()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        osascriptPath: "/usr/bin/osascript",
        processRunner: runner,
        accessibilityPermissionChecker: RecordingAccessibilityPermissionChecker(trusted: false)
    )
    let participants = [
        try RecipientHandle(type: .email, value: "friend@example.com"),
        try RecipientHandle(type: .phone, value: "+1 500 555 0006"),
    ]

    let result = try await sender.send(SenderDispatchRequest(
        requestID: RequestID(validating: "group-request-guid"),
        destination: .participants(participants),
        conversationContext: nil,
        text: "Synthetic group text",
        media: [],
        replyTarget: nil
    ))

    #expect(result.status == .accepted)
    let call = try #require(await runner.recordedCalls.first)
    #expect(call.arguments == [
        "-", "account-guid", "Synthetic group text", "friend@example.com", "+15005550006",
    ])
    #expect(call.standardInput == Data(MacOSMessageSender.groupSendScript.utf8))
}

@Test
func macOSSenderRejectsMediaBeforeRunningAutomation() async throws {
    let runner = RecordingProcessRunner()
    let accessibility = RecordingAccessibilityPermissionChecker(trusted: false)
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        osascriptPath: "/usr/bin/osascript",
        processRunner: runner,
        accessibilityPermissionChecker: accessibility
    )
    let mediaID = try MediaID(validating: "upload-fixture")
    let conversationID = try ConversationID(validating: "any;-;friend@example.com")

    await #expect(throws: MessageSenderError.unavailable(
        "Grant Accessibility access to the relay process before sending replies or attachments."
    )) {
        try await sender.send(SenderDispatchRequest(
            requestID: RequestID(validating: "request-guid"),
            destination: .conversation(conversationID),
            conversationContext: ConversationSendContext(
                conversationID: conversationID,
                providerGUID: conversationID.rawValue,
                accountID: "account-guid",
                accountLogin: "sender@example.com",
                recipients: [RecipientHandle(type: .email, value: "friend@example.com")]
            ),
            conversationAnchorMessageID: MessageID(validating: "anchor-guid"),
            text: "Synthetic text",
            media: [OutboundMedia(
                reference: MediaReference(
                    mediaID: mediaID,
                    filename: "photo.jpg",
                    mimeType: "image/jpeg",
                    byteSize: 3,
                    source: .upload
                ),
                fileURL: URL(fileURLWithPath: "/synthetic/photo.jpg")
            )],
            replyTarget: nil
        ))
    }
    #expect(await runner.calls == 0)
    #expect(await accessibility.calls == 1)
}

@Test
func macOSSenderScriptCompilesWithoutRunningIt() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-applescript-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for (name, script) in [
        ("send", MacOSMessageSender.sendScript),
        ("group-send", MacOSMessageSender.groupSendScript),
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = [
            "-o", directory.appendingPathComponent("\(name).scpt").path,
            "-e", script,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }
}

private struct ProcessCall: Sendable {
    let executablePath: String
    let arguments: [String]
    let standardInput: Data
}

private actor RecordingProcessRunner: SendProcessRunning {
    private(set) var recordedCalls: [ProcessCall] = []
    var calls: Int { recordedCalls.count }

    func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data,
        timeout: Duration,
        terminationGrace: Duration
    ) async throws -> SendProcessResult {
        recordedCalls.append(ProcessCall(
            executablePath: executablePath,
            arguments: arguments,
            standardInput: standardInput
        ))
        return .exited(0)
    }
}

private actor RecordingAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    let trusted: Bool
    private(set) var calls = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool {
        calls += 1
        return trusted
    }
}
