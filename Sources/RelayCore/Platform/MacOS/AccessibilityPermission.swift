import ApplicationServices

public protocol AccessibilityPermissionChecking: Sendable {
    func isTrusted() async -> Bool
}

public struct MacOSAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    public init() {}

    public func isTrusted() async -> Bool {
        AXIsProcessTrusted()
    }
}
