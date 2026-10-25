import Foundation
import ServiceManagement

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var title = "Start at Login"

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        title = status == .requiresApproval ? "Approve Start at Login..." : "Start at Login"
    }

    func toggle() throws {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            try service.unregister()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .notFound, .notRegistered:
            guard isInstalledInApplications else { throw LoginItemError.notInstalled }
            try service.register()
        @unknown default:
            throw LoginItemError.unknownStatus
        }
        refresh()
    }

    private var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true).path + "/")
    }
}

enum LoginItemError: LocalizedError {
    case notInstalled
    case unknownStatus

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Move iMessage Relay to Applications before enabling Start at Login."
        case .unknownStatus: "macOS returned an unknown Start at Login state."
        }
    }
}
