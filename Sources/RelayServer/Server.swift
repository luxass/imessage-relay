import Foundation
import Hummingbird
import HummingbirdRouter
import Logging
import RelayCore
import ServiceLifecycle

public let packageVersion = "0.3.0" // x-release-please-version

struct RelayDependencies: Sendable {
    let database: any DatabaseStatusProviding
    let conversations: ConversationService
    let messages: MessageService
    let reactions: ReactionService
    let typing: TypingService
    let media: MediaService
    let sender: any MessageSender
    let events: EventService
}

struct RelayRuntime: Sendable {
    let storage: MessagesStorage
    let sender: any MessageSender & MessageReactionWriting
    let conversationReadWriter: any ConversationReadWriting
    let conversationTypingWriter: any ConversationTypingWriting
    let uploads: any UploadedMediaStoring
    let sendRequests: any SendRequestStoring
}

struct RelayResourcesService: Service {
    let storage: MessagesStorage
    let events: EventService
    let typing: TypingService

    func run() async throws {
        do {
            try await gracefulShutdown()
        } catch {
            try? await typing.stopActiveTyping()
            await events.shutdown()
            try? await storage.shutdown()
            throw error
        }
        try? await typing.stopActiveTyping()
        await events.shutdown()
        try await storage.shutdown()
    }
}

func buildRouter(
    serverConfig: ServerConfig,
    dependencies: RelayDependencies
) -> Router<RelayRequestContext> {
    let router = Router(context: RelayRequestContext.self)
    router.middlewares.add(APIErrorMiddleware())
    router.middlewares.add(RequestIDMiddleware())
    router.middlewares.add(AuthenticationMiddleware(token: serverConfig.token))
    StatusRoutes(database: dependencies.database, sender: dependencies.sender).register(on: router)
    SenderRoutes(sender: dependencies.sender).register(on: router)
    ConversationRoutes(
        conversations: dependencies.conversations,
        messages: dependencies.messages,
        typing: dependencies.typing
    ).register(on: router)
    MessageRoutes(messages: dependencies.messages, reactions: dependencies.reactions).register(on: router)
    MediaRoutes(media: dependencies.media, maximumBytes: serverConfig.maximumMediaBytes)
        .register(on: router)
    EventRoutes(database: dependencies.database, events: dependencies.events).register(on: router)
    return router
}

func buildApplication(
    configuration: ApplicationConfiguration,
    serverConfig: ServerConfig,
    runtime: RelayRuntime,
    logger: Logger? = nil
) -> some ApplicationProtocol {
    let media = MediaService(
        uploads: runtime.uploads,
        messagesMedia: runtime.storage.media,
        policy: MediaPolicy(maximumBytes: serverConfig.maximumMediaBytes)
    )
    let events = EventService(observer: SQLiteMessageChangeObserver(
        path: serverConfig.databasePath,
        attachmentDirectory: serverConfig.attachmentDirectory
    ))
    let typing = TypingService(
        conversations: runtime.storage.conversations,
        messages: runtime.storage.messages,
        writer: runtime.conversationTypingWriter
    )
    let dependencies = RelayDependencies(
        database: runtime.storage,
        conversations: ConversationService(
            store: runtime.storage.conversations,
            messages: runtime.storage.messages,
            readWriter: runtime.conversationReadWriter,
            typing: typing
        ),
        messages: MessageService(
            conversations: runtime.storage.conversations,
            messages: runtime.storage.messages,
            sender: runtime.sender,
            media: media,
            recipientResolver: ContactRecipientResolver(region: serverConfig.phoneRegion),
            allowlist: RecipientAllowlist(values: serverConfig.allowedRecipients),
            sendRequests: runtime.sendRequests,
            correlator: runtime.storage.messages,
            typing: typing
        ),
        reactions: ReactionService(
            conversations: runtime.storage.conversations,
            messages: runtime.storage.messages,
            sender: runtime.sender,
            writer: runtime.sender,
            typing: typing
        ),
        typing: typing,
        media: media,
        sender: runtime.sender,
        events: events
    )
    return Application(
        router: buildRouter(serverConfig: serverConfig, dependencies: dependencies),
        configuration: configuration,
        services: [RelayResourcesService(storage: runtime.storage, events: events, typing: typing)],
        logger: logger
    )
}

public func runRelayServer(
    hostname: String,
    port: Int,
    config: ServerConfig
) async throws {
    let storage = MessagesStorage(
        path: config.databasePath,
        attachmentDirectory: config.attachmentDirectory
    )
    let accessibilityPermissionChecker = MacOSAccessibilityPermissionChecker()
    let accessibilityDriver = MacOSAccessibilityMessagesDriver()
    let accessibilityQueue = AccessibilityOperationQueue()
    let sender = MacOSMessageSender(
        configuredAccountID: config.senderAccountID,
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
    let uploads = MediaFileStore(directory: URL(fileURLWithPath: config.mediaDirectory))
    let sendRequests = try SQLiteSendRequestStore(path: config.stateDatabasePath)
    let application = buildApplication(
        configuration: .init(
            address: .hostname(hostname, port: port),
            serverName: "imessage-relay"
        ),
        serverConfig: config,
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
