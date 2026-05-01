import SwiftUI

struct TrackerListView: View {
    @Bindable var viewModel: TorrentDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            backgroundGradient
            
            ScrollView {
                VStack(spacing: 12) {
                    if viewModel.trackers.isEmpty {
                        ContentUnavailableView(
                            "No Trackers",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("No tracker information available for this torrent.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(viewModel.trackers) { tracker in
                            TrackerRow(tracker: tracker)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Trackers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: trackerRefreshToolbarPlacement) {
                Button {
                    Task { await viewModel.loadTrackers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await viewModel.loadTrackers()
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.indigo.opacity(0.12), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct TrackerRow: View {
    let tracker: TorrentTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayUrl)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    
                    if tracker.tier >= 0 {
                        Text("Tier \(tracker.tier)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                statusBadge
            }

            HStack(spacing: 16) {
                statLabel(value: "\(tracker.numSeeds)", icon: "arrow.up.circle.fill", color: .green, label: "Seeds")
                statLabel(value: "\(tracker.numLeeches)", icon: "arrow.down.circle.fill", color: .blue, label: "Leeches")
                statLabel(value: "\(tracker.numPeers)", icon: "person.2.fill", color: .secondary, label: "Peers")
            }

            if !tracker.msg.isEmpty {
                Text(tracker.msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var displayUrl: String {
        tracker.url.replacingOccurrences(of: "udp://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    private func statLabel(value: String, icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.caption.weight(.medium))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch tracker.status {
        case 0: "Disabled"
        case 1: "Not Contacted"
        case 2: "Working"
        case 3: "Updating"
        case 4: "Not Working"
        default: "Unknown"
        }
    }

    private var statusColor: Color {
        switch tracker.status {
        case 2: .green
        case 3: .orange
        case 4: .red
        default: .secondary
        }
    }
}

private var trackerRefreshToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
}
