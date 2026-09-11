import SwiftUI

/// The shared identity treatment for Prowlarr and direct Arr indexers.
enum IndexerDetailStatus {
    case active
    case disabled
    case temporarilyDisabled

    var label: String {
        switch self {
        case .active: "Active"
        case .disabled: "Disabled"
        case .temporarilyDisabled: "Temporarily Disabled"
        }
    }

    var icon: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .disabled: "pause.circle.fill"
        case .temporarilyDisabled: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .disabled: .secondary
        case .temporarilyDisabled: .orange
        }
    }
}

struct IndexerDetailHeader: View {
    let title: String
    let subtitle: String
    let tint: Color
    let status: IndexerDetailStatus

    var body: some View {
        TrawlEntityHeader(
            title: title,
            subtitle: subtitle,
            systemImage: "magnifyingglass",
            tint: tint,
            badges: [
                ArrDetailBadge(
                    icon: status.icon,
                    label: status.label,
                    color: status.color
                )
            ]
        )
    }
}
