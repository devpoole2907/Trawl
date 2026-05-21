import SwiftUI

struct ConnectionStatusCard: View {
    enum Presentation {
        case card
        case embedded
    }

    let identity: ServiceIdentity?
    let title: String
    let message: String
    let isConnecting: Bool
    var detailTitle: String?
    var detailSubtitle: String?
    var retryTitle = "Retry Connection"
    var editTitle = "Edit Server"
    var presentation: Presentation = .card
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .card:
            cardContent
        case .embedded:
            embeddedContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                statusIcon

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detailTitle {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(detailTitle)
                                .font(.subheadline.weight(.medium))
                            if let detailSubtitle {
                                Text(detailSubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                if onRetry != nil || onEdit != nil {
                    cardActions
                } else {
                    Spacer(minLength: 0)
                }
            }

            connectionTiming
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge))
        .overlay {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge)
                .strokeBorder(.quaternary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: isConnecting)
    }

    private var cardActions: some View {
        HStack(spacing: 8) {
            if let onRetry {
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
            }

            if let onEdit {
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

    private var embeddedContent: some View {
        VStack(spacing: 16) {
            embeddedStatusIcon

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let detailTitle {
                    VStack(spacing: 4) {
                        Text(detailTitle)
                        if let detailSubtitle {
                            Text(detailSubtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                }
            }

            connectionTiming

            if onRetry != nil || onEdit != nil {
                VStack(spacing: 14) {
                    if let onRetry {
                        Button(retryTitle, systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .disabled(isConnecting)
                    }

                    if let onEdit {
                        Button(editTitle, systemImage: "server.rack", action: onEdit)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: isConnecting)
    }

    private var statusIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .fill(statusColor.opacity(0.15))
                .frame(width: 44, height: 44)

            Image(systemName: identity?.systemImage ?? "network.slash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var embeddedStatusIcon: some View {
        if isConnecting {
            ProgressView()
                .controlSize(.regular)
                .tint(statusColor)
        } else {
            Image(systemName: identity?.systemImage ?? "network.slash")
                .font(.system(size: 102, weight: .semibold))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var connectionTiming: some View {
        if !isConnecting, onRetry != nil {
            ConnectionRetryCountdownView()
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var statusColor: Color {
        if isConnecting {
            return identity?.brandColor ?? .accentColor
        }
        return .secondary
    }
}
