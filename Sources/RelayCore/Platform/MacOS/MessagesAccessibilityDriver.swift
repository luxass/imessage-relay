import Foundation

public final class MacOSAccessibilityMessagesDriver: AccessibilityMessagesDriving, @unchecked Sendable {
    static let messagesBundleIdentifier = "com.apple.MobileSMS"
    static let replyBundlePath =
        "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle"
    static let chatKitBundlePath =
        "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework"

    static let normalComposerPlaceholders = localizedStringVariants(
        bundlePath: chatKitBundlePath,
        table: "ChatKit",
        key: "MADRID",
        fallbacks: ["iMessage"]
    ).union(localizedStringVariants(
        bundlePath: chatKitBundlePath,
        table: "ChatKit",
        key: "TEXT_MESSAGE",
        fallbacks: ["Text Message"]
    ))

    static let replyActionTitles = localizedStringVariants(
        bundlePath: replyBundlePath,
        table: "Accessibility",
        key: "balloon.message.reply",
        fallbacks: ["Reply"]
    )

    static let reactionPickerActionTitles = localizedStringVariants(
        bundlePath: replyBundlePath,
        table: "Accessibility",
        key: "acknowledgments.action.title",
        fallbacks: ["React", "Tapback"]
    )

    static let loveReactionActionTitles = reactionActionTitles(
        key: "acknowledgment.type.heart",
        fallback: "Heart"
    )
    static let likeReactionActionTitles = reactionActionTitles(
        key: "acknowledgment.type.thumbs.up",
        fallback: "Thumbs up"
    )
    static let dislikeReactionActionTitles = reactionActionTitles(
        key: "acknowledgment.type.thumbs.down",
        fallback: "Thumbs down"
    )
    static let laughReactionActionTitles = reactionActionTitles(
        key: "acknowledgment.type.ha",
        fallback: "Ha ha!"
    )
    static let emphasisReactionActionTitles = reactionActionTitles(
        key: "acknowledgment.type.exclamation",
        fallback: "Exclamation mark"
    )
    static let questionReactionActionTitles = reactionActionTitles(
        key: "acknowledgment.type.question.mark",
        fallback: "Question mark"
    )
    static let directReactionActionTitles = loveReactionActionTitles
        .union(likeReactionActionTitles)
        .union(dislikeReactionActionTitles)
        .union(laughReactionActionTitles)
        .union(emphasisReactionActionTitles)
        .union(questionReactionActionTitles)

    let timeout: Duration

    public init(timeout: Duration = .seconds(8)) {
        self.timeout = timeout
    }

    private static func reactionActionTitles(key: String, fallback: String) -> Set<String> {
        localizedStringVariants(
            bundlePath: replyBundlePath,
            table: "Accessibility",
            key: key,
            fallbacks: [fallback]
        )
    }
}
