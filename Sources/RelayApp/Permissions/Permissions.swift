import AppKit
import ApplicationServices
import Contacts
import Darwin
import Foundation
import RelayCore

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess
    case accessibility
    case automation
    case contacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .accessibility: "Accessibility"
        case .automation: "Automation (Messages)"
        case .contacts: "Contacts"
        }
    }

    var summary: String {
        switch self {
        case .fullDiskAccess:
            "Read messages, conversations, and attachments"
        case .accessibility:
            "Control Messages for replies and reactions"
        case .automation:
            "Send messages through the Messages app"
        case .contacts:
            "Show names for people in your conversations"
        }
    }

    var icon: String {
        switch self {
        case .fullDiskAccess: "externaldrive"
        case .accessibility: "hand.raised"
        case .automation: "message.and.waveform"
        case .contacts: "person.2"
        }
    }

    var required: Bool {
        self == .fullDiskAccess
    }

    /// Direct `true` means tapping Allow triggers a system prompt.
    /// Direct `false` means the grant can only happen inside System Settings.
    var supportsDirectPrompt: Bool {
        switch self {
        case .fullDiskAccess: false
        case .accessibility, .automation, .contacts: true
        }
    }

    var settingsURL: URL? {
        let pane: String
        switch self {
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .accessibility: pane = "Privacy_Accessibility"
        case .automation: pane = "Privacy_Automation"
        case .contacts: pane = "Privacy_Contacts"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

enum PermissionState: Sendable {
    case granted
    case notGranted
    case denied
    case notChecked
    case unknown

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .notGranted: "Needs attention"
        case .denied: "Denied"
        case .notChecked: "Not checked"
        case .unknown: "Cannot verify"
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}

/// Reads permission state and requests access from explicit user actions.
enum PermissionChecker: Sendable {
    static func check(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .fullDiskAccess:
            checkFullDiskAccess()
        case .accessibility:
            await checkAccessibility()
        case .automation:
            await checkAutomation(prompt: false)
        case .contacts:
            checkContacts()
        }
    }

    static func checkAll() async -> [PermissionKind: PermissionState] {
        var states: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases {
            states[kind] = await check(kind)
        }
        return states
    }

    // MARK: - Checks

    /// Full Disk Access has no prompt API. A real open attempt honors TCC,
    /// so success means the app can read the Messages database.
    static func checkFullDiskAccess(
        databasePath: String = ManagedConfiguration.messagesDatabasePath
    ) -> PermissionState {
        let descriptor = open(databasePath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .unknown : .notGranted
        }
        close(descriptor)
        return .granted
    }

    static func checkAccessibility() async -> PermissionState {
        if await MacOSAccessibilityPermissionChecker().isTrusted() {
            return .granted
        }
        // Trust APIs can lag the real TCC state (stale identity, renamed
        // privacy panes). A successful read proves the capability directly.
        if canReadMessagesAccessibilityRole() {
            return .granted
        }
        // Accessibility trust belongs to the relay process, not Messages.
        // Unlike the Automation probe, it can be checked while Messages is
        // closed, so a false trust result is a real denial.
        return .notGranted
    }

    /// Reads one harmless attribute off the Messages app element. Returns
    /// false when Messages is not running or the read is refused. Never
    /// prompts and never launches Messages.
    static func canReadMessagesAccessibilityRole() -> Bool {
        guard let messages = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MobileSMS"
        }) else {
            return false
        }
        let element = AXUIElementCreateApplication(messages.processIdentifier)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    /// Probes Automation for Messages without sending anything.
    /// With `prompt` the system shows the allow/deny dialog once.
    /// Background checks only ask macOS for the current verdict. The
    /// osascript probe runs only after an explicit Allow action.
    static func checkAutomation(prompt: Bool) async -> PermissionState {
        let verdict = synchronousAutomationVerdict(prompt: prompt)
        return prompt ? await verifyAutomation(fallback: verdict) : verdict
    }

    private static func synchronousAutomationVerdict(prompt: Bool) -> PermissionState {
        guard let target = automationTarget() else { return .unknown }
        var mutableTarget = target
        defer { AEDisposeDesc(&mutableTarget) }
        let status = AEDeterminePermissionToAutomateTarget(
            &mutableTarget,
            typeWildCard,
            typeWildCard,
            prompt
        )
        if status == noErr {
            return .granted
        } else if status == errAEEventNotPermitted {
            return .denied
        } else {
            return .unknown
        }
    }

    static func verifyAutomation(fallback: PermissionState) async -> PermissionState {
        guard fallback != .granted else { return .granted }
        guard isMessagesAppRunning() else { return fallback }
        return await probeMessagesAppViaOSAScript() ? .granted : fallback
    }

    static func isMessagesAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.MobileSMS"
        })
    }

    /// `tell application "Messages" to get name`: no state change, exit 0
    /// iff Apple Events actually flow.
    static func probeMessagesAppViaOSAScript() async -> Bool {
        let runner = FoundationSendProcessRunner()
        guard let result = try? await runner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Messages\" to get name"],
            standardInput: Data(),
            timeout: .seconds(5),
            terminationGrace: .seconds(1)
        ) else {
            return false
        }
        return osascriptProbeGranted(result)
    }

    static func osascriptProbeGranted(_ result: SendProcessResult) -> Bool {
        if case .exited(0) = result {
            return true
        }
        return false
    }

    static func checkContacts() -> PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .notGranted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: - Requests (wired to Allow buttons)

    /// Shows the system Accessibility dialog, which directs the user to Settings.
    static func requestAccessibility() {
        // The kAXTrustedCheckOptionPrompt global is not concurrency-safe in
        // Swift 6; its value is the stable "AXTrustedCheckOptionPrompt" key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the Automation allow/deny dialog for Messages, then verifies
    /// with a real round-trip so the reported state reflects capability.
    static func requestAutomation() async -> PermissionState {
        await verifyAutomation(fallback: synchronousAutomationVerdict(prompt: true))
    }

    static func requestContacts() async -> PermissionState {
        let store = CNContactStore()
        let granted = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : checkContacts()
    }

    // MARK: - Private

    private static func automationTarget() -> AEAddressDesc? {
        let data = Data("com.apple.MobileSMS".utf8)
        var target = AEAddressDesc()
        let status = data.withUnsafeBytes { buffer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                buffer.baseAddress,
                data.count,
                &target
            )
        }
        guard status == noErr else { return nil }
        return target
    }
}

/// Observable permission state shared by the Settings window.
@MainActor
final class PermissionStore: ObservableObject {
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMessagesAppRunning = false

    func state(for kind: PermissionKind) -> PermissionState {
        states[kind] ?? .notChecked
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        isMessagesAppRunning = PermissionChecker.isMessagesAppRunning()
        states = await PermissionChecker.checkAll()
    }

    /// Requests access when macOS permits it, then updates the displayed state.
    func requestAccess(for kind: PermissionKind) async {
        switch kind {
        case .fullDiskAccess:
            openSettings(for: kind)
        case .accessibility:
            PermissionChecker.requestAccessibility()
        case .automation:
            states[kind] = await PermissionChecker.requestAutomation()
            return
        case .contacts:
            states[kind] = await PermissionChecker.requestContacts()
            return
        }
        // The Settings-based grants apply asynchronously; recheck shortly after.
        try? await Task.sleep(for: .seconds(1))
        states[kind] = await PermissionChecker.check(kind)
    }

    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openMessagesApp() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.MobileSMS"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
