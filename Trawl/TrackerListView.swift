import SwiftUI

struct TrackerListView: View {
    @Bindable var viewModel: TorrentDetailViewModel

    var body: some View {
        List {
            if viewModel.trackers.isEmpty {
                ContentUnavailableView("No Trackers", systemImage: "antenna.radiowaves.left.and.right", description: Text("No tracker information available."))
            } else {
                ForEach(viewModel.trackers) { tracker in
                    TrackerRow(tracker: tracker)
                }
            }
        }
        .navigationTitle("Trackers")
        .task {
            await viewModel.loadTrackers()
        }
    }
}

private struct TrackerRow: View {
    let tracker: TorrentTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tracker.url)
                .font(.subheadline)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Label("\(tracker.numSeeds)", systemImage: "arrow.up")
                    .font(.caption)
                    .foregroundStyle(.green)

                Label("\(tracker.numLeeches)", systemImage: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.blue)

                Label("\(tracker.numPeers)", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if !tracker.msg.isEmpty {
                Text(tracker.msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch tracker.status {
        case 0: "Disabled"
        case 1: "Not contacted"
        case 2: "Working"
        case 3: "Updating"
        case 4: "Not working"
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
