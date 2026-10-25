import SwiftUI

struct PermissionRowView: View {
    let kind: PermissionKind
    @ObservedObject var store: PermissionStore

    var body: some View {
        let state = store.state(for: kind)

        HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(stateColor(for: state))
                .frame(width: 32, height: 32)
                .background(
                    stateColor(for: state).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                    if !kind.required {
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor(for: state))
                        .frame(width: 6, height: 6)
                    Text(statusTitle(for: kind, state: state))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor(for: state))
                }

                if !state.isGranted {
                    HStack(spacing: 5) {
                        if kind == .automation && state == .denied {
                            Button("Allow") {
                                Task { await store.requestAccess(for: kind) }
                            }
                        }
                        Button(actionTitle(for: kind, state: state)) {
                            if state == .denied {
                                store.openSettings(for: kind)
                            } else if kind == .automation && (state == .unknown || state == .notChecked)
                                && !store.isMessagesAppRunning {
                                store.openMessagesApp()
                            } else {
                                Task { await store.requestAccess(for: kind) }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func stateColor(for state: PermissionState) -> Color {
        switch state {
        case .granted: .green
        case .notGranted, .denied: .orange
        case .notChecked, .unknown: .secondary
        }
    }

    private func statusTitle(for kind: PermissionKind, state: PermissionState) -> String {
        if kind == .automation && (state == .unknown || state == .notChecked)
            && !store.isMessagesAppRunning {
            return "Waiting for Messages"
        }
        return state.label
    }

    private func actionTitle(for kind: PermissionKind, state: PermissionState) -> String {
        if state == .denied { return "Open Settings" }
        if kind == .automation && (state == .unknown || state == .notChecked)
            && !store.isMessagesAppRunning {
            return "Open Messages"
        }
        return kind.supportsDirectPrompt ? "Allow" : "Open Settings"
    }
}
