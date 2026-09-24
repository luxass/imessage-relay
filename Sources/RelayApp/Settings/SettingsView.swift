import AppKit
import RelayServer
import SwiftUI

/// Settings uses a small sidebar for navigation without making every section
/// its own window or scene.
struct SettingsView: View {
    @ObservedObject var relay: RelayController
    @ObservedObject var loginItem: LoginItemSettings
    @ObservedObject var permissions: PermissionStore

    private enum Page {
        case status
        case permissions
    }

    @State private var selectedPage: Page = .status
    @State private var token: String?
    @State private var tokenError: String?
    @State private var tokenRevealed = false
    @State private var tokenCopied = false
    @State private var isEditingToken = false
    @State private var loginItemError: String?
    @State private var configurationError: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                Group {
                    if selectedPage == .status {
                        statusPage
                    } else {
                        permissionsPage
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task(id: selectedPage) {
            guard selectedPage == .permissions else { return }
            await permissions.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await permissions.refresh()
            }
        }
        .sheet(isPresented: $isEditingToken) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("API Token")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Cancel") { isEditingToken = false }
                        .keyboardShortcut(.cancelAction)
                }
                TokenEditorView(tokenStore: relay.tokenStore) {
                    token = nil
                    tokenRevealed = false
                    tokenError = nil
                    relay.applyTokenChange()
                    isEditingToken = false
                }
            }
            .padding(24)
            .frame(width: 510)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("General")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            sidebarButton("Status", systemImage: "info.circle", page: .status)
            Text("Relay")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 12)
            sidebarButton("Permissions", systemImage: "lock", page: .permissions)
            Spacer()
        }
        .padding(12)
        .frame(width: 200, alignment: .topLeading)
    }

    private func sidebarButton(_ title: String, systemImage: String, page: Page) -> some View {
        Button {
            selectedPage = page
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            .quaternary.opacity(selectedPage == page ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private var statusPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("iMessage Relay \(packageVersion)")
                .font(.largeTitle)

            SettingsGroup(title: "Server") {
                SettingsRow(title: "Status", subtitle: relay.state.description) {
                    EmptyView()
                }
                GroupDivider()
                SettingsRow(title: "Address", subtitle: "The local API binds here.") {
                    Text(relay.address)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(title: "Relay") {
                SettingsRow(
                    title: "Relay enabled",
                    subtitle: "Start or stop the local server."
                ) {
                    Toggle("", isOn: Binding(
                        get: { relay.state.isEnabled },
                        set: { if $0 { relay.start() } else { relay.stop() } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!relay.state.canChange)
                }
                GroupDivider()
                SettingsRow(
                    title: "Launch at login",
                    subtitle: "Start iMessage Relay when you log in."
                ) {
                    Toggle("", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { _ in
                            do {
                                try loginItem.toggle()
                                loginItemError = nil
                            } catch {
                                loginItemError = error.localizedDescription
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            tokenSection

            SettingsGroup(title: "Configuration") {
                SettingsRow(
                    title: "Configuration file",
                    subtitle: "Edit the relay's port and connection options."
                ) {
                    Button("Open File", action: openConfiguration)
                }
                GroupDivider()
                SettingsRow(
                    title: "Reload configuration",
                    subtitle: "Restart the running relay with your saved changes."
                ) {
                    Button("Reload") {
                        relay.reloadConfiguration()
                    }
                    .disabled(!relay.state.isEnabled || !relay.state.canChange)
                }
            }
            if let configurationError {
                Text(configurationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var permissionsPage: some View {
        let required = PermissionKind.allCases.filter(\.required)
        let granted = required.filter { permissions.state(for: $0).isGranted }.count
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Permissions")
                    .font(.title2)
                Spacer()
                Text("\(granted)/\(required.count) core access")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await permissions.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(permissions.isRefreshing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Access")
                    .font(.headline)

                VStack(spacing: 0) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionRowView(kind: kind, store: permissions)
                        if kind != PermissionKind.allCases.last {
                            GroupDivider()
                        }
                    }
                }
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary)
                }
            }

        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsGroup(title: "API Token") {
                if let tokenError {
                    HStack {
                        Text(tokenError)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Retry") {
                            Task { await revealToken() }
                        }
                    }
                    .padding(12)
                } else if tokenRevealed, let token {
                    HStack {
                        Text(token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Hide") {
                            tokenRevealed = false
                        }
                        Button(tokenCopied ? "Copied" : "Copy", action: copyToken)
                            .buttonStyle(.borderedProminent)
                            .disabled(tokenCopied)
                    }
                    .padding(12)
                } else {
                    HStack {
                        Text("••••••••••••")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal") {
                            Task { await revealToken() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                }
            }
            Text("Reveal to view the token stored in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Change Token...") {
                isEditingToken = true
            }
        }
    }

    private func revealToken() async {
        if token == nil {
            do {
                guard let stored = try relay.tokenStore.read() else {
                    throw KeychainTokenError.missingToken
                }
                token = stored
                tokenError = nil
            } catch {
                token = nil
                tokenError = error.localizedDescription
                return
            }
        }
        tokenRevealed = token != nil
    }

    private func openConfiguration() {
        do {
            _ = try ManagedConfigurationStore.loadOrCreate()
            if NSWorkspace.shared.open(ManagedConfigurationStore.configurationURL) {
                configurationError = nil
            } else {
                configurationError = "Could not open the configuration file."
            }
        } catch {
            configurationError = error.localizedDescription
        }
    }

    private func copyToken() {
        guard let token else { return }
        SecurePasteboard.copy(token)
        tokenCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            tokenCopied = false
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct SettingsRow<Control: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct GroupDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 12)
    }
}
