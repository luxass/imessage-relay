import ArgumentParser
import Foundation
import Hummingbird
import RelayCore

@main
struct RelayServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relay-server",
        abstract: "Expose the local Messages database and sender through the /v1 API.",
        version: packageVersion
    )

    @Option(name: .shortAndLong)
    var hostname = "127.0.0.1"

    @Option(name: .shortAndLong)
    var port = 8080

    func run() async throws {
        let serverConfig = try ServerConfig.fromEnvironment()
        let storage = MessagesStorage(
            path: serverConfig.databasePath,
            attachmentDirectory: serverConfig.attachmentDirectory
        )
        let accessibilityPermissionChecker = MacOSAccessibilityPermissionChecker()
        let accessibilityDriver = MacOSAccessibilityMessagesDriver()
        let accessibilityQueue = AccessibilityOperationQueue()
        let sender = MacOSMessageSender(
            configuredAccountID: serverConfig.senderAccountID,
            accessibilityPermissionChecker: accessibilityPermissionChecker,
            accessibilityDriver: accessibilityDriver,
            accessibilityQueue: accessibilityQueue
        )
        let conversationReadWriter = MacOSConversationReadWriter(
            permissionChecker: accessibilityPermissionChecker,
            driver: accessibilityDriver,
            queue: accessibilityQueue
        )
        let conversationTypingWriter = MacOSConversationTypingWriter(
            permissionChecker: accessibilityPermissionChecker,
            driver: accessibilityDriver,
            queue: accessibilityQueue
        )
        let uploads = MediaFileStore(directory: URL(fileURLWithPath: serverConfig.mediaDirectory))
        let sendRequests = try SQLiteSendRequestStore(path: serverConfig.stateDatabasePath)
        let application = buildApplication(
            configuration: .init(
                address: .hostname(hostname, port: port),
                serverName: "imessage-relay"
            ),
            serverConfig: serverConfig,
            runtime: RelayRuntime(
                storage: storage,
                sender: sender,
                conversationReadWriter: conversationReadWriter,
                conversationTypingWriter: conversationTypingWriter,
                uploads: uploads,
                sendRequests: sendRequests
            )
        )
        try await application.runService()
    }
}
