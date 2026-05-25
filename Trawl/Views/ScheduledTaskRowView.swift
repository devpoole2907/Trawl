import SwiftUI

struct ScheduledTaskRowView<Action: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let badge: ScheduledTaskRowBadge?
    let details: [ScheduledTaskRowDetail]
    let progress: Double?
    let result: ScheduledTaskRowResult?
    @ViewBuilder let action: Action

    init(
        icon: String = "clock",
        iconColor: Color = .secondary,
        title: String,
        subtitle: String? = nil,
        badge: ScheduledTaskRowBadge? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.details = details
        self.progress = progress
        self.result = result
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if let badge {
                        ScheduledTaskBadgeView(badge: badge)
                    }
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !details.isEmpty {
                    ScheduledTaskDetailFlowLayout(horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(details) { detail in
                            HStack(spacing: 3) {
                                Image(systemName: detail.icon)
                                    .imageScale(.small)
                                    .accessibilityHidden(true)

                                Text(detail.text)
                                    .lineLimit(1)
                            }
                                .font(.caption2)
                                .foregroundStyle(detail.color)
                        }
                    }
                }

                if let progress {
                    ProgressView(value: progress, total: 100)
                        .tint(.green)
                }

                if let result {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(result.color)
                            .frame(width: 6, height: 6)

                        Text(result.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(result.color)

                        if let detail = result.detail, !detail.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            action
        }
        .padding(.vertical, 4)
    }
}

extension ScheduledTaskRowView {
    init(
        status: ScheduledTaskRowStatus,
        title: String,
        subtitle: String? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.init(
            icon: status.icon,
            iconColor: status.color,
            title: title,
            subtitle: subtitle,
            badge: status.badge,
            details: details,
            progress: progress,
            result: result,
            action: action
        )
    }
}

extension ScheduledTaskRowView where Action == EmptyView {
    init(
        icon: String = "clock",
        iconColor: Color = .secondary,
        title: String,
        subtitle: String? = nil,
        badge: ScheduledTaskRowBadge? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil
    ) {
        self.init(
            icon: icon,
            iconColor: iconColor,
            title: title,
            subtitle: subtitle,
            badge: badge,
            details: details,
            progress: progress,
            result: result
        ) {
            EmptyView()
        }
    }
}

extension ScheduledTaskRowView where Action == ScheduledTaskRowActionButton {
    init(
        icon: String = "clock",
        iconColor: Color = .secondary,
        title: String,
        subtitle: String? = nil,
        badge: ScheduledTaskRowBadge? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        action: ScheduledTaskRowAction
    ) {
        self.init(
            icon: icon,
            iconColor: iconColor,
            title: title,
            subtitle: subtitle,
            badge: badge,
            details: details,
            progress: progress,
            result: result
        ) {
            ScheduledTaskRowActionButton(action: action)
        }
    }

    init(
        status: ScheduledTaskRowStatus,
        title: String,
        subtitle: String? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        action: ScheduledTaskRowAction
    ) {
        self.init(
            status: status,
            title: title,
            subtitle: subtitle,
            details: details,
            progress: progress,
            result: result
        ) {
            ScheduledTaskRowActionButton(action: action)
        }
    }
}

struct ScheduledTaskRowBadge {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

struct ScheduledTaskRowStatus {
    let title: String
    let icon: String
    let color: Color

    var badge: ScheduledTaskRowBadge {
        ScheduledTaskRowBadge(title, color: color)
    }

    static let idle = ScheduledTaskRowStatus(
        title: "Idle",
        icon: "clock",
        color: .secondary
    )

    static let running = ScheduledTaskRowStatus(
        title: "Running",
        icon: "clock.arrow.2.circlepath",
        color: .green
    )

    static let cancelling = ScheduledTaskRowStatus(
        title: "Cancelling",
        icon: "clock.arrow.2.circlepath",
        color: .orange
    )
}

struct ScheduledTaskRowDetail: Identifiable {
    let id: String
    let icon: String
    let text: String
    let color: Color

    init(icon: String, text: String, color: Color = .secondary) {
        self.id = "\(icon)-\(text)"
        self.icon = icon
        self.text = text
        self.color = color
    }
}

struct ScheduledTaskRowAction: Sendable {
    let accessibilityLabel: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let perform: @MainActor @Sendable () async -> Void

    init(
        accessibilityLabel: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.systemImage = systemImage
        self.tint = tint
        self.isDisabled = isDisabled
        self.perform = perform
    }

    static func run(
        accessibilityLabel: String = "Run task",
        systemImage: String = "play.circle",
        tint: Color = .green,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        ScheduledTaskRowAction(
            accessibilityLabel: accessibilityLabel,
            systemImage: systemImage,
            tint: tint,
            isDisabled: isDisabled,
            perform: perform
        )
    }

    static func stop(
        accessibilityLabel: String = "Stop task",
        systemImage: String = "stop.circle",
        tint: Color = .red,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        ScheduledTaskRowAction(
            accessibilityLabel: accessibilityLabel,
            systemImage: systemImage,
            tint: tint,
            isDisabled: isDisabled,
            perform: perform
        )
    }
}

struct ScheduledTaskRowActionButton: View {
    let action: ScheduledTaskRowAction
    @State private var isPerforming = false

    var body: some View {
        Button {
            performAction()
        } label: {
            Group {
                if isPerforming {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                } else {
                    Label(action.accessibilityLabel, systemImage: action.systemImage)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(action.isDisabled ? Color.secondary.opacity(0.4) : action.tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.isDisabled || isPerforming)
        .accessibilityLabel(action.accessibilityLabel)
        .help(action.accessibilityLabel)
    }

    @MainActor
    private func performAction() {
        guard !action.isDisabled, !isPerforming else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isPerforming = true
        }

        Task { @MainActor in
            defer {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isPerforming = false
                }
            }
            await action.perform()
        }
    }
}

struct ScheduledTaskRowResult {
    let title: String
    let detail: String?
    let color: Color

    init(title: String, detail: String? = nil, color: Color) {
        self.title = title
        self.detail = detail
        self.color = color
    }
}

private struct ScheduledTaskBadgeView: View {
    let badge: ScheduledTaskRowBadge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badge.color.opacity(0.15), in: Capsule())
            .foregroundStyle(badge.color)
    }
}

private struct ScheduledTaskDetailFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, proposal: proposal)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, proposal: proposal)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: element.size.width, height: element.size.height)
                )
                x += element.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for subviews: Subviews, proposal: ProposedViewSize) -> [Row] {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if current.width > 0, current.width + horizontalSpacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.append(subview: subview, size: size, spacing: horizontalSpacing)
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }

        return rows
    }

    private struct Row {
        var elements: [Element] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(subview: LayoutSubview, size: CGSize, spacing: CGFloat) {
            if !elements.isEmpty {
                width += spacing
            }
            elements.append(Element(subview: subview, size: size))
            width += size.width
            height = max(height, size.height)
        }
    }

    private struct Element {
        let subview: LayoutSubview
        let size: CGSize
    }
}
