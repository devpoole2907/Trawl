import SwiftUI
import SwiftData

struct RadarrMovieListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Query private var profiles: [ArrServiceProfile]
    @State private var viewModel: RadarrViewModel?
    @State private var viewModelInstanceID: UUID?
    @State private var listScrollPosition: Int?
    @Namespace private var namespace
    @State private var showSettings = false
    @State private var showAddSheet = false
    @State private var showCalendar = false
    @State private var showWantedMissing = false
    @State private var pendingDeleteMovie: RadarrMovie?
    @State private var isRunningCommand = false
    @State private var editMode: SelectionMode = .inactive
    @State private var selectedMovieIDs: Set<Int> = []
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
                movieContent(vm: vm)
            } else if isShowingConnectingState {
                connectingContent
            } else if let errorMessage = serviceManager.radarrConnectionError {
                ContentUnavailableView {
                    Label("Connection Failed", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await serviceManager.retry(.radarr) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serviceManager.radarrIsConnecting)
                    Button("Edit Server", systemImage: "server.rack") {
                        showSettings = true
                    }
                }
            } else if !serviceManager.radarrConnected {
                ContentUnavailableView {
                    Label("Radarr Not Set Up", systemImage: "film")
                } description: {
                    Text("Add a Radarr server to get started.")
                } actions: {
                    Button("Add Server", systemImage: "plus") {
                        if profiles.filter({ $0.resolvedServiceType == .radarr }).isEmpty {
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
        .searchable(text: movieSearchText, prompt: "Search movies")
        .toolbar { toolbarContent }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: editMode.isEditing)
        .alert(
            "Delete Movie?",
            isPresented: Binding(
                get: { pendingDeleteMovie != nil },
                set: { if !$0 { pendingDeleteMovie = nil } }
            ),
            presenting: pendingDeleteMovie
        ) { movie in
            Button("Delete from Radarr", role: .destructive) {
                let id = movie.id
                pendingDeleteMovie = nil
                Task { await viewModel?.deleteMovie(id: id, deleteFiles: false) }
            }
            Button("Delete Movie and Files", role: .destructive) {
                let id = movie.id
                pendingDeleteMovie = nil
                Task { await viewModel?.deleteMovie(id: id, deleteFiles: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteMovie = nil
            }
        } message: { movie in
            Text("Choose whether to remove only \(movie.title) from Radarr or also delete its files.")
        }
        .alert("Delete \(selectedMovieIDs.count) Movies?", isPresented: $showBulkDeleteAlert) {
            Button("Delete from Radarr", role: .destructive) {
                bulkDeleteMovies(deleteFiles: false)
            }
            .disabled(!canBulkDelete)
            Button("Delete Movies and Files", role: .destructive) {
                bulkDeleteMovies(deleteFiles: true)
            }
            .disabled(!canBulkDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose whether to remove the selected movies from Radarr or also delete their files. This action can't be undone.")
        }
        .refreshable {
            if let viewModel {
                async let loadMovies = viewModel.loadMovies()
                async let loadQueue = viewModel.loadQueue()
                _ = await (loadMovies, loadQueue)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: .radarr)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ArrSetupSheet(initialServiceType: .radarr, onComplete: {
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
                ArrWantedView(initialScope: .movies, showsCloseButton: true)
                    .environment(serviceManager)
            }
        }
        .navigationDestination(for: Int.self) { movieId in
            if let vm = viewModel {
                RadarrMovieDetailView(movieId: movieId, viewModel: vm)
                    .environment(syncService)
            }
        }
        .task(id: serviceManager.activeRadarrInstanceID) {
            guard serviceManager.radarrConnected else {
                viewModel = nil
                viewModelInstanceID = nil
                return
            }
            // Only create a new VM when the active instance changes, not on every tab switch.
            // This preserves scroll position and avoids a flash back through the loading state.
            let activeID = serviceManager.activeRadarrInstanceID
            if viewModel == nil || viewModelInstanceID != activeID {
                viewModel = RadarrViewModel(serviceManager: serviceManager)
                viewModelInstanceID = activeID
            }
            guard let vm = viewModel else { return }
            async let loadMovies = vm.loadMovies()
            async let loadQueue = vm.loadQueue()
            _ = await (loadMovies, loadQueue)

            // Poll queue every 30s; when items are removed (import completed), refresh movies.
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

                guard serviceManager.radarrConnected else { continue }
                guard let latestViewModel = viewModel else { continue }
                if latestViewModel !== polledViewModel {
                    polledViewModel = latestViewModel
                    knownQueueIds = Set(polledViewModel.queue.map(\.id))
                }

                await polledViewModel.loadQueue()
                let currentIds = Set(polledViewModel.queue.map(\.id))
                if !knownQueueIds.subtracting(currentIds).isEmpty {
                    await polledViewModel.loadMovies()
                }
                knownQueueIds = currentIds
            }
        }

        if shouldShowInstanceTitleMenu {
            baseContent.toolbarTitleMenu {
                ForEach(radarrProfiles) { profile in
                    Button {
                        serviceManager.setActiveRadarr(profile.id)
                    } label: {
                        if profile.id == serviceManager.activeRadarrInstanceID {
                            Label(instanceDisplayName(for: profile), systemImage: "checkmark")
                        } else {
                            Text(instanceDisplayName(for: profile))
                        }
                    }
                    .disabled(!serviceManager.isConnected(.radarr, profileID: profile.id))
                }
            }
        } else {
            baseContent
        }
    }

    @ViewBuilder
    private func movieContent(vm: RadarrViewModel) -> some View {
        if vm.isLoading && vm.movies.isEmpty {
            ProgressView("Loading movies...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filteredMovies.isEmpty {
            ContentUnavailableView {
                Label("No Movies", systemImage: "film")
            } description: {
                Text("No movies match the current filter.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            movieList(vm: vm)
            .scrollPosition(id: $listScrollPosition)
            .animation(.default, value: vm.filteredMovies)
        }
    }

    @ViewBuilder
    private func movieList(vm: RadarrViewModel) -> some View {
        if vm.sortOrder == .title {
            let sections = movieTitleSections(for: vm.filteredMovies)
            #if os(iOS)
            if #available(iOS 26.0, *) {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.movies) { movie in
                                movieRow(movie, vm: vm)
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
                            ForEach(section.movies) { movie in
                                movieRow(movie, vm: vm)
                            }
                        }
                    }
                }
            }
            #else
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.movies) { movie in
                            movieRow(movie, vm: vm)
                        }
                    }
                }
            }
            #endif
        } else {
            List {
                ForEach(vm.filteredMovies) { movie in
                    movieRow(movie, vm: vm)
                }
            }
        }
    }

    @ViewBuilder
    private func movieRow(_ movie: RadarrMovie, vm: RadarrViewModel) -> some View {
        if editMode.isEditing {
            Button {
                toggleMovieSelection(movie)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedMovieIDs.contains(movie.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedMovieIDs.contains(movie.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    RadarrMovieRow(
                        movie: movie,
                        hasIssue: vm.queue.contains {
                            $0.movieId == movie.id && $0.isImportIssueQueueItem
                        }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: movie.id) {
                RadarrMovieRow(
                    movie: movie,
                    hasIssue: vm.queue.contains {
                        $0.movieId == movie.id && $0.isImportIssueQueueItem
                    }
                )
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeleteMovie = movie
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    Task { await vm.toggleMovieMonitored(movie) }
                } label: {
                    Label(
                        movie.monitored == true ? "Unmonitor" : "Monitor",
                        systemImage: movie.monitored == true ? "bookmark.slash" : "bookmark.fill"
                    )
                }
                .tint(movie.monitored == true ? .orange : .blue)
            }
        }
    }

    private func toggleMovieSelection(_ movie: RadarrMovie) {
        if selectedMovieIDs.contains(movie.id) {
            selectedMovieIDs.remove(movie.id)
        } else {
            selectedMovieIDs.insert(movie.id)
        }
    }

    private var canBulkDelete: Bool {
        guard let vm = viewModel else { return false }
        let visibleIDs = Set(vm.filteredMovies.map { $0.id })
        return !selectedMovieIDs.intersection(visibleIDs).isEmpty
    }

    private func bulkDeleteMovies(deleteFiles: Bool) {
        guard let vm = viewModel else { return }
        let visibleIDs = Set(vm.filteredMovies.map { $0.id })
        let idsToDelete = selectedMovieIDs.intersection(visibleIDs)
        guard !idsToDelete.isEmpty else { return }
        selectedMovieIDs = []
        withAnimation { editMode = .inactive }
        Task {
            for id in idsToDelete {
                _ = await viewModel?.deleteMovie(id: id, deleteFiles: deleteFiles)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing, let vm = viewModel {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    withAnimation { editMode = .inactive }
                    selectedMovieIDs = []
                }
            }
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button(selectedMovieIDs.count == vm.filteredMovies.count ? "Deselect All" : "Select All") {
                    if selectedMovieIDs.count == vm.filteredMovies.count {
                        selectedMovieIDs = []
                    } else {
                        selectedMovieIDs = Set(vm.filteredMovies.map(\.id))
                    }
                }
                Button(role: .destructive) {
                    showBulkDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(!canBulkDelete)
            }
        } else {
            ToolbarItemGroup(placement: platformTopBarLeadingPlacement) {
                if let vm = viewModel {
                    Menu {
                        ForEach(RadarrFilter.allCases) { filter in
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
                        ForEach(RadarrSortOrder.allCases) { order in
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

            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
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
                    if let vm = viewModel, !vm.filteredMovies.isEmpty {
                        Button("Select", systemImage: "checkmark.circle") {
                            withAnimation { editMode = .active }
                        }
                    }
                    if let vm = viewModel {
                        Divider()
                        Button("Refresh All", systemImage: "arrow.clockwise") {
                            Task { await runRadarrCommand(vm: vm) { try await vm.refreshMovies() } }
                        }
                        .disabled(isRunningCommand)
                        Button("Check for New Releases", systemImage: "dot.radiowaves.left.and.right") {
                            Task { await runRadarrCommand(vm: vm) { try await vm.rssSync() } }
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

                if serviceManager.radarrInstances.count > 1 {
                    Menu {
                        ForEach(serviceManager.radarrInstances) { entry in
                            Button {
                                serviceManager.setActiveRadarr(entry.id)
                            } label: {
                                if entry.id == serviceManager.activeRadarrEntry?.id {
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
            let count = selectedMovieIDs.count
            return count == 1 ? "1 selected" : "\(count) selected"
        }
        guard let vm = viewModel else { return "" }
        let count = vm.filteredMovies.count
        return count == 1 ? "1 movie" : "\(count) movies"
    }

    private var movieSearchText: Binding<String> {
        Binding {
            viewModel?.searchText ?? ""
        } set: { newValue in
            viewModel?.searchText = newValue
        }
    }

    private func runRadarrCommand(vm: RadarrViewModel, action: @escaping () async throws -> Void) async {
        isRunningCommand = true
        do {
            try await action()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Command Failed", message: error.localizedDescription)
        }
        isRunningCommand = false
    }

    private func filterIcon(for filter: RadarrFilter) -> String {
        switch filter {
        case .all:         "line.3.horizontal.decrease.circle"
        case .monitored:   "bookmark.circle"
        case .unmonitored: "bookmark.slash"
        case .missing:     "exclamationmark.circle"
        case .downloaded:  "checkmark.circle"
        case .wanted:      "magnifyingglass.circle"
        }
    }

    private var radarrProfile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: .radarr, in: profiles)
    }

    private var radarrProfiles: [ArrServiceProfile] {
        profiles
            .filter { $0.resolvedServiceType == .radarr && $0.isEnabled }
            .sorted { lhs, rhs in
                if lhs.dateAdded == rhs.dateAdded {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.dateAdded < rhs.dateAdded
            }
    }

    private var shouldShowInstanceTitleMenu: Bool {
        radarrProfiles.count > 1
    }

    private var navigationTitleText: String {
        guard shouldShowInstanceTitleMenu, let radarrProfile else { return "Movies" }
        return instanceDisplayName(for: radarrProfile)
    }

    private var isShowingConnectingState: Bool {
        radarrProfile != nil && (serviceManager.isInitializing || serviceManager.radarrIsConnecting)
    }

    private func instanceDisplayName(for profile: ArrServiceProfile) -> String {
        let baseName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingNames = radarrProfiles.filter {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(baseName) == .orderedSame
        }

        if !baseName.isEmpty,
           baseName.localizedCaseInsensitiveCompare(ArrServiceType.radarr.displayName) != .orderedSame,
           matchingNames.count == 1 {
            return baseName
        }

        if let index = radarrProfiles.firstIndex(where: { $0.id == profile.id }) {
            return "\(ArrServiceType.radarr.displayName) (\(index + 1))"
        }

        return ArrServiceType.radarr.displayName
    }

    private var connectingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.headline)
            if let profile = radarrProfile {
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

private struct RadarrMovieTitleSection: Identifiable {
    let title: String
    let indexLabel: String
    let movies: [RadarrMovie]

    var id: String { indexLabel }
}

private func movieTitleSections(for movies: [RadarrMovie]) -> [RadarrMovieTitleSection] {
    let grouped = Dictionary(grouping: movies) { movie in
        listSectionLabel(for: movie.sortTitle ?? movie.title)
    }

    return grouped.keys.sorted().map { label in
        RadarrMovieTitleSection(
            title: label,
            indexLabel: label,
            movies: grouped[label] ?? []
        )
    }
}

private func listSectionLabel(for title: String) -> String {
    guard let scalar = title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first else {
        return "#"
    }

    let label = String(scalar).uppercased()
    return label.range(of: "[A-Z]", options: .regularExpression) != nil ? label : "#"
}

// MARK: - Movie Row

struct RadarrMovieRow: View {
    let movie: RadarrMovie
    let hasIssue: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: movie.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let year = movie.year { Text(String(year)).font(.caption2) }
                    if let runtime = movie.runtime, runtime > 0 {
                        Text("• \(runtime)m").font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: movie.hasFile == true ? "checkmark.circle.fill" : "clock")
                        .font(.caption2)
                        .foregroundStyle(movie.hasFile == true ? .green : .orange)
                    Text(movie.displayStatus)
                        .font(.caption2)
                        .foregroundStyle(movie.hasFile == true ? .green : .secondary)

                    if let size = movie.sizeOnDisk, size > 0 {
                        Text("• \(ByteFormatter.format(bytes: size))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

                if movie.monitored == true {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
