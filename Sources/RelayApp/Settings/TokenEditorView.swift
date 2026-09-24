import SwiftUI

/// The Keychain changes only after the user chooses an action.
struct TokenEditorView: View {
    let tokenStore: KeychainTokenStore
    let onSaved: () -> Void

    @State private var customToken = ""
    @State private var hasExistingToken = false
    @State private var confirmReplacement = false
    @State private var replaceWithCustomToken = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                Button {
                    if hasExistingToken {
                        replaceWithCustomToken = false
                        confirmReplacement = true
                    } else {
                        generateToken(replacingExisting: false)
                    }
                } label: {
                    tokenRow(
                        icon: "sparkles",
                        title: "Generate a token",
                        detail: hasExistingToken
                            ? "Replace your current token with a new one."
                            : "Create a secure token automatically."
                    )
                }
                .buttonStyle(.plain)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))

            HStack(spacing: 10) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                Text("OR USE YOUR OWN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                SecureField("Paste or type a token", text: $customToken)
                    .textFieldStyle(.roundedBorder)
                Button("Save Token") {
                    if hasExistingToken {
                        replaceWithCustomToken = true
                        confirmReplacement = true
                    } else {
                        saveCustomToken()
                    }
                }
                .controlSize(.large)
                .disabled(customToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            do {
                hasExistingToken = try tokenStore.read() != nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Replace the existing token?", isPresented: $confirmReplacement) {
            Button("Replace Token", role: .destructive) {
                if replaceWithCustomToken {
                    saveCustomToken()
                } else {
                    generateToken(replacingExisting: true)
                }
            }
        } message: {
            Text("Clients using the current token will need the new one.")
        }
    }

    private func tokenRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func didSave() {
        errorMessage = nil
        onSaved()
    }

    private func saveCustomToken() {
        do {
            try tokenStore.save(customToken.trimmingCharacters(in: .whitespacesAndNewlines))
            customToken = ""
            hasExistingToken = true
            didSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateToken(replacingExisting: Bool) {
        do {
            _ = try tokenStore.generate(replacingExisting: replacingExisting)
            hasExistingToken = true
            didSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
