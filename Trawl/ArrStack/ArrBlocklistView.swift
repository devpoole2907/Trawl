import SwiftUI

struct ArrBlocklistView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var mode: SuppressionMode = .blocklist
    @State private var scope: BlocklistScope = .all
    @State private var showClearConfirm = false
    @State private var entryToDelete: BlocklistEntry?
    @State private var exclusionToDelete: ExclusionEntry?
    @State private var showSettings = false
    @State private var suppressionSearchText = ""
    @State private var isSearchExpanded = false
    private let previewSonarrBlocklist: [ArrBlocklistItem]?
    private let previewRadarrBlocklist: [ArrBlocklistItem]?
    private let previewSonarrExclusions: [ArrImportListExclusion]?
    private let previewRadarrExclusions: [ArrImportListExclusion]?

    init(
        previewSonarrBlocklist: [ArrBlocklistItem]? = nil,
        previewRadarrBlocklist: [ArrBlocklistItem]? = nil,
        previewSonarrExclusions: [ArrImportListExclusion]? = nil,
        previewRadarrExclusions: [ArrImportListExclusion]? = nil,
        initialMode: SuppressionMode = .blocklist
    ) {
        self.previewSonarrBlocklist = previewSonarrBlocklist
        self.previewRadarrBlocklist = previewRadarrBlocklist
        self.previewSonarrExclusions = previewSonarrExclusions
        self.previewRadarrExclusions = previewRadarrExclusions
        _mode = State(initialValue: initialMode)
    }

    enum SuppressionMode: String, CaseIterable, Identifiable {
        case blocklist = "Blocklist"
        case exclusions = "Exclusions"

        var id: String { rawValue }

        var segmentBarItem: TrawlSegmentBarItem<Self> {
            TrawlSegmentBarItem(rawValue, value: self)
        }
    }

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

    struct ExclusionEntry: Identifiable {
        let item: ArrImportListExclusion
        let source: ArrServiceType

        var id: String { "\(source.rawValue)-\(item.id)" }
    }

    private var displayedSonarrItems: [ArrBlocklistItem] {
        let items: [ArrBlocklistItem]
        if let previewSonarrBlocklist {
            items = previewSonarrBlocklist
        } else {
            guard serviceManager.sonarrConnected else { return [] }
            items = serviceManager.sonarrBlocklist
        }
        guard scope != .movies else { return [] }
        return items
    }

    private var allSonarrItems: [ArrBlocklistItem] {
        if let previewSonarrBlocklist {
            return previewSonarrBlocklist
        }
        guard serviceManager.sonarrConnected else { return [] }
        return serviceManager.sonarrBlocklist
    }

    private var displayedRadarrItems: [ArrBlocklistItem] {
        let items: [ArrBlocklistItem]
        if let previewRadarrBlocklist {
            items = previewRadarrBlocklist
        } else {
            guard serviceManager.radarrConnected else { return [] }
            items = serviceManager.radarrBlocklist
        }
        guard scope != .series else { return [] }
        return items
    }

    private var allRadarrItems: [ArrBlocklistItem] {
        if let previewRadarrBlocklist { return previewRadarrBlocklist }
        guard serviceManager.radarrConnected else { return [] }
        return serviceManager.radarrBlocklist
    }

    private var displayedSonarrExclusions: [ArrImportListExclusion] {
        let items: [ArrImportListExclusion]
        if let previewSonarrExclusions {
            items = previewSonarrExclusions
        } else {
            guard serviceManager.sonarrConnected else { return [] }
            items = serviceManager.sonarrImportListExclusions
        }
        guard scope != .movies else { return [] }
        return items
    }

    private var allSonarrExclusions: [ArrImportListExclusion] {
        if let previewSonarrExclusions { return previewSonarrExclusions }
        guard serviceManager.sonarrConnected else { return [] }
        return serviceManager.sonarrImportListExclusions
    }

    private var displayedRadarrExclusions: [ArrImportListExclusion] {
        let items: [ArrImportListExclusion]
        if let previewRadarrExclusions {
            items = previewRadarrExclusions
        } else {
            guard serviceManager.radarrConnected else { return [] }
            items = serviceManager.radarrImportListExclusions
        }
        guard scope != .series else { return [] }
        return items
    }

    private var allRadarrExclusions: [ArrImportListExclusion] {
        if let previewRadarrExclusions { return previewRadarrExclusions }
        guard serviceManager.radarrConnected else { return [] }
        return serviceManager.radarrImportListExclusions
    }

    private var isEmpty: Bool {
        switch mode {
        case .blocklist:
            displayedSonarrItems.isEmpty && displayedRadarrItems.isEmpty
        case .exclusions:
            displayedSonarrExclusions.isEmpty && displayedRadarrExclusions.isEmpty
        }
    }

    private var hasFilterableBlocklistItems: Bool {
        switch mode {
        case .blocklist:
            (serviceManager.sonarrConnected && !serviceManager.sonarrBlocklist.isEmpty) ||
            (serviceManager.radarrConnected && !serviceManager.radarrBlocklist.isEmpty)
        case .exclusions:
            (serviceManager.sonarrConnected && !serviceManager.sonarrImportListExclusions.isEmpty) ||
            (serviceManager.radarrConnected && !serviceManager.radarrImportListExclusions.isEmpty)
        }
    }

    private var hasConfigured: Bool {
        if hasPreviewData { return true }
        return serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var blocklistServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasConnected: Bool {
        if hasPreviewData { return true }
        return serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var hasPreviewData: Bool {
        previewSonarrBlocklist != nil ||
        previewRadarrBlocklist != nil ||
        previewSonarrExclusions != nil ||
        previewRadarrExclusions != nil
    }

    private var isConnecting: Bool {
        guard !hasConnected else { return false }
        return serviceManager.isInitializing ||
            serviceManager.isConnecting(.sonarr) ||
            serviceManager.isConnecting(.radarr)
    }

    private var blocklistSettingsService: ArrServiceType {
        if serviceManager.hasSonarrInstance && !serviceManager.sonarrConnected { return .sonarr }
        return .radarr
    }

    private var allEntries: [BlocklistEntry] {
        let sonarrEntries = displayedSonarrItems.map { BlocklistEntry(item: $0, source: .sonarr) }
        let radarrEntries = displayedRadarrItems.map { BlocklistEntry(item: $0, source: .radarr) }
        return (sonarrEntries + radarrEntries).sorted { lhs, rhs in
            (blockDate(for: lhs.item) ?? .distantPast) > (blockDate(for: rhs.item) ?? .distantPast)
        }
    }

    private var allExclusionEntries: [ExclusionEntry] {
        let sonarrEntries = displayedSonarrExclusions.map { ExclusionEntry(item: $0, source: .sonarr) }
        let radarrEntries = displayedRadarrExclusions.map { ExclusionEntry(item: $0, source: .radarr) }
        return (sonarrEntries + radarrEntries).sorted { lhs, rhs in
            lhs.item.displayTitle.localizedCaseInsensitiveCompare(rhs.item.displayTitle) == .orderedAscending
        }
    }

    private var suppressionSearchQuery: String {
        suppressionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSuppressionSearch: Bool {
        !suppressionSearchQuery.isEmpty
    }

    private var allBlocklistSearchEntries: [BlocklistEntry] {
        (allSonarrItems.map { BlocklistEntry(item: $0, source: .sonarr) } +
         allRadarrItems.map { BlocklistEntry(item: $0, source: .radarr) })
            .sorted { lhs, rhs in
                (blockDate(for: lhs.item) ?? .distantPast) > (blockDate(for: rhs.item) ?? .distantPast)
            }
    }

    private var allExclusionSearchEntries: [ExclusionEntry] {
        (allSonarrExclusions.map { ExclusionEntry(item: $0, source: .sonarr) } +
         allRadarrExclusions.map { ExclusionEntry(item: $0, source: .radarr) })
            .sorted { lhs, rhs in
                lhs.item.displayTitle.localizedCaseInsensitiveCompare(rhs.item.displayTitle) == .orderedAscending
            }
    }

    private var navigationSubtitle: String {
        switch mode {
        case .blocklist:
            let count = allEntries.count
            guard count > 0 else { return "" }
            return count == 1 ? "1 blocked release" : "\(count) blocked releases"
        case .exclusions:
            let count = allExclusionEntries.count
            guard count > 0 else { return "" }
            return count == 1 ? "1 import-list exclusion" : "\(count) import-list exclusions"
        }
    }

    private var isLoadingCurrentMode: Bool {
        switch mode {
        case .blocklist:
            serviceManager.isLoadingBlocklist && serviceManager.sonarrBlocklist.isEmpty && serviceManager.radarrBlocklist.isEmpty
        case .exclusions:
            serviceManager.isLoadingImportListExclusions &&
            serviceManager.sonarrImportListExclusions.isEmpty &&
            serviceManager.radarrImportListExclusions.isEmpty
        }
    }

    private var currentError: String? {
        switch mode {
        case .blocklist: serviceManager.blocklistError
        case .exclusions: serviceManager.importListExclusionsError
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch mode {
        case .blocklist: "Blocklist Empty"
        case .exclusions: "No Exclusions"
        }
    }

    private var emptyIcon: String {
        switch mode {
        case .blocklist: "checkmark.shield"
        case .exclusions: "list.bullet.rectangle"
        }
    }

    private var emptyDescription: LocalizedStringKey {
        switch mode {
        case .blocklist: "No blocked releases for the selected scope."
        case .exclusions: "No import-list exclusions for the selected scope."
        }
    }

    private var clearAlertTitle: String {
        switch mode {
        case .blocklist: "Clear Blocklist?"
        case .exclusions: "Clear Exclusions?"
        }
    }

    private var clearAlertMessage: String {
        switch mode {
        case .blocklist:
            "All blocked releases for the selected scope will be removed."
        case .exclusions:
            "All import-list exclusions for the selected scope will be removed."
        }
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
                ArrServicesConnectionStatusView(
                    services: blocklistServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else {
                ArrLoadingErrorEmptyView(
                    isLoading: isLoadingCurrentMode,
                    error: currentError,
                    isEmpty: hasSuppressionSearch ? false : isEmpty,
                    emptyTitle: emptyTitle,
                    emptyIcon: emptyIcon,
                    emptyDescription: emptyDescription,
                    onRetry: { await loadCurrentMode() }
                ) {
                    if hasSuppressionSearch {
                        searchContent
                    } else {
                        switch mode {
                        case .blocklist:
                            blocklistContent
                        case .exclusions:
                            exclusionsContent
                        }
                    }
                }
            }
        }
        .background(backgroundGradient)
        .navigationTitle("Blocked & Excluded")
        .navigationSubtitle(navigationSubtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Type",
                selection: Binding(
                    get: { mode },
                    set: { newMode in withAnimation { mode = newMode } }
                ),
                items: SuppressionMode.allCases.map(\.segmentBarItem),
                searchText: $suppressionSearchText,
                searchHint: "Search blocked items",
                isSearchExpanded: $isSearchExpanded,
                searchPlacement: .leading,
                alignment: .leading
            )
        }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                BlocklistToolbarMenu(
                    scope: $scope,
                    mode: mode,
                    canFilter: hasFilterableBlocklistItems,
                    isEmpty: isEmpty,
                    onClearAll: { showClearConfirm = true }
                )
            }
        }
        .alert(clearAlertTitle, isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) {
                Task { await clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearAlertMessage)
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
        .alert("Remove Exclusion?", isPresented: Binding(
            get: { exclusionToDelete != nil },
            set: { if !$0 { exclusionToDelete = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let entry = exclusionToDelete {
                    Task { await deleteExclusion(entry) }
                    exclusionToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                exclusionToDelete = nil
            }
        } message: {
            if let entry = exclusionToDelete {
                Text("This will allow \"\(entry.item.displayTitle)\" to be added again by import lists.")
            }
        }
        .refreshable { await loadCurrentMode() }
        .task(id: mode) { await loadCurrentMode() }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: blocklistSettingsService)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let sections = suppressionSearchSections(matching: suppressionSearchQuery)

        List {
            if sections.isEmpty {
                ContentUnavailableView.search(text: suppressionSearchQuery)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            switch item.kind {
                            case .blocklist(let entry):
                                BlocklistRow(entry: entry)
                                    .swipeActions(allowsFullSwipe: false) {
                                        Button {
                                            entryToDelete = entry
                                        } label: {
                                            Label("Unblock", systemImage: "arrow.uturn.backward")
                                        }
                                        .tint(.red)
                                    }
                            case .exclusion(let entry):
                                ExclusionRow(entry: entry)
                                    .swipeActions(allowsFullSwipe: false) {
                                        Button {
                                            exclusionToDelete = entry
                                        } label: {
                                            Label("Remove", systemImage: "arrow.uturn.backward")
                                        }
                                        .tint(.red)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .animation(.default, value: sections.map(\.id))
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
    }

    private func suppressionSearchSections(matching query: String) -> [SuppressionSearchSection] {
        let blocklistSections = [ArrServiceType.sonarr, .radarr].compactMap { service -> SuppressionSearchSection? in
            let entries = allBlocklistSearchEntries
                .filter { $0.source == service && $0.item.matchesSuppressionSearch(query) }
                .map { SuppressionSearchItem(kind: .blocklist($0)) }
            guard !entries.isEmpty else { return nil }
            return SuppressionSearchSection(title: "Blocklist - \(service.displayName)", items: entries)
        }

        let exclusionSections = [ArrServiceType.sonarr, .radarr].compactMap { service -> SuppressionSearchSection? in
            let entries = allExclusionSearchEntries
                .filter { $0.source == service && $0.item.matchesSuppressionSearch(query) }
                .map { SuppressionSearchItem(kind: .exclusion($0)) }
            guard !entries.isEmpty else { return nil }
            return SuppressionSearchSection(title: "Exclusions - \(service.displayName)", items: entries)
        }

        return blocklistSections + exclusionSections
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
        .animation(.default, value: allEntries.map(\.id))
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var exclusionsContent: some View {
        List {
            ForEach(allExclusionEntries) { entry in
                ExclusionRow(entry: entry)
                    .swipeActions(allowsFullSwipe: false) {
                        Button {
                            exclusionToDelete = entry
                        } label: {
                            Label("Remove", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.red)
                    }
            }
        }
        .animation(.default, value: allExclusionEntries.map(\.id))
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
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

    private func loadCurrentMode() async {
        if hasPreviewData { return }
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
        switch mode {
        case .blocklist:
            await serviceManager.loadBlocklist()
        case .exclusions:
            await serviceManager.loadImportListExclusions()
        }
    }

    private func deleteEntry(_ entry: BlocklistEntry) async {
        await serviceManager.removeBlocklistItem(id: entry.item.id, source: entry.source)
    }

    private func deleteExclusion(_ entry: ExclusionEntry) async {
        await serviceManager.removeImportListExclusion(id: entry.item.id, source: entry.source)
    }

    private func clearAll() async {
        switch mode {
        case .blocklist:
            let sonarrIDs = displayedSonarrItems.map(\.id)
            let radarrIDs = displayedRadarrItems.map(\.id)
            await serviceManager.clearBlocklist(sonarrIDs: sonarrIDs, radarrIDs: radarrIDs)
        case .exclusions:
            let sonarrIDs = displayedSonarrExclusions.map(\.id)
            let radarrIDs = displayedRadarrExclusions.map(\.id)
            await serviceManager.clearImportListExclusions(sonarrIDs: sonarrIDs, radarrIDs: radarrIDs)
        }
    }
}

private struct SuppressionSearchSection: Identifiable {
    let title: String
    let items: [SuppressionSearchItem]

    var id: String { title }
}

private struct SuppressionSearchItem: Identifiable {
    let kind: SuppressionSearchItemKind

    var id: String { kind.id }
}

private enum SuppressionSearchItemKind {
    case blocklist(ArrBlocklistView.BlocklistEntry)
    case exclusion(ArrBlocklistView.ExclusionEntry)

    var id: String {
        switch self {
        case .blocklist(let entry):
            "blocklist-\(entry.id)"
        case .exclusion(let entry):
            "exclusion-\(entry.id)"
        }
    }
}

private extension ArrBlocklistItem {
    func matchesSuppressionSearch(_ query: String) -> Bool {
        [
            sourceTitle,
            indexer,
            message,
            quality?.quality?.name,
            quality?.quality?.source
        ].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private extension ArrImportListExclusion {
    func matchesSuppressionSearch(_ query: String) -> Bool {
        [
            displayTitle,
            title,
            movieTitle,
            tvdbId.map(String.init),
            tmdbId.map(String.init)
        ].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private struct BlocklistToolbarMenu: View {
    @Binding var scope: ArrBlocklistView.BlocklistScope
    let mode: ArrBlocklistView.SuppressionMode
    let canFilter: Bool
    let isEmpty: Bool
    let onClearAll: () -> Void

    var body: some View {
        if canFilter || !isEmpty {
            Menu {
                if canFilter {
                    Picker("Scope", selection: $scope) {
                        Label("All", systemImage: "square.grid.2x2").tag(ArrBlocklistView.BlocklistScope.all)
                        Label("Series", systemImage: "tv").tag(ArrBlocklistView.BlocklistScope.series)
                        Label("Movies", systemImage: "film").tag(ArrBlocklistView.BlocklistScope.movies)
                    }
                }
                if !isEmpty {
                    if canFilter {
                        Divider()
                    }
                    Button("Clear \(mode.rawValue)", role: .destructive, action: onClearAll)
                }
            } label: {
                Image(systemName: scope == .all
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                .accessibilityLabel(Text("Blocklist filter menu"))
            }
        }
    }
}

// MARK: - Blocklist Row

private struct BlocklistRow: View {
    let entry: ArrBlocklistView.BlocklistEntry

    var body: some View {
        ArrInfoRowView(blocklistItem: entry.item, source: entry.source)
    }
}

private struct ExclusionRow: View {
    let entry: ArrBlocklistView.ExclusionEntry

    private var idLabel: String? {
        switch entry.source {
        case .sonarr:
            entry.item.tvdbId.map { "TVDb \($0)" }
        case .radarr:
            entry.item.tmdbId.map { "TMDb \($0)" }
        case .prowlarr, .bazarr:
            nil
        }
    }

    private var yearLabel: String? {
        guard let year = entry.item.movieYear, year > 0 else { return nil }
        return "\(year)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.source == .sonarr ? "tv" : "film")
                .foregroundStyle(entry.source == .sonarr ? Color.purple : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Label(entry.source.displayName, systemImage: entry.source.systemImage)
                    if let yearLabel {
                        Text("·")
                        Text(yearLabel)
                    }
                    if let idLabel {
                        Text("·")
                        Text(idLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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

#if DEBUG
#Preview("Blocklist - Releases") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBlocklistView(
                previewSonarrBlocklist: [ArrBlocklistItem.preview, ArrBlocklistItem.previewList[2]],
                previewRadarrBlocklist: [ArrBlocklistItem.previewMovie]
            )
        }
    }
}

#Preview("Blocklist - Exclusions") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBlocklistView(
                previewSonarrExclusions: [ArrImportListExclusion.preview],
                previewRadarrExclusions: [ArrImportListExclusion.previewMovie],
                initialMode: .exclusions
            )
        }
    }
}

#Preview("Blocklist - Empty") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBlocklistView(
                previewSonarrBlocklist: [],
                previewRadarrBlocklist: []
            )
        }
    }
}

#Preview("Blocklist - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrBlocklistView()
        }
    }
}
#endif
