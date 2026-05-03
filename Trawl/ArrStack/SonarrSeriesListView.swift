import SwiftUI
import SwiftData

struct SonarrSeriesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Query private var profiles: [ArrServiceProfile]
    @State private var viewModel: SonarrViewModel?
    @State private var viewModelInstanceID: UUID?
    @State private var listScrollPosition: Int?
    @Namespace private var namespace
    @State private var showSettings = false
    @State private var showAddSheet = false
    @State private var showCalendar = false
    @State private var showWantedMissing = false
    @State private var pendingDeleteSeries: SonarrSeries?
    @State private var isRunningCommand = false
    @State private var localSeriesSearch: String = ""
    @State private var editMode: SelectionMode = .inactive
    @State private var selectedSeriesIDs: Set<Int> = []
    @State private var showBulkDeleteAlert = false

    #if os(iOS)
    private var swiftUIEditMode: Binding<EditMode> {
        Binding(
            get: { editMode.isEditing ? .active : .inactive },
            set: { editMode = $0.isEditing ? .active : .inactive }
        )
    }
    #endif

    var body: some View {
        let baseContent = Group {
            if let vm = viewModel {
                seriesContent(vm: vm)
            } else if isShowingConnectingState {
                connectingContent
            } else if let errorMessage = serviceManager.sonarrConnectionError {
                ContentUnavailableView {
                    Label("Connection Failed", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await serviceManager.retry(.sonarr) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serviceManager.sonarrIsConnecting)
                    Button("Edit Server", systemImage: "server.rack") {
                        showSettings = true
                    }
                }
            } else if !serviceManager.sonarrConnected {
                ContentUnavailableView {
                    Label("Sonarr Not Set Up", systemImage: "tv")
                } description: {
                    Text("Add a Sonarr server to get started.")
                } actions: {
                    Button("Add Server", systemImage: "plus") {
                        if profiles.filter({ $0.resolvedServiceType == .sonarr }).isEmpty {
                            showAddSheet = true
                        } else {
                            showSettings = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationSubtitle(navigationSubtitleText)
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        .environment(\.editMode, swiftUIEditMode)
        .toolbarVisibility(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        #endif
        .searchable(text: $localSeriesSearch, prompt: "Search series")
        .onChange(of: localSeriesSearch) { _, newValue in
            viewModel?.searchText = newValue
        }
        .onChange(of: viewModel?.searchText) { _, newValue in
            if let newValue, newValue != localSeriesSearch {
                localSeriesSearch = newValue
            }
        }
        .toolbar { toolbarContent }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: editMode.isEditing)
        .alert(
            "Delete Series?",
            isPresented: Binding(
                get: { pendingDeleteSeries != nil },
                set: { if !$0 { pendingDeleteSeries = nil } }
            ),
            presenting: pendingDeleteSeries
        ) { show in
            Button("Delete from Sonarr", role: .destructive) {
                let id = show.id
                pendingDeleteSeries = nil
                Task { await viewModel?.deleteSeries(id: id, deleteFiles: false) }
            }
            Button("Delete Series and Files", role: .destructive) {
                let id = show.id
                pendingDeleteSeries = nil
                Task { await viewModel?.deleteSeries(id: id, deleteFiles: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSeries = nil
            }
        } message: { show in
            Text("Choose whether to remove only \(show.title) from Sonarr or also delete its files.")
        }
        .alert("Delete \(selectedSeriesIDs.count) Series?", isPresented: $showBulkDeleteAlert) {
            Button("Delete from Sonarr", role: .destructive) {
                bulkDeleteSeries(deleteFiles: false)
            }
            Button("Delete Series and Files", role: .destructive) {
                bulkDeleteSeries(deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose whether to remove the selected series from Sonarr or also delete their files. This action can't be undone.")
        }
        .refreshable {
            if let viewModel {
                async let loadSeries = viewModel.loadSeries()
                async let loadQueue = viewModel.loadQueue()
                _ = await (loadSeries, loadQueue)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: .sonarr)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ArrSetupSheet(initialServiceType: .sonarr, onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
        .sheet(isPresented: $showCalendar) {
            NavigationStack {
                ArrCalendarView(showsCloseButton: true)
                    .environment(serviceManager)
                    .environment(syncService)
            }
            #if os(iOS)
            .navigationTransition(.zoom(sourceID: "calendar", in: namespace))
            #endif
        }
        .sheet(isPresented: $showWantedMissing) {
            NavigationStack {
                ArrWantedView(initialScope: .series, showsCloseButton: true)
                    .environment(serviceManager)
            }
        }
        .navigationDestination(for: Int.self) { seriesId in
            if let vm = viewModel {
                SonarrSeriesDetailView(seriesId: seriesId, viewModel: vm)
                    .environment(syncService)
            }
        }
        .onChange(of: serviceManager.sonarrConnected) { _, isConnected in
            if !isConnected {
                viewModel = nil
                viewModelInstanceID = nil
            } else {
                // Connection restored — recreate VM if we don't have one
                if viewModel == nil {
                    viewModel = SonarrViewModel(serviceManager: serviceManager)
                    viewModelInstanceID = serviceManager.activeSonarrInstanceID
                    // Sync local search state to new VM
                    if !localSeriesSearch.isEmpty {
                        viewModel?.searchText = localSeriesSearch
                    }
                    Task {
                        guard let vm = viewModel else { return }
                        async let loadSeries = vm.loadSeries()
                        async let loadQueue = vm.loadQueue()
                        _ = await (loadSeries, loadQueue)
                    }
                }
            }
        }
        .task(id: serviceManager.activeSonarrInstanceID) {
            guard serviceManager.sonarrConnected else {
                viewModel = nil
                viewModelInstanceID = nil
                return
            }
            // Only create a new VM when the active instance changes, not on every tab switch.
            // This preserves scroll position and avoids a flash back through the loading state.
            let activeID = serviceManager.activeSonarrInstanceID
            if viewModel == nil || viewModelInstanceID != activeID {
                viewModel = SonarrViewModel(serviceManager: serviceManager)
                viewModelInstanceID = activeID
                // Sync local search state to new VM
                if !localSeriesSearch.isEmpty {
                    viewModel?.searchText = localSeriesSearch
                }
            }
            guard let vm = viewModel else { return }
            async let loadSeries = vm.loadSeries()
            async let loadQueue = vm.loadQueue()
            _ = await (loadSeries, loadQueue)

            // Poll queue every 30s; when items are removed (import completed), refresh series.
            var polledViewModel = vm
            var knownQueueIds = Set(polledViewModel.queue.map(\.id))
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }

                guard serviceManager.sonarrConnected else { continue }
                guard let latestViewModel = viewModel else { continue }
                if latestViewModel !== polledViewModel {
                    polledViewModel = latestViewModel
                    knownQueueIds = Set(polledViewModel.queue.map(\.id))
                }

                await polledViewModel.loadQueue()
                let currentIds = Set(polledViewModel.queue.map(\.id))
                if !knownQueueIds.subtracting(currentIds).isEmpty {
                    await polledViewModel.loadSeries()
                }
                knownQueueIds = currentIds
            }
        }

        if shouldShowInstanceTitleMenu {
            baseContent.toolbarTitleMenu {
                ForEach(sonarrProfiles) { profile in
                    Button {
                        serviceManager.setActiveSonarr(profile.id)
                    } label: {
                        if profile.id == serviceManager.activeSonarrInstanceID {
                            Label(instanceDisplayName(for: profile), systemImage: "checkmark")
                        } else {
                            Text(instanceDisplayName(for: profile))
                        }
                    }
                    .disabled(!serviceManager.isConnected(.sonarr, profileID: profile.id))
                }
            }
        } else {
            baseContent
        }
    }

    @ViewBuilder
    private func seriesContent(vm: SonarrViewModel) -> some View {
        if vm.isLoading && vm.series.isEmpty {
            ProgressView("Loading series...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filteredSeries.isEmpty {
            ContentUnavailableView {
                Label("No Series", systemImage: "tv")
            } description: {
                Text("No series match the current filter.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            seriesList(vm: vm)
            .scrollPosition(id: $listScrollPosition)
            .animation(.default, value: vm.filteredSeries)
        }
    }

    @ViewBuilder
    private func seriesList(vm: SonarrViewModel) -> some View {
        if vm.sortOrder == .title {
            let sections = seriesTitleSections(for: vm.filteredSeries)
            #if os(iOS)
            if #available(iOS 26.0, *) {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.series) { show in
                                seriesRow(show, vm: vm)
                            }
                        }
                        .sectionIndexLabel(Text(section.indexLabel))
                    }
                }
                .listSectionIndexVisibility(.visible)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.series) { show in
                                seriesRow(show, vm: vm)
                            }
                        }
                    }
                }
            }
            #else
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.series) { show in
                            seriesRow(show, vm: vm)
                        }
                    }
                }
            }
            #endif
        } else {
            List {
                ForEach(vm.filteredSeries) { show in
                    seriesRow(show, vm: vm)
                }
            }
        }
    }

    @ViewBuilder
    private func seriesRow(_ show: SonarrSeries, vm: SonarrViewModel) -> some View {
        let bazarrStatus = serviceManager.bazarrSubtitleStatus(forSonarrSeriesId: show.id)
        if editMode.isEditing {
            Button {
                toggleSeriesSelection(show)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedSeriesIDs.contains(show.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedSeriesIDs.contains(show.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    SonarrSeriesRow(
                        series: show,
                        hasIssue: vm.queue.contains {
                            $0.seriesId == show.id && $0.isImportIssueQueueItem
                        },
                        bazarrStatus: bazarrStatus
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: show.id) {
                SonarrSeriesRow(
                    series: show,
                    hasIssue: vm.queue.contains {
                        $0.seriesId == show.id && $0.isImportIssueQueueItem
                    },
                    bazarrStatus: bazarrStatus
                )
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeleteSeries = show
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    Task { await vm.toggleSeriesMonitored(show) }
                } label: {
                    Label(
                        show.monitored == true ? "Unmonitor" : "Monitor",
                        systemImage: show.monitored == true ? "bookmark.slash" : "bookmark.fill"
                    )
                }
                .tint(show.monitored == true ? .orange : .blue)
            }
        }
    }

    private func toggleSeriesSelection(_ show: SonarrSeries) {
        if selectedSeriesIDs.contains(show.id) {
            selectedSeriesIDs.remove(show.id)
        } else {
            selectedSeriesIDs.insert(show.id)
        }
    }

    private func bulkDeleteSeries(deleteFiles: Bool) {
        let ids = selectedSeriesIDs
        selectedSeriesIDs = []
        withAnimation { editMode = .inactive }
        Task {
            for id in ids {
                _ = await viewModel?.deleteSeries(id: id, deleteFiles: deleteFiles)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing, let vm = viewModel {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    withAnimation { editMode = .inactive }
                    selectedSeriesIDs = []
                }
            }
            ToolbarItemGroup(placement: sonarrTrailingToolbarPlacement) {
                Button(selectedSeriesIDs.count == vm.filteredSeries.count ? "Deselect All" : "Select All") {
                    if selectedSeriesIDs.count == vm.filteredSeries.count {
                        selectedSeriesIDs = []
                    } else {
                        selectedSeriesIDs = Set(vm.filteredSeries.map(\.id))
                    }
                }
                Button(role: .destructive) {
                    showBulkDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(selectedSeriesIDs.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: sonarrLeadingToolbarPlacement) {
                if let vm = viewModel {
                    Menu {
                        ForEach(SonarrFilter.allCases) { filter in
                            Button {
                                withAnimation { vm.selectedFilter = filter }
                            } label: {
                                if vm.selectedFilter == filter {
                                    Label(filter.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(filter.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: filterIcon(for: vm.selectedFilter))
                    }

                    Menu {
                        ForEach(SonarrSortOrder.allCases) { order in
                            Button {
                                withAnimation {
                                    vm.sortOrder = order
                                }
                            } label: {
                                if vm.sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }

            ToolbarItemGroup(placement: sonarrTrailingToolbarPlacement) {
                Button("Calendar", systemImage: "calendar") {
                    showCalendar = true
                }
                #if os(iOS)
                .matchedTransitionSource(id: "calendar", in: namespace)
                #endif

                Menu {
                    Button("Wanted / Missing", systemImage: "exclamationmark.triangle") {
                        showWantedMissing = true
                    }
                    if let vm = viewModel, !vm.filteredSeries.isEmpty {
                        Button("Select", systemImage: "checkmark.circle") {
                            withAnimation { editMode = .active }
                        }
                    }
                    if let vm = viewModel {
                        Divider()
                        Button("Refresh All", systemImage: "arrow.clockwise") {
                            Task { await runSonarrCommand(vm: vm) { try await vm.refreshSeries() } }
                        }
                        .disabled(isRunningCommand)
                        Button("Check for New Releases", systemImage: "dot.radiowaves.left.and.right") {
                            Task { await runSonarrCommand(vm: vm) { try await vm.rssSync() } }
                        }
                        .disabled(isRunningCommand)
                    }
                } label: {
                    if isRunningCommand {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                if serviceManager.sonarrInstances.count > 1 {
                    Menu {
                        ForEach(serviceManager.sonarrInstances) { entry in
                            Button {
                                serviceManager.setActiveSonarr(entry.id)
                            } label: {
                                if entry.id == serviceManager.activeSonarrEntry?.id {
                                    Label(entry.displayName, systemImage: "checkmark")
                                } else {
                                    Label(entry.displayName,
                                          systemImage: entry.isConnected ? "server.rack" : "exclamationmark.triangle")
                                }
                            }
                            .disabled(!entry.isConnected)
                        }
                    } label: {
                        Label("Instance", systemImage: "server.rack")
                    }
                }
            }
        }
    }

    private var navigationSubtitleText: String {
        if editMode.isEditing {
            let count = selectedSeriesIDs.count
            return count == 1 ? "1 selected" : "\(count) selected"
        }
        guard let vm = viewModel else { return "" }
        let count = vm.filteredSeries.count
        return count == 1 ? "1 series" : "\(count) series"
    }

    private func runSonarrCommand(vm: SonarrViewModel, action: @escaping () async throws -> Void) async {
        isRunningCommand = true
        do {
            try await action()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Command Failed", message: error.localizedDescription)
        }
        isRunningCommand = false
    }

    private func filterIcon(for filter: SonarrFilter) -> String {
        switch filter {
        case .all:         "line.3.horizontal.decrease.circle"
        case .monitored:   "bookmark.circle"
        case .unmonitored: "bookmark.slash"
        case .continuing:  "play.circle"
        case .ended:       "stop.circle"
        case .missing:     "exclamationmark.circle"
        }
    }

    private var sonarrProfile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: .sonarr, in: profiles)
    }

    private var sonarrProfiles: [ArrServiceProfile] {
        profiles
            .filter { $0.resolvedServiceType == .sonarr && $0.isEnabled }
            .sorted { lhs, rhs in
                if lhs.dateAdded == rhs.dateAdded {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.dateAdded < rhs.dateAdded
            }
    }

    private var shouldShowInstanceTitleMenu: Bool {
        sonarrProfiles.count > 1
    }

    private var navigationTitleText: String {
        guard shouldShowInstanceTitleMenu, let sonarrProfile else { return "Series" }
        return instanceDisplayName(for: sonarrProfile)
    }

    private var isShowingConnectingState: Bool {
        sonarrProfile != nil && (serviceManager.isInitializing || serviceManager.sonarrIsConnecting)
    }

    private func instanceDisplayName(for profile: ArrServiceProfile) -> String {
        let baseName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingNames = sonarrProfiles.filter {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(baseName) == .orderedSame
        }

        if !baseName.isEmpty,
           baseName.localizedCaseInsensitiveCompare(ArrServiceType.sonarr.displayName) != .orderedSame,
           matchingNames.count == 1 {
            return baseName
        }

        if let index = sonarrProfiles.firstIndex(where: { $0.id == profile.id }) {
            return "\(ArrServiceType.sonarr.displayName) (\(index + 1))"
        }

        return ArrServiceType.sonarr.displayName
    }

    private var connectingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.headline)
            if let profile = sonarrProfile {
                VStack(spacing: 4) {
                    Text(profile.displayName)
                    Text(profile.hostURL)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
            }
            Button("Edit Server", systemImage: "server.rack") {
                showSettings = true
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private var sonarrLeadingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
}

private var sonarrTrailingToolbarPlacement: ToolbarItemPlacement {
    platformTopBarTrailingPlacement
}

private struct SonarrSeriesTitleSection: Identifiable {
    let title: String
    let indexLabel: String
    let series: [SonarrSeries]

    var id: String { indexLabel }
}

private func seriesTitleSections(for series: [SonarrSeries]) -> [SonarrSeriesTitleSection] {
    let grouped = Dictionary(grouping: series) { show in
        sonarrListSectionLabel(for: show.sortTitle ?? show.title)
    }

    return grouped.keys.sorted().map { label in
        SonarrSeriesTitleSection(
            title: label,
            indexLabel: label,
            series: grouped[label] ?? []
        )
    }
}

private func sonarrListSectionLabel(for title: String) -> String {
    guard let scalar = title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first else {
        return "#"
    }

    let label = String(scalar).uppercased()
    return label.range(of: "[A-Z]", options: .regularExpression) != nil ? label : "#"
}

// MARK: - Series Row

struct SonarrSeriesRow: View {
    let series: SonarrSeries
    let hasIssue: Bool
    var bazarrStatus: BazarrSubtitleStatus? = nil

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: series.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let year = series.year {
                        Text(String(year))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let network = series.network {
                        Text(network)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(series.status?.capitalized ?? "")
                        .font(.caption2)
                        .foregroundStyle(series.status == "continuing" ? .green : .secondary)
                }

                HStack(spacing: 6) {
                    if let stats = series.statistics {
                        let fileCount = stats.episodeFileCount ?? 0
                        let totalCount = stats.episodeCount ?? 0
                        ProgressView(value: totalCount > 0 ? Double(fileCount) / Double(totalCount) : 0)
                            .tint(fileCount == totalCount ? .green : .blue)
                            .frame(width: 40)
                        Text("\(fileCount)/\(totalCount) eps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let bazarrStatus {
                        let color: Color = {
                            switch bazarrStatus {
                            case .allPresent: return .green
                            case .partial: return .orange
                            case .none: return .red
                            case .unknown: return .gray
                            }
                        }()
                        let icon: String = {
                            switch bazarrStatus {
                            case .allPresent: return "checkmark.circle.fill"
                            case .partial: return "exclamationmark.triangle.fill"
                            case .none: return "xmark.circle.fill"
                            case .unknown: return "questionmark.circle.fill"
                            }
                        }()
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: icon)
                            .font(.caption2)
                            .foregroundStyle(color)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if hasIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if series.monitored == true {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
