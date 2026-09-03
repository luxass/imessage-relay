import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import RelayCore
import Testing

@testable import relay_server

@Test("status reports synthetic database and fake sender")
func statusSuccess() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/status", method: .get)
        #expect(response.status == .ok)
        expectJSONContentType(response)
        let body = try jsonObject(response.body)
        #expect(value(body, at: "version") as? String == "0.1.0")
        #expect(value(body, at: "database", "ready") as? Bool == true)
        #expect(value(body, at: "database", "path") == nil)
        #expect(value(body, at: "database", "error") == nil)
        #expect(value(body, at: "sender", "available") as? Bool == true)
        #expect(value(body, at: "sender", "capabilities") as? [String] == ["text"])
        #expect(value(body, at: "sender", "automation_permission") as? String == "unknown")
    }
}

@Test("status checks sender executable readiness without launching it")
func statusSenderReadiness() async throws {
    let fixture = try ServerDatabaseFixture()
    let runner = FakeSendProcessRunner(result: .exited(0))

    for (path, expectedAvailability) in [
        ("/usr/bin/true", true),
        ("/synthetic/missing/osascript", false),
    ] {
        let sender = MessageSender(osascriptPath: path, processRunner: runner)
        let app = makeTestApplication(databasePath: fixture.path, sender: sender)
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/status", method: .get)
            let body = try jsonObject(response.body)
            #expect(value(body, at: "sender", "available") as? Bool == expectedAvailability)
            #expect(value(body, at: "sender", "capabilities") as? [String] == ["text"])
            #expect(value(body, at: "sender", "automation_permission") as? String == "unknown")
        }
    }

    #expect(runner.invocations.isEmpty)
}

@Test("status exposes an unavailable synthetic database without failing")
func statusUnavailableDatabase() async throws {
    let missingPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)/chat.db").path
    let app = makeTestApplication(databasePath: missingPath)

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/status", method: .get)
        #expect(response.status == .ok)
        expectJSONContentType(response)
        let body = try jsonObject(response.body)
        #expect(value(body, at: "database", "ready") as? Bool == false)
        #expect(value(body, at: "database", "path") == nil)
        #expect(value(body, at: "database", "error") == nil)
        let responseText = try #require(String(bytes: response.body.readableBytesView, encoding: .utf8))
        #expect(!responseText.contains(missingPath))
    }
}

@Test("chat routes encode fixture data")
func chatRouteSuccesses() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        let chats = try await client.execute(uri: "/chats?limit=1", method: .get)
        #expect(chats.status == .ok)
        expectJSONContentType(chats)
        let chatBody = try #require(try jsonObject(chats.body)["items"] as? [[String: Any]])
        #expect(chatBody.count == 1)
        #expect(chatBody.first?["id"] as? Int == 1)

        let detail = try await client.execute(uri: "/chats/1", method: .get)
        #expect(detail.status == .ok)
        #expect(try jsonObject(detail.body)["id"] as? Int == 1)

        let messages = try await client.execute(
            uri: "/chats/1/messages?attachments=true",
            method: .get
        )
        #expect(messages.status == .ok)
        expectJSONContentType(messages)
        let messageBody = try #require(try jsonObject(messages.body)["items"] as? [[String: Any]])
        #expect(messageBody.first?["text"] as? String == "hello fixture")
        #expect((messageBody.first?["attachments"] as? [[String: Any]])?.count == 1)
        let attachment = try #require((messageBody.first?["attachments"] as? [[String: Any]])?.first)
        #expect(attachment["filename"] == nil)
        #expect(attachment["original_path"] == nil)
        let responseText = try #require(String(bytes: messages.body.readableBytesView, encoding: .utf8))
        #expect(!responseText.contains(fixture.path))
    }
}

@Test("chat routes reject malformed query and path input")
func chatRouteErrors() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        let chats = try await client.execute(uri: "/chats?unread_only=invalid", method: .get)
        try expectJSONError(
            chats,
            status: .badRequest,
            message: "Type mismatch for `` key, expected `Bool` type."
        )

        let messages = try await client.execute(uri: "/chats/0/messages", method: .get)
        try expectJSONError(
            messages,
            status: .badRequest,
            message: "path parameter :id must be a positive integer chat rowid"
        )

        let missing = try await client.execute(uri: "/chats/999", method: .get)
        try expectJSONError(missing, status: .notFound, message: "chat not found")

        let missingMessages = try await client.execute(uri: "/chats/999/messages", method: .get)
        try expectJSONError(missingMessages, status: .notFound, message: "chat not found")
    }
}

