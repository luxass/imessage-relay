import Foundation

public final class MacOSAccessibilityMessagesDriver: AccessibilityMessagesDriving, @unchecked Sendable {
    static let messagesBundleIdentifier = "com.apple.MobileSMS"
    static let replyBundlePath =
        "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle"
    static let chatKitBundlePath =
        "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework"

    let timeout: Duration

    public init(timeout: Duration = .seconds(8)) {
        self.timeout = timeout
    }
}
