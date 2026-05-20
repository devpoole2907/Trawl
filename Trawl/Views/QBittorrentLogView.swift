import SwiftUI

private enum QBLogFilter: String, CaseIterable {
    case all = "All"
    case normal = "Normal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"

    var typeValue: Int? {
        switch self {
        case .all: nil
        case .normal: 1
        case .info: 2
        case .warning: 4
        case .critical: 8
        }
    }

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}

struct QBittorrentLogView: View {
    @Environment(TorrentService.self) private var torrentService

    @State private var entries: [QBittorrentLogEntry] = []
    @State private var isLoading = false
    @State private var loadError: ErrorAlertItem?
    @State private var filter: QBLogFilter = .all

    private var displayed: [QBittorrentLogEntry] {
        guard let typeValue = filter.typeValue else { return entries }
        return entries.filter { $0.type == typeValue }
    }

    var body: some View {
        List {
            if isLoading && entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if displayed.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "doc.text",
                    description: Text(entries.isEmpty
                        ? "No log entries found."
                        : "No entries match the selected filter.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(displayed) { entry in
                        QBLogRow(entry: entry)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .navigationTitle("qBittorrent Log")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Filter",
                selection: Binding(
                    get: { filter },
                    set: { newFilter in withAnimation { filter = newFilter } }
                ),
                items: QBLogFilter.allCases.map(\.segmentBarItem)
            )
        }
        .errorAlert(item: $loadError)
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.15), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.blue.opacity(0.10), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }

    private func load() async {
        isLoading = true
        do {
            let all = try await torrentService.getMainLog()
            entries = all.reversed()
        } catch {
            loadError = ErrorAlertItem(title: "Failed to Load Log", message: error.localizedDescription)
        }
        isLoading = false
    }
}

private struct QBLogRow: View {
    let entry: QBittorrentLogEntry

    private var date: Date {
        Date(timeIntervalSince1970: Double(entry.timestamp))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                severityBadge
                Spacer()
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var severityBadge: some View {
        Text(severityLabel)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(severityColor.opacity(0.15))
            .foregroundStyle(severityColor)
            .clipShape(Capsule())
    }

    private var severityLabel: String {
        switch entry.type {
        case 1: "Normal"
        case 2: "Info"
        case 4: "Warning"
        case 8: "Critical"
        default: "Log"
        }
    }

    private var severityColor: Color {
        switch entry.type {
        case 1: .secondary
        case 2: .blue
        case 4: .orange
        case 8: .red
        default: .secondary
        }
    }
}