@Test("chat message search is scoped and global search is absent")
func messageRouteSearch() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        let search = try await client.execute(uri: "/chats/1/messages?q=fixture", method: .get)
        #expect(search.status == .ok)
        expectJSONContentType(search)
        let items = try #require(try jsonObject(search.body)["items"] as? [[String: Any]])
        #expect(items.first?["id"] as? Int == 100)

        let global = try await client.execute(uri: "/messages/search?q=fixture", method: .get)
        #expect(global.status == .notFound)
    }
}

@Test("request logs redact query values and resource identifiers")
func requestLogsRedactPrivateValues() async throws {
    let fixture = try ServerDatabaseFixture()
    let capturedLogs = CapturedLogs()
    let logger = Logger(label: "relay-server-tests") { _ in
        CapturingLogHandler(capturedLogs: capturedLogs)
    }
    let app = makeTestApplication(databasePath: fixture.path, logger: logger)

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/chats/1/messages?q=sensitive-search-value",
            method: .get
        )
        #expect(response.status == .ok)

        let chat = try await client.execute(uri: "/chats/1/messages", method: .get)
        #expect(chat.status == .ok)

        let attachment = try await client.execute(uri: "/attachments/7", method: .get)
        #expect(attachment.status == .ok)
    }

    let output = capturedLogs.entries.joined(separator: "\n")
    #expect(output.contains("GET"))
    #expect(output.contains("/chats/:id/messages"))
    #expect(output.contains("/attachments/:rowid"))
    #expect(!output.contains("sensitive-search-value"))
    #expect(!output.contains("?q="))
    #expect(!output.contains("/chats/1/messages"))
    #expect(!output.contains("/attachments/7"))
}

@Test("attachments return bytes and map missing files")
func attachmentRoute() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path)
    let orphanURL = URL(fileURLWithPath: fixture.path)
        .deletingLastPathComponent()
        .appendingPathComponent("Attachments/orphan.txt")
    try Data("orphan attachment".utf8).write(to: orphanURL)
    try fixture.execute("""
        INSERT INTO attachment (ROWID, filename, mime_type)
        VALUES (8, '\(orphanURL.path)', 'text/plain');
        """)

    try await app.test(.router) { client in
        let found = try await client.execute(uri: "/attachments/7", method: .get)
        #expect(found.status == .ok)
        #expect(found.headers[.contentType] == "text/plain")
        #expect(Data(found.body.readableBytesView) == fixture.attachmentData)

        let missing = try await client.execute(uri: "/attachments/999", method: .get)
        try expectJSONError(
            missing,
            status: .notFound,
            message: "attachment not found or backing file missing"
        )

        let orphan = try await client.execute(uri: "/attachments/8", method: .get)
        try expectJSONError(
            orphan,
            status: .notFound,
            message: "attachment not found or backing file missing"
        )

        let malformed = try await client.execute(uri: "/attachments/nope", method: .get)
        try expectJSONError(
            malformed,
            status: .badRequest,
            message: "path parameter :rowid must be a positive attachment rowid"
        )
    }
}

@Test("parallel reads share the isolated store executor")
func parallelReads() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        async let chats = client.execute(uri: "/chats", method: .get)
        async let messages = client.execute(uri: "/chats/1/messages", method: .get)
        let (chatResponse, messageResponse) = try await (chats, messages)
        #expect(chatResponse.status == .ok)
        #expect(messageResponse.status == .ok)
    }
}

@Test("large attachments stream in bounded chunks")
func largeAttachmentStreaming() async throws {
    let bytes = Data(repeating: 0xA5, count: 9 * 1024 * 1024 + 17)
    let fixture = try ServerDatabaseFixture(attachmentData: bytes, attachmentMimeType: nil)
    let store = MessageStore(path: fixture.path)
    let resource = try #require(try await store.attachmentResource(rowid: 7))
    let context = StreamingTestContext(source: .init(logger: Logger(label: "attachment-stream-test")))
    let body = try await AttachmentsController.responseBody(for: resource, context: context)
    let recorder = StreamRecorder()

    try await body.write(RecordingBodyWriter(recorder: recorder))

    let result = await recorder.result
    #expect(result.totalBytes == bytes.count)
    #expect(result.largestWrite <= 1024 * 1024)
    #expect(result.finished)

    let app = makeTestApplication(databasePath: fixture.path)
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/attachments/7", method: .get)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/octet-stream")
        #expect(Data(response.body.readableBytesView) == bytes)
    }
}

