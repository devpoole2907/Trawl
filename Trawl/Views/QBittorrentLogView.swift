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
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init() {}

    private var displayed: [QBittorrentLogEntry] {
        var results = entries
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, let typeValue = filter.typeValue {
            results = results.filter { $0.type == typeValue }
        } else if !query.isEmpty {
            results = results.filter { $0.message.localizedCaseInsensitiveContains(query) }
        }
        return results
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
        .refreshable {
            await load()
        }
        .background(backgroundGradient)
        .navigationTitle("Logs")
        .navigationSubtitle("qBittorrent")
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
                items: QBLogFilter.allCases.map(\.segmentBarItem),
                searchText: $searchText,
                searchHint: "Search log",
                isSearchExpanded: $isSearchExpanded,
                searchPlacement: .leading,
                alignment: .leading
            )
        }
        .errorAlert(item: $loadError)
        .task {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            await load()
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
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

#if DEBUG
extension QBittorrentLogEntry {
    static let previewList: [QBittorrentLogEntry] = [
        QBittorrentLogEntry(
            id: 1,
            message: "qBittorrent v5.0.3 started",
            timestamp: Int(Date().addingTimeInterval(-3600).timeIntervalSince1970),
            type: 2
        ),
        QBittorrentLogEntry(
            id: 2,
            message: "Successfully listening on IP: 0.0.0.0, port: TCP/6881",
            timestamp: Int(Date().addingTimeInterval(-1800).timeIntervalSince1970),
            type: 1
        ),
        QBittorrentLogEntry(
            id: 3,
            message: "Tracker warning: connection timed out for udp://offline.example.net:6969/announce",
            timestamp: Int(Date().addingTimeInterval(-600).timeIntervalSince1970),
            type: 4
        ),
        QBittorrentLogEntry(
            id: 4,
            message: "File error alert. Torrent: Broken. File: /downloads/Broken.mkv. Reason: permission denied",
            timestamp: Int(Date().addingTimeInterval(-120).timeIntervalSince1970),
            type: 8
        )
    ]
}

extension QBittorrentLogView {
    fileprivate init(
        previewEntries entries: [QBittorrentLogEntry],
        isLoading: Bool = false,
        loadError: ErrorAlertItem? = nil,
        filter: QBLogFilter = .all
    ) {
        self.init()
        self._entries = State(initialValue: entries)
        self._isLoading = State(initialValue: isLoading)
        self._loadError = State(initialValue: loadError)
        self._filter = State(initialValue: filter)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Loaded") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentLogView(previewEntries: QBittorrentLogEntry.previewList)
        }
    }
}

#Preview("Filtered") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentLogView(previewEntries: QBittorrentLogEntry.previewList, filter: .critical)
        }
    }
}

#Preview("Empty") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentLogView(previewEntries: [])
        }
    }
}

#Preview("Loading") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentLogView(previewEntries: [], isLoading: true)
        }
    }
}

#Preview("Error") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentLogView(
                previewEntries: [],
                loadError: ErrorAlertItem(
                    title: "Failed to Load Log",
                    message: "The qBittorrent log endpoint timed out."
                )
            )
        }
    }
}
#endif

private struct QBLogRow: View {
    let entry: QBittorrentLogEntry

    var body: some View {
        LogEntryRow(
            message: entry.message,
            timestamp: Date(timeIntervalSince1970: Double(entry.timestamp))
                .formatted(date: .abbreviated, time: .standard)
        ) {
            Text(severityLabel)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(severityColor.opacity(0.15), in: Capsule())
                .foregroundStyle(severityColor)
        }
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
