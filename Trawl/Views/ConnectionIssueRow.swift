import SwiftUI

struct ConnectionIssueRow: View {
    enum ActionStyle {
        case bordered
        case glassIcons
    }

    let identity: ServiceIdentity
    let title: String
    let message: String
    let isConnecting: Bool
    var retryTitle = "Retry Connection"
    var editTitle = "Edit Server"
    var actionStyle: ActionStyle = .bordered
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(identity.brandColor)

                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if actionStyle == .glassIcons {
                    actions
                }
            }

            if !isConnecting {
                ConnectionRetryCountdownView()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if actionStyle == .bordered {
                actions
            }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: isConnecting)
    }

    @ViewBuilder
    private var actions: some View {
        switch actionStyle {
        case .bordered:
            HStack(spacing: 10) {
                Button(retryTitle, systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting)

                Button(editTitle, systemImage: "server.rack", action: onEdit)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)

        case .glassIcons:
            HStack(spacing: 8) {
                Button {
                    guard !isConnecting else { return }
                    onRetry()
                } label: {
                    ZStack {
                        if isConnecting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(.primary)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(retryTitle)
                .glassEffect(.regular.interactive(), in: .circle)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(editTitle)
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .fill((isConnecting ? identity.brandColor : Color.secondary).opacity(0.15))
                .frame(width: 36, height: 36)

            Image(systemName: identity.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isConnecting ? identity.brandColor : .secondary)
        }
        .accessibilityHidden(true)
    }
}