@Test("send dispatches only through the fake sender")
func sendSuccess() async throws {
    let fixture = try ServerDatabaseFixture()
    let sender = FakeMessageSender()
    let app = makeTestApplication(databasePath: fixture.path, sender: sender)

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/send",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"to":"+15551230001","text":"test only"}"#)
        )
        #expect(response.status == .ok)
        expectJSONContentType(response)
        let body = try jsonObject(response.body)
        #expect(body["ok"] as? Bool == true)
        #expect(body["guid"] as? String == "fake-guid")
        #expect(sender.requests.count == 1)
        #expect(sender.requests.first?.to == "+15551230001")
        #expect(sender.requests.first?.text == "test only")
    }
}

@Test("send rejects unsupported fields and invalid text before dispatch")
func sendStrictRequestValidation() async throws {
    let fixture = try ServerDatabaseFixture()
    let sender = FakeMessageSender()
    let app = makeTestApplication(databasePath: fixture.path, sender: sender)
    let cases: [(String, String)] = [
        (#"{"to":"+15551230001","file":"synthetic.txt"}"#, "unsupported field: file"),
        (#"{"to":"+15551230001","text":"safe","file":"synthetic.txt"}"#, "unsupported field: file"),
        (#"{"to":"+15551230001","text":"safe","service":"SMS"}"#, "unsupported field: service"),
        (#"{"to":"+15551230001","text":"safe","extra":true}"#, "unsupported field: extra"),
        (#"{"to":"+15551230001","text":" \t\n"}"#, "provide non-empty text"),
        (#"{"to":"+15551230001"}"#, "provide non-empty text"),
        (#"{"to":"+15551230001","chat_id":1,"text":"safe"}"#, "provide exactly one of chat_id or to"),
        (#"{"text":"safe"}"#, "provide exactly one of chat_id or to"),
    ]

    try await app.test(.router) { client in
        for (body, message) in cases {
            let response = try await postJSON(client, body: body)
            try expectJSONError(response, status: .badRequest, message: message)
        }
    }
    #expect(sender.requests.isEmpty)
}

@Test("send maps every fake process outcome conservatively")
func sendProcessOutcomes() async throws {
    let fixture = try ServerDatabaseFixture()
    let cases: [(SendProcessResult, HTTPResponse.Status, String)] = [
        (
            .launchFailed("synthetic launch failure"),
            .badGateway,
            "Send was never started (retry safe). Could not launch osascript. synthetic launch failure"
        ),
        (
            .inputFailed("synthetic input failure"),
            .internalServerError,
            "Send may have completed; do not retry blindly. Could not provide the script to osascript. synthetic input failure"
        ),
        (
            .exited(7),
            .internalServerError,
            "Send may have completed; do not retry blindly. osascript exited 7."
        ),
        (
            .timedOut,
            .internalServerError,
            "Send may have completed; do not retry blindly. osascript exceeded the send deadline and was terminated."
        ),
        (
            .failedToTerminate,
            .internalServerError,
            "Send may have completed; do not retry blindly. osascript did not stop after forced termination."
        ),
    ]

    for (result, status, message) in cases {
        let runner = FakeSendProcessRunner(result: result)
        let sender = MessageSender(
            timeout: .milliseconds(5),
            terminationGrace: .milliseconds(5),
            osascriptPath: "/synthetic/osascript",
            processRunner: runner
        )
        let app = makeTestApplication(databasePath: fixture.path, sender: sender)
        try await app.test(.router) { client in
            let response = try await postJSON(
                client,
                body: #"{"to":"+15551230001","text":"synthetic"}"#
            )
            try expectJSONError(response, status: status, message: message)
            if status == .internalServerError {
                #expect(!message.localizedCaseInsensitiveContains("retry safe"))
            }
        }
        #expect(runner.invocations.count == 1)
    }

    let runner = FakeSendProcessRunner(result: .exited(0))
    let sender = MessageSender(osascriptPath: "/synthetic/osascript", processRunner: runner)
    let app = makeTestApplication(databasePath: fixture.path, sender: sender)
    try await app.test(.router) { client in
        let response = try await postJSON(
            client,
            body: #"{"to":"+15551230001","text":"synthetic"}"#
        )
        #expect(response.status == .ok)
    }
    #expect(runner.invocations.count == 1)
}

@Test("send keeps message contents out of process arguments")
func sendMessagePrivacy() async throws {
    let sensitiveText = "private message content \(UUID().uuidString)"
    let runner = FakeSendProcessRunner(result: .exited(0))
    let sender = MessageSender(osascriptPath: "/synthetic/osascript", processRunner: runner)

    _ = try await sender.send(SendRequest(
        chatID: nil,
        chatGuid: nil,
        to: "+15551230001",
        text: sensitiveText
    ))

    let invocation = try #require(runner.invocations.first)
    #expect(invocation.arguments.isEmpty)
    #expect(!invocation.arguments.joined(separator: " ").contains(sensitiveText))
    let script = try #require(String(data: invocation.standardInput, encoding: .utf8))
    #expect(script.contains(sensitiveText))
    #expect(script.contains("+15551230001"))
}

@Test("send authorization preserves direct address identity")
func sendAddressCollisionDenied() async throws {
    let fixture = try ServerDatabaseFixture()
    let sender = FakeMessageSender()
    let app = makeTestApplication(
        databasePath: fixture.path,
        allowedRecipients: [ServerConfig.normalizeRecipient("recipient_tag@example.com")],
        sender: sender
    )

    try await app.test(.router) { client in
        let allowed = try await postJSON(
            client,
            body: #"{"to":"RECIPIENT_TAG@EXAMPLE.COM","text":"synthetic"}"#
        )
        #expect(allowed.status == .ok)

        let denied = try await postJSON(
            client,
            body: #"{"to":"recipienttag@example.com","text":"never sent"}"#
        )
        try expectJSONError(
            denied,
            status: .forbidden,
            message:
                "recipient not allowed by RELAY_ALLOWED_RECIPIENTS. Configure the allowlist to enable sending."
        )
        #expect(sender.requests.count == 1)
        #expect(sender.requests.first?.to == "RECIPIENT_TAG@EXAMPLE.COM")
    }
}

@Test("group send requires every synthetic participant")
func sendGroupRequiresEveryParticipant() async throws {
    let fixture = try ServerDatabaseFixture()
    let allowedSender = FakeMessageSender()
    let allowedApp = makeTestApplication(
        databasePath: fixture.path,
        allowedRecipients: [
            ServerConfig.normalizeRecipient("member_one@example.com"),
            ServerConfig.normalizeRecipient("member-two@example.com"),
        ],
        sender: allowedSender
    )

    try await allowedApp.test(.router) { client in
        let response = try await postJSON(
            client,
            body: #"{"chat_id":2,"text":"synthetic group"}"#
        )
        #expect(response.status == .ok)
        #expect(allowedSender.requests.count == 1)
        #expect(allowedSender.requests.first?.chatID == 2)
    }

    let deniedSender = FakeMessageSender()
    let deniedApp = makeTestApplication(
        databasePath: fixture.path,
        allowedRecipients: [ServerConfig.normalizeRecipient("member_one@example.com")],
        sender: deniedSender
    )

    try await deniedApp.test(.router) { client in
        let response = try await postJSON(
            client,
            body: #"{"chat_id":2,"text":"never sent"}"#
        )
        try expectJSONError(
            response,
            status: .forbidden,
            message:
                "recipient not allowed by RELAY_ALLOWED_RECIPIENTS. Configure the allowlist to enable sending."
        )
        #expect(deniedSender.requests.isEmpty)
    }
}

@Test("send validates input, allowlist, and sender errors")
func sendErrors() async throws {
    let fixture = try ServerDatabaseFixture()
    let deniedApp = makeTestApplication(databasePath: fixture.path)
    try await deniedApp.test(.router) { client in
        let invalid = try await postJSON(client, body: #"{"text":"missing target"}"#)
        try expectJSONError(
            invalid, status: .badRequest, message: "provide exactly one of chat_id or to")

        let denied = try await postJSON(client, body: #"{"to":"+15559999999","text":"denied"}"#)
        try expectJSONError(
            denied,
            status: .forbidden,
            message:
                "recipient not allowed by RELAY_ALLOWED_RECIPIENTS. Configure the allowlist to enable sending."
        )
    }

    let unavailableSender = FakeMessageSender(outcome: .unavailable("fake sender unavailable"))
    let unavailableApp = makeTestApplication(databasePath: fixture.path, sender: unavailableSender)
    try await unavailableApp.test(.router) { client in
        let response = try await postJSON(client, body: #"{"to":"+15551230001","text":"safe fake"}"#)
        try expectJSONError(response, status: .notImplemented, message: "fake sender unavailable")
    }
}

@Test("configured bearer authentication protects every route")
func authenticationBoundaries() async throws {
    let fixture = try ServerDatabaseFixture()
    let app = makeTestApplication(databasePath: fixture.path, token: "test-token")
    let routes: [(String, HTTPRequest.Method, ByteBuffer?)] = [
        ("/status", .get, nil),
        ("/chats", .get, nil),
        ("/chats/1", .get, nil),
        ("/chats/1/messages", .get, nil),
        ("/attachments/7", .get, nil),
        ("/send", .post, ByteBuffer(string: #"{"to":"+15551230001","text":"never sent"}"#)),
    ]

    try await app.test(.router) { client in
        for (uri, method, body) in routes {
            let missing = try await client.execute(
                uri: uri,
                method: method,
                headers: body == nil ? [:] : [.contentType: "application/json"],
                body: body
            )
            try expectJSONError(
                missing,
                status: .unauthorized,
                message: "missing or invalid bearer token"
            )

            let invalid = try await client.execute(
                uri: uri,
                method: method,
                headers: [
                    .authorization: "Bearer wrong-token",
                    .contentType: "application/json",
                ],
                body: body
            )
            try expectJSONError(
                invalid,
                status: .unauthorized,
                message: "missing or invalid bearer token"
            )
        }

        let valid = try await client.execute(
            uri: "/status",
            method: .get,
            headers: [.authorization: "Bearer test-token"]
        )
        #expect(valid.status == .ok)
    }
}

@Test("database open failures map to service unavailable")
func absentDatabaseErrorMapping() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("absent-\(UUID().uuidString)/chat.db").path
    let app = makeTestApplication(databasePath: path)

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/chats", method: .get)
        try expectJSONError(
            response, status: .serviceUnavailable, message: "Messages database unavailable")
        let responseText = try #require(String(bytes: response.body.readableBytesView, encoding: .utf8))
        #expect(!responseText.contains(path))
    }
}

private struct StreamingTestSource: RequestContextSource {
    let logger: Logger
}

private struct StreamingTestContext: RequestContext {
    typealias Source = StreamingTestSource

    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        coreContext = .init(source: source)
    }
}

private actor StreamRecorder {
    private(set) var totalBytes = 0
    private(set) var largestWrite = 0
    private(set) var finished = false

    var result: (totalBytes: Int, largestWrite: Int, finished: Bool) {
        (totalBytes, largestWrite, finished)
    }

    func record(_ count: Int) {
        totalBytes += count
        largestWrite = max(largestWrite, count)
    }

    func finish() {
        finished = true
    }
}

private struct RecordingBodyWriter: ResponseBodyWriter {
    let recorder: StreamRecorder

    mutating func write(_ buffer: ByteBuffer) async throws {
        await recorder.record(buffer.readableBytes)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        await recorder.finish()
    }
}

private func postJSON(
    _ client: any TestClientProtocol,
    body: String
) async throws -> TestResponse {
    try await client.execute(
        uri: "/send",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(string: body)
    )
}

private func expectJSONError(
    _ response: TestResponse,
    status: HTTPResponse.Status,
    message: String
) throws {
    #expect(response.status == status)
    expectJSONContentType(response)
    let body = try jsonObject(response.body)
    #expect(value(body, at: "error", "message") as? String == message)
}

private func expectJSONError(
    _ response: TestResponse,
    status: HTTPResponse.Status,
    containing fragment: String
) throws {
    #expect(response.status == status)
    expectJSONContentType(response)
    let body = try jsonObject(response.body)
    let message = value(body, at: "error", "message") as? String
    #expect(message?.contains(fragment) == true)
}

private func jsonObject(_ buffer: ByteBuffer) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any])
}

private func expectJSONContentType(_ response: TestResponse) {
    #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
}

private func jsonArray(_ buffer: ByteBuffer) throws -> [[String: Any]] {
    try #require(
        JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [[String: Any]])
}

private func value(_ object: [String: Any], at keys: String...) -> Any? {
    keys.dropLast().reduce(object as Any?) { current, key in
        (current as? [String: Any])?[key]
    }.flatMap { ($0 as? [String: Any])?[keys.last!] }
}
