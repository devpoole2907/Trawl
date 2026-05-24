import SwiftUI

struct SeerrLogsView: View {
    let apiClient: SeerrAPIClient

    @State private var entries: [SeerrServerLogEntry] = []
    @State private var level: SeerrLogLevelFilter = .debug
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEntry: SeerrServerLogEntry?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var isSearchExpanded = false
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        List {
            if let errorMessage {
                Section("Unavailable") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && entries.isEmpty {
                Section("Logs") {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No Seerr Logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("No server log entries were returned by Seerr.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Logs") {
                    ForEach(entries) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            SeerrLogRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .navigationTitle("Logs")
        .navigationSubtitle("Seerr")
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Level",
                selection: Binding(
                    get: { level },
                    set: { newLevel in withAnimation { level = newLevel } }
                ),
                items: SeerrLogLevelFilter.allCases.map(\.segmentBarItem),
                searchText: $searchText,
                searchHint: "Search logs",
                isSearchExpanded: $isSearchExpanded,
                searchPlacement: .leading
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .refreshable { await loadLogs() }
        .task(id: "\(level.apiValue)|\(committedSearchText)") {
            #if DEBUG
            if isPreview { return }
            #endif
            await loadLogs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await loadLogs(showLoading: false)
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                committedSearchText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .sheet(item: $selectedEntry) { entry in
            SeerrLogDetailSheet(entry: entry)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func loadLogs(showLoading: Bool = true) async {
        if showLoading {
            isLoading = true
        }
        errorMessage = nil

        do {
            let result = try await apiClient.getLogs(
                take: 100,
                filter: level.apiValue,
                search: committedSearchText
            )
            withAnimation(.default) {
                entries = result
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

#if DEBUG
extension SeerrLogsView {
    init(
        apiClient: SeerrAPIClient = .preview(),
        previewEntries: [SeerrServerLogEntry],
        level: SeerrLogLevelFilter = .debug,
        searchText: String = "",
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.apiClient = apiClient
        self._entries = State(initialValue: previewEntries)
        self._level = State(initialValue: level)
        self._searchText = State(initialValue: searchText)
        self._committedSearchText = State(initialValue: searchText)
        self._isLoading = State(initialValue: isLoading)
        self._errorMessage = State(initialValue: errorMessage)
        self.isPreview = true
    }
}

#Preview("Seerr Logs - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrLogsView(previewEntries: SeerrServerLogEntry.previewList)
        }
    }
}

#Preview("Seerr Logs - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrLogsView(previewEntries: [])
        }
    }
}

#Preview("Seerr Logs - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        NavigationStack {
            SeerrLogsView(previewEntries: [], isLoading: true)
        }
    }
}

#Preview("Seerr Logs - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to load logs."))) {
        NavigationStack {
            SeerrLogsView(
                previewEntries: [],
                errorMessage: "Server log endpoint timed out."
            )
        }
    }
}

#Preview("Seerr Log Detail") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        SeerrLogDetailSheet(entry: .preview)
    }
}
#endif

struct SeerrLogRow: View {
    let entry: SeerrServerLogEntry

    var body: some View {
        LogEntryRow(
            message: entry.message ?? "No message",
            timestamp: entry.timestampDate.map { $0.formatted(date: .abbreviated, time: .standard) } ?? ""
        ) {
            Text(entry.level?.uppercased() ?? "LOG")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(levelTint.opacity(0.16), in: Capsule())
                .foregroundStyle(levelTint)

            if let label = entry.label, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var levelTint: Color {
        switch entry.level?.lowercased() {
        case "error": .red
        case "warn", "warning": .orange
        case "info": .blue
        default: .secondary
        }
    }
}

private struct SeerrLogDetailSheet: View {
    let entry: SeerrServerLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppSheetShell(title: "Log Details") {
            Form {
                Section("Timestamp") {
                    Text(timestampText)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                Section("Severity") {
                    HStack(spacing: 8) {
                        Image(systemName: severityIcon)
                            .foregroundStyle(severityTint)
                        Text(entry.level?.uppercased() ?? "LOG")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(severityTint)
                    }
                }

                if let label = entry.label, !label.isEmpty {
                    Section("Label") {
                        Text(label)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }

                Section("Message") {
                    Text(entry.message ?? "No message")
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                if let prettyData = entry.prettyPrintedData {
                    Section("Additional Data") {
                        Text(prettyData)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var timestampText: String {
        if let date = entry.timestampDate {
            return date.formatted(date: .long, time: .standard)
        }
        return entry.timestamp ?? "Unknown"
    }

    private var severityIcon: String {
        switch entry.level?.lowercased() {
        case "error": return "xmark.octagon.fill"
        case "warn", "warning": return "exclamationmark.triangle.fill"
        case "info": return "info.circle.fill"
        default: return "ant.fill"
        }
    }

    private var severityTint: Color {
        switch entry.level?.lowercased() {
        case "error": return .red
        case "warn", "warning": return .orange
        case "info": return .blue
        default: return .secondary
        }
    }
}
