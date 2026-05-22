import SwiftUI
import SwiftData
import Foundation

@MainActor
struct ArrMediaListView<Item, VM, Row>: View
where Item: Identifiable & JellyfinMatchable & Equatable, Item.ID == Int,
      VM: ArrMediaListViewModel & Observable, VM.Item == Item,
      Row: View {

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager
    @Query private var profiles: [ArrServiceProfile]

    @Bindable var viewModel: VM
    let serviceType: ArrServiceType
    let nounSingular: String
    let nounPlural: String
    let emptyIcon: String
    let row: (Item, Bool) -> Row
    let detailDestination: (Int) -> AnyView

    @State private var listScrollPosition: Int?
    @Namespace private var namespace
    @State private var showSettings = false
    @State private var showAddSheet = false
    @State private var showCalendar = false
    @State private var showWantedMissing = false
    @State private var pendingDeleteItem: Item?
    @State private var isRunningCommand = false
    @State private var editMode: SelectionMode = .inactive
    @State private var selectedIDs: Set<Int> = []
    @State private var showBulkDeleteAlert = false
    @State private var isFilterSearchExpanded = false

    #if os(iOS)
    private var swiftUIEditMode: Binding<EditMode> {
        Binding(
            get: { editMode.isEditing ? .active : .inactive },
            set: { editMode = $0.isEditing ? .active : .inactive }
        )
    }
    #endif

    var body: some View {
        baseContent
            .navigationTitle(navigationTitleText)
            .navigationSubtitle(navigationSubtitleText)
            #if os(iOS)
            .toolbarTitleDisplayMode(.inlineLarge)
            .environment(\.editMode, swiftUIEditMode)
            .toolbarVisibility(editMode.isEditing ? .hidden : .visible, for: .tabBar)
            #endif
            .toolbar { toolbarContent }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: editMode.isEditing)
            .modifier(ArrMediaListViewAlertsAndSheets(
                serviceType: serviceType,
                nounSingular: nounSingular,
                nounPlural: nounPlural,
                viewModel: viewModel,
                serviceManager: serviceManager,
                syncService: syncService,
                namespace: namespace,
                pendingDeleteItem: $pendingDeleteItem,
                showBulkDeleteAlert: $showBulkDeleteAlert,
                selectedIDs: $selectedIDs,
                showSettings: $showSettings,
                showAddSheet: $showAddSheet,
                showCalendar: $showCalendar,
                showWantedMissing: $showWantedMissing,
                onBulkDelete: bulkDeleteItems
            ))
            .refreshable {
                async let loadItems = viewModel.loadLibraryItems()
                async let loadQueue = viewModel.loadQueue()
                _ = await (loadItems, loadQueue)
                if serviceManager.hasAnyConnectedBazarrInstance {
                    await serviceManager.refreshActiveBazarrSubtitleCache()
                }
                viewModel.refreshFilters()
            }
            .safeAreaInset(edge: .top) {
                if !editMode.isEditing {
                    TrawlSegmentBar(
                        "Filter",
                        selection: $viewModel.selectedFilter,
                        items: VM.Filter.allCases.map { TrawlSegmentBarItem($0.rawValue, value: $0) },
                        searchText: $viewModel.searchText,
                        searchHint: "Search \(nounPlural.lowercased())",
                        isSearchExpanded: $isFilterSearchExpanded,
                        searchPlacement: .leading
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .navigationDestination(for: Int.self) { id in
                detailDestination(id)
                    .environment(syncService)
            }
            .task(id: serviceManager.activeInstanceID(serviceType)) { [viewModel] in
                await performInitialLoadAndStartPolling(viewModel: viewModel)
            }
            .task(id: serviceManager.activeBazarrProfileID) { [viewModel] in
                await refreshBazarrStatus(viewModel: viewModel)
            }
            .task(id: "\(jellyfinManager.activeProfileID?.uuidString ?? ""):\(jellyfinManager.isConnected)") { [viewModel] in
                await viewModel.refreshJellyfinLibraryCache()
            }
    }

    @ViewBuilder
    private var baseContent: some View {
        if serviceManager.isConnected(serviceType) {
            mainContent
        } else if isShowingConnectingState || serviceManager.connectionError(serviceType) != nil {
            ConnectionStatusCard(
                identity: serviceType.serviceIdentity,
                title: isShowingConnectingState ? "Connecting to \(serviceType.displayName)" : "\(serviceType.displayName) Unreachable",
                message: serviceManager.connectionError(serviceType) ?? "Checking your configured \(serviceType.displayName) server.",
                isConnecting: isShowingConnectingState,
                detailTitle: activeProfile?.displayName,
                detailSubtitle: activeProfile?.hostURL,
                presentation: .embedded,
                onRetry: { Task { await serviceManager.retry(serviceType) } },
                onEdit: {
                    withAnimation(.snappy) {
                        showSettings = true
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            notSetUpView
        }
    }

    private var notSetUpView: some View {
        ContentUnavailableView {
            Label("\(serviceType.displayName) Not Set Up", systemImage: emptyIcon)
        } description: {
            Text("Add a \(serviceType.displayName) server to get started.")
        } actions: {
            Button("Add Server", systemImage: "plus") {
                withAnimation(.snappy) {
                    if profiles.filter({ $0.resolvedServiceType == serviceType }).isEmpty {
                        showAddSheet = true
                    } else {
                        showSettings = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ArrLibraryListView(
            items: viewModel.filteredItems,
            isLoading: viewModel.isLoading && viewModel.items.isEmpty,
            error: nil,
            nounSingular: nounSingular,
            nounPlural: nounPlural,
            emptyIcon: emptyIcon,
            titleKeyPath: \.titlePlaceholder,
            sectionTitle: { item in
                (item as? any ArrSortable)?.sortTitle ?? (item as? any ArrTitleable)?.title ?? ""
            },
            usesTitleSections: viewModel.sortOrder.rawValue == "Title",
            selectedIDs: selectedIDs,
            row: { item, _ in itemRow(item) },
            retry: nil
        )
        .scrollPosition(id: $listScrollPosition)
        .animation(.default, value: viewModel.filteredItems)
    }

    @ViewBuilder
    private func itemRow(_ item: Item) -> some View {
        if editMode.isEditing {
            Button {
                toggleSelection(item)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedIDs.contains(item.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    row(item, true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: item.id) {
                row(item, false)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeleteItem = item
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    Task { await viewModel.toggleMonitored(item) }
                } label: {
                    let monitored = (item as? any ArrMonitorable)?.monitored ?? true
                    Label(
                        monitored ? "Unmonitor" : "Monitor",
                        systemImage: monitored ? "bookmark.slash" : "bookmark.fill"
                    )
                }
                .tint(((item as? any ArrMonitorable)?.monitored ?? true) ? .orange : .blue)
            }
        }
    }

    private func toggleSelection(_ item: Item) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func bulkDeleteItems(deleteFiles: Bool) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        selectedIDs = []
        withAnimation { editMode = .inactive }
        Task {
            await viewModel.deleteItems(ids: ids, deleteFiles: deleteFiles)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    withAnimation { editMode = .inactive }
                    selectedIDs = []
                }
            }
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button(selectedIDs.count == viewModel.filteredItems.count ? "Deselect All" : "Select All") {
                    if selectedIDs.count == viewModel.filteredItems.count {
                        selectedIDs = []
                    } else {
                        selectedIDs = Set(viewModel.filteredItems.map(\.id))
                    }
                }
                Button(role: .destructive) {
                    showBulkDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(selectedIDs.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button("Calendar", systemImage: "calendar") {
                    showCalendar = true
                }
                #if os(iOS)
                .matchedTransitionSource(id: "calendar", in: namespace)
                #endif

                Menu {
                    ForEach(Array(VM.Sort.allCases)) { order in
                        Button {
                            withAnimation {
                                viewModel.sortOrder = order
                            }
                        } label: {
                            if viewModel.sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: viewModel.isNonDefaultSortOrder ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
                }

                Menu {
                    Button("Wanted / Missing", systemImage: "exclamationmark.triangle") {
                        showWantedMissing = true
                    }
                    if !viewModel.filteredItems.isEmpty {
                        Button("Select", systemImage: "checkmark.circle") {
                            withAnimation { editMode = .active }
                        }
                    }
                    Divider()
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        Task { await runCommand { try await viewModel.refreshLibrary() } }
                    }
                    .disabled(isRunningCommand)
                    Button("Check for New Releases", systemImage: "dot.radiowaves.left.and.right") {
                        Task { await runCommand { try await viewModel.rssSync() } }
                    }
                    .disabled(isRunningCommand)
                } label: {
                    if isRunningCommand {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .accessibilityLabel("\(serviceType.displayName) Actions")

                if instanceProfiles.count > 1 {
                    Menu {
                        ForEach(instanceProfiles) { profile in
                            Button {
                                switch serviceType {
                                case .sonarr: serviceManager.setActiveSonarr(profile.id)
                                case .radarr: serviceManager.setActiveRadarr(profile.id)
                                default: break
                                }
                            } label: {
                                if profile.id == serviceManager.activeInstanceID(serviceType) {
                                    Label(instanceDisplayName(for: profile), systemImage: "checkmark")
                                } else {
                                    Label(instanceDisplayName(for: profile),
                                          systemImage: serviceManager.isConnected(serviceType, profileID: profile.id) ? "server.rack" : "exclamationmark.triangle")
                                }
                            }
                            .disabled(!serviceManager.isConnected(serviceType, profileID: profile.id))
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
            let count = selectedIDs.count
            return count == 1 ? "1 selected" : "\(count) selected"
        }
        let count = viewModel.filteredItems.count
        return count == 1 ? "1 \(nounSingular.lowercased())" : "\(count) \(nounPlural.lowercased())"
    }

    private func runCommand(action: @escaping () async throws -> Void) async {
        isRunningCommand = true
        do {
            try await action()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Command Failed", message: error.localizedDescription)
        }
        isRunningCommand = false
    }

    private var activeProfile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: serviceType, in: profiles)
    }

    private var instanceProfiles: [ArrServiceProfile] {
        profiles
            .filter { $0.resolvedServiceType == serviceType && $0.isEnabled }
            .sorted { lhs, rhs in
                if lhs.dateAdded == rhs.dateAdded {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.dateAdded < rhs.dateAdded
            }
    }

    private var shouldShowInstanceTitleMenu: Bool {
        instanceProfiles.count > 1
    }

    private var navigationTitleText: String {
        guard shouldShowInstanceTitleMenu, let profile = activeProfile else { return nounPlural }
        return instanceDisplayName(for: profile)
    }

    private var isShowingConnectingState: Bool {
        activeProfile != nil && (serviceManager.isInitializing || serviceManager.isConnecting(serviceType))
    }

    private func instanceDisplayName(for profile: ArrServiceProfile) -> String {
        InstanceDisplayNameResolver.displayName(
            for: profile,
            in: instanceProfiles,
            serviceType: serviceType
        )
    }

    private func performInitialLoadAndStartPolling(viewModel: VM) async {
        guard serviceManager.isConnected(serviceType) else { return }

        async let loadItems = viewModel.loadLibraryItems()
        async let loadQueue = viewModel.loadQueue()
        _ = await (loadItems, loadQueue)

        var knownQueueIds = Set(viewModel.queue.map(\.id))
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                break
            } catch {
                continue
            }

            guard serviceManager.isConnected(serviceType) else { continue }

            await viewModel.loadQueue()
            let currentIds = Set(viewModel.queue.map(\.id))
            if !knownQueueIds.subtracting(currentIds).isEmpty {
                await viewModel.loadLibraryItems()
            }
            knownQueueIds = currentIds
        }
    }

    private func refreshBazarrStatus(viewModel: VM) async {
        guard serviceManager.hasAnyConnectedBazarrInstance else {
            viewModel.refreshFilters()
            return
        }
        await serviceManager.refreshActiveBazarrSubtitleCache()
        viewModel.refreshFilters()
    }
}

// MARK: - Helper Protocols

protocol ArrTitleable {
    var title: String { get }
}

protocol ArrSortable {
    var sortTitle: String? { get }
}

protocol ArrMonitorable {
    var monitored: Bool? { get }
}

extension SonarrSeries: ArrTitleable, ArrSortable, ArrMonitorable {}
extension RadarrMovie: ArrTitleable, ArrSortable, ArrMonitorable {}

private extension Identifiable {
    var titlePlaceholder: String { "" }
}

struct ArrMediaListViewAlertsAndSheets<Item, VM>: ViewModifier
where Item: Identifiable & JellyfinMatchable & Equatable, Item.ID == Int,
      VM: ArrMediaListViewModel & Observable, VM.Item == Item {
    let serviceType: ArrServiceType
    let nounSingular: String
    let nounPlural: String
    @Bindable var viewModel: VM
    let serviceManager: ArrServiceManager
    let syncService: SyncService
    let namespace: Namespace.ID

    @Binding var pendingDeleteItem: Item?
    @Binding var showBulkDeleteAlert: Bool
    @Binding var selectedIDs: Set<Int>
    @Binding var showSettings: Bool
    @Binding var showAddSheet: Bool
    @Binding var showCalendar: Bool
    @Binding var showWantedMissing: Bool

    let onBulkDelete: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete \(nounSingular)?",
                isPresented: Binding(
                    get: { pendingDeleteItem != nil },
                    set: { if !$0 { pendingDeleteItem = nil } }
                ),
                presenting: pendingDeleteItem
            ) { item in
                Button("Delete from \(serviceType.displayName)", role: .destructive) {
                    let id = item.id
                    pendingDeleteItem = nil
                    Task { await viewModel.deleteItem(id: id, deleteFiles: false) }
                }
                Button("Delete \(nounSingular) and Files", role: .destructive) {
                    let id = item.id
                    pendingDeleteItem = nil
                    Task { await viewModel.deleteItem(id: id, deleteFiles: true) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteItem = nil
                }
            } message: { item in
                let title = (item as? any ArrTitleable)?.title ?? nounSingular
                Text("Choose whether to remove only \(title) from \(serviceType.displayName) or also delete its files.")
            }
            .alert("Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? nounSingular : nounPlural)?", isPresented: $showBulkDeleteAlert) {
                Button("Delete from \(serviceType.displayName)", role: .destructive) {
                    onBulkDelete(false)
                }
                Button("Delete \(nounPlural) and Files", role: .destructive) {
                    onBulkDelete(true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose whether to remove the selected \(nounPlural.lowercased()) from \(serviceType.displayName) or also delete their files. This action can't be undone.")
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ArrServiceSettingsView(serviceType: serviceType)
                        .environment(serviceManager)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                ArrSetupSheet(initialServiceType: serviceType, onComplete: {
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
                    ArrWantedView(initialScope: serviceType == .sonarr ? .series : .movies, showsCloseButton: true)
                        .environment(serviceManager)
                }
            }
    }
}
