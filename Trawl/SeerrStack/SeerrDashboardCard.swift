import SwiftUI

struct SeerrDashboardCard: View {
    let requestCount: SeerrRequestCount?
    let apiClient: SeerrAPIClient

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Admin Dashboard")
                        .font(.headline)
                    Text("Approvals, queue health, and user access")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if requestCount != nil {
                    pendingBadge
                }
            }

            if requestCount != nil {
                HStack(spacing: 24) {
                    statBlock(title: "Total", value: requestCount?.total ?? 0)
                    statBlock(title: "Movies", value: requestCount?.movie ?? 0)
                    statBlock(title: "TV", value: requestCount?.tv ?? 0)
                }

                if let pending = requestCount?.pending, pending > 0 {
                    Text(pending == 1 ? "1 request is waiting for approval." : "\(pending) requests are waiting for approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                SeerrUserManagementView(apiClient: apiClient)
            } label: {
                HStack {
                    Label("Manage Users", systemImage: "person.2.badge.gearshape")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var pendingBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(requestCount?.pending ?? 0)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text("Pending")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.orange)
    }

    private func statBlock(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
