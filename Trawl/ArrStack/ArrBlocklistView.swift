import SwiftUI

struct ArrBlocklistView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var scope: BlocklistScope = .all
    @State private var showClearConfirm = false
    @State private var entryToDelete: BlocklistEntry?

    enum BlocklistScope: String, CaseIterable, Identifiable {
        case all = "All"
        case series = "Series"
        case movies = "Movies"
        var id: String { rawValue }
    }

    struct BlocklistEntry: Identifiable {
        let item: ArrBlocklistItem
        let source: ArrServiceType

        var id: String { "\(source.rawValue)-\(item.id)" }
    }

    private var displayedSonarrItems: [ArrBlocklistItem] {
        guard serviceManager.sonarrConnected else { return [] }
        return scope == .movies ? [] : serviceManager.sonarrBlocklist
    }

    private var displayedRadarrItems: [ArrBlocklistItem] {
        guard serviceManager.radarrConnected else { return [] }
        return scope == .series ? [] : serviceManager.radarrBlocklist
    }

    private var isEmpty: Bool {
        displayedSonarrItems.isEmpty && displayedRadarrItems.isEmpty
    }

    private var hasConfigured: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var hasConnected: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var allEntries: [BlocklistEntry] {
        let sonarrEntries = displayedSonarrItems.map { BlocklistEntry(item: $0, source: .sonarr) }
        let radarrEntries = displayedRadarrItems.map { BlocklistEntry(item: $0, source: .radarr) }
        return (sonarrEntries + radarrEntries).sorted { lhs, rhs in
            (blockDate(for: lhs.item) ?? .distantPast) > (blockDate(for: rhs.item) ?? .distantPast)
        }
    }

    private var navigationSubtitle: String {
        let count = allEntries.count
        guard count > 0 else { return "" }
        return count == 1 ? "1 blocked release" : "\(count) blocked releases"
    }

    var body: some View {
        Group {
            if !hasConfigured {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "server.rack",
                    description: Text("Connect Sonarr or Radarr to manage the blocklist.")
                )
            } else if !hasConnected {
                ContentUnavailableView(
                    "Services Unreachable",
                    systemImage: "network.slash",
                    description: Text("Unable to reach your configured Sonarr or Radarr servers.")
                )
            } else if serviceManager.isLoadingBlocklist && serviceManager.sonarrBlocklist.isEmpty && serviceManager.radarrBlocklist.isEmpty {
                ProgressView("Loading blocklist…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                ContentUnavailableView(
                    "Blocklist Empty",
                    systemImage: "checkmark.shield",
                    description: Text("No blocked releases for the selected scope.")
                )
            } else {
                blocklistContent
            }
        }
        .background(backgroundGradient)
        .navigationTitle("Blocklist")
        .navigationSubtitle(navigationSubtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BlocklistToolbarMenu(
                    scope: $scope,
                    canFilterAcrossServices: serviceManager.sonarrConnected && serviceManager.radarrConnected,
                    isEmpty: isEmpty,
                    onClearAll: { showClearConfirm = true }
                )
            }
        }
        .alert("Clear Blocklist?", isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) {
                Task { await clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All blocked releases for the selected scope will be removed.")
        }
        .alert("Unblock Release?", isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Unblock", role: .destructive) {
                if let entry = entryToDelete {
                    Task { await deleteEntry(entry) }
                    entryToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            if let entry = entryToDelete {
                Text("This will unblock \"\(entry.item.sourceTitle ?? "Unknown Release")\" and allow it to be downloaded again.")
            }
        }
        .refreshable { await serviceManager.loadBlocklist() }
        .task { await serviceManager.loadBlocklist() }
    }

    @ViewBuilder
    private var blocklistContent: some View {
        List {
            ForEach(allEntries) { entry in
                BlocklistRow(entry: entry)
                    .swipeActions(allowsFullSwipe: false) {
                        Button {
                            entryToDelete = entry
                        } label: {
                            Label("Unblock", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.red)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.red.opacity(0.16), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.red.opacity(0.12), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    private func blockDate(for item: ArrBlocklistItem) -> Date? {
        BlocklistDateParser.parse(item.date)
    }

    // MARK: - Actions

    private func deleteEntry(_ entry: BlocklistEntry) async {
        await serviceManager.removeBlocklistItem(id: entry.item.id, source: entry.source)
    }

    private func clearAll() async {
        let sonarrIDs = displayedSonarrItems.map(\.id)
        let radarrIDs = displayedRadarrItems.map(\.id)
        await serviceManager.clearBlocklist(sonarrIDs: sonarrIDs, radarrIDs: radarrIDs)
    }
}

private struct BlocklistToolbarMenu: View {
    @Binding var scope: ArrBlocklistView.BlocklistScope
    let canFilterAcrossServices: Bool
    let isEmpty: Bool
    let onClearAll: () -> Void

    var body: some View {
        if canFilterAcrossServices || !isEmpty {
            Menu {
                if canFilterAcrossServices {
                    Picker("Scope", selection: $scope) {
                        Label("All", systemImage: "square.grid.2x2").tag(ArrBlocklistView.BlocklistScope.all)
                        Label("Series", systemImage: "tv").tag(ArrBlocklistView.BlocklistScope.series)
                        Label("Movies", systemImage: "film").tag(ArrBlocklistView.BlocklistScope.movies)
                    }
                }
                if !isEmpty {
                    if canFilterAcrossServices {
                        Divider()
                    }
                    Button("Clear All", role: .destructive, action: onClearAll)
                }
            } label: {
                Image(systemName: scope == .all
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                .accessibilityLabel("Filter scope")
            }
        }
    }
}

// MARK: - Blocklist Row

private struct BlocklistRow: View {
    let entry: ArrBlocklistView.BlocklistEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.source == ArrServiceType.sonarr ? "tv" : "film")
                .foregroundStyle(entry.source == ArrServiceType.sonarr ? Color.purple : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.item.sourceTitle ?? "Unknown Release")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(entry.source.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.source == ArrServiceType.sonarr ? Color.purple : Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((entry.source == ArrServiceType.sonarr ? Color.purple : Color.orange).opacity(0.14))
                        .clipShape(Capsule())
                }

                HStack(spacing: 4) {
                    let hasIndexer = entry.item.indexer?.isEmpty == false

                    if let indexer = entry.item.indexer, hasIndexer {
                        Label(indexer, systemImage: "magnifyingglass")
                    }
                    if let quality = entry.item.quality?.quality?.name, !quality.isEmpty {
                        if hasIndexer {
                            Text("·")
                        }
                        Text(quality)
                    }
                    if let date = blockDate(for: entry.item) {
                        Text("·")
                        Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let message = entry.item.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func blockDate(for item: ArrBlocklistItem) -> Date? {
        BlocklistDateParser.parse(item.date)
    }
}

private enum BlocklistDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalISO.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }
}