import SwiftUI

struct TrackerListView: View {
    @Bindable var viewModel: TorrentDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false

    var body: some View {
        List {
            if viewModel.trackers.isEmpty {
                ContentUnavailableView(
                    "No Trackers",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("No tracker information available for this torrent.")
                )
            } else {
                Section {
                    ForEach(viewModel.trackers) { tracker in
                        TrackerRow(tracker: tracker)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Trackers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: trackerRefreshToolbarPlacement) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await refreshTrackers() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await viewModel.loadTrackers()
        }
        .refreshable {
            await viewModel.loadTrackers()
        }
    }

    private func refreshTrackers() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        async let refresh: Void = viewModel.loadTrackers()
        async let feedback: Void = {
            try? await Task.sleep(for: .seconds(2))
        }()
        _ = await (refresh, feedback)
        isRefreshing = false
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

#if DEBUG
#Preview("Loaded") {
    let vm = TorrentDetailViewModel(trackers: TorrentTracker.previewList)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
    }
}

#Preview("Empty") {
    let vm = TorrentDetailViewModel(trackers: [])
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
    }
}
#endif
