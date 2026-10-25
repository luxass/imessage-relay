import SwiftUI

struct OnboardingView: View {
    let tokenStore: KeychainTokenStore
    @ObservedObject var permissions: PermissionStore
    let onFinish: () -> Void
    let onHeightChange: (CGFloat) -> Void

    private enum TokenChoice {
        case existing
        case generated
        case custom
    }

    @State private var showingPermissions = AppSetup.tokenReady()
    @State private var hasExistingToken = false
    @State private var tokenChoice: TokenChoice?
    @State private var customToken = ""
    @State private var tokenError: String?
    @State private var confirmReplacement = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                Text("iMessage Relay")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(showingPermissions ? "2 of 2" : "1 of 2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(showingPermissions ? "Connect to macOS" : "Choose an API token")
                            .font(.system(size: 25, weight: .semibold))
                        Text(showingPermissions
                             ? "Allow access to the features you want to use. You can change this later."
                             : "This token protects your local relay. Keep it in Keychain or enter your own.")
                            .foregroundStyle(.secondary)
                    }

                    if showingPermissions {
                        permissionsStep
                    } else {
                        tokenStep
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            HStack {
                if showingPermissions {
                    Button("Back") { showingPermissions = false }
                } else {
                    Label("Stored in Keychain", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
                if showingPermissions {
                    Button("Finish Setup", action: onFinish)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button(continueTitle) { continueWithToken() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canContinue)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 600, minHeight: 350)
        .onAppear {
            do {
                hasExistingToken = try tokenStore.read() != nil
                if showingPermissions && !hasExistingToken {
                    AppSetup.clearTokenReady()
                    showingPermissions = false
                }
            } catch {
                tokenError = error.localizedDescription
            }
        }
        .onChange(of: windowHeight) { _, height in
            onHeightChange(height)
        }
        .task(id: showingPermissions) {
            if showingPermissions { await permissions.refresh() }
        }
        .confirmationDialog("Replace the existing token?", isPresented: $confirmReplacement) {
            Button("Replace Token", role: .destructive) {
                continueWithToken(replacementConfirmed: true)
            }
        } message: {
            Text("Clients using the current token will need the new one.")
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                if hasExistingToken {
                    tokenOption(
                        .existing,
                        title: "Keep existing token",
                        detail: "Continue with the token already in Keychain.",
                        icon: "key.fill"
                    )
                    Divider().padding(.leading, 52)
                }
                tokenOption(
                    .generated,
                    title: "Generate a token",
                    detail: "Create a secure token automatically.",
                    icon: "sparkles"
                )
                Divider().padding(.leading, 52)
                tokenOption(
                    .custom,
                    title: "Use my own token",
                    detail: "Enter a token you already use with your clients.",
                    icon: "keyboard"
                )
                if tokenChoice == .custom {
                    SecureField("Your token", text: $customToken)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 52)
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))

            if hasExistingToken && tokenChoice == .generated {
                Text("Generating a new token will replace the current one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let tokenError {
                Label(tokenError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func tokenOption(
        _ choice: TokenChoice,
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        Button {
            tokenChoice = choice
            tokenError = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: tokenChoice == choice ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(tokenChoice == choice ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var continueTitle: String {
        switch tokenChoice {
        case .existing: "Continue"
        case .generated: "Generate & Continue"
        case .custom: "Save & Continue"
        case nil: "Continue"
        }
    }

    private var windowHeight: CGFloat {
        if showingPermissions { return 540 }
        if tokenChoice == .custom { return hasExistingToken ? 500 : 450 }
        return hasExistingToken ? 440 : 390
    }

    private var canContinue: Bool {
        guard let tokenChoice else { return false }
        if tokenChoice == .custom {
            return !customToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func continueWithToken(replacementConfirmed: Bool = false) {
        guard let tokenChoice else { return }
        if hasExistingToken && tokenChoice != .existing && !replacementConfirmed {
            confirmReplacement = true
            return
        }
        do {
            switch tokenChoice {
            case .existing:
                guard try tokenStore.read() != nil else { throw KeychainTokenError.missingToken }
            case .generated:
                _ = try tokenStore.generate(replacingExisting: hasExistingToken)
            case .custom:
                try tokenStore.save(customToken.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            advanceToPermissions()
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func advanceToPermissions() {
        hasExistingToken = true
        tokenChoice = .existing
        customToken = ""
        tokenError = nil
        AppSetup.markTokenReady()
        showingPermissions = true
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Permissions")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Recheck") {
                    Task { await permissions.refresh() }
                }
                .disabled(permissions.isRefreshing)
            }

            VStack(spacing: 0) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRowView(kind: kind, store: permissions)
                    if kind != PermissionKind.allCases.last {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text("macOS may close the app after you grant Full Disk Access. Reopen it to continue here.")
                Text("You can finish with permissions pending and allow them later in Settings.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
