import SwiftUI
import SwiftData

struct RadarrMovieListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Query private var profiles: [ArrServiceProfile]
    @State private var viewModel: RadarrViewModel?
    @State private var showSettings = false
    @State private var showAddSheet = false
    @State private var showCalendar = false
    @State private var showWantedMissing = false
    @State private var pendingDeleteMovie: RadarrMovie?

    var body: some View {
        Group {
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
        .navigationTitle("Movies")
        .navigationSubtitle(navigationSubtitleText)
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Delete Movie?",
            isPresented: Binding(
                get: { pendingDeleteMovie != nil },
                set: { if !$0 { pendingDeleteMovie = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMovie
        ) { movie in
            Button("Delete from Radarr", role: .destructive) {
                pendingDeleteMovie = nil
                Task { await viewModel?.deleteMovie(id: movie.id, deleteFiles: false) }
            }
            Button("Delete Movie and Files", role: .destructive) {
                pendingDeleteMovie = nil
                Task { await viewModel?.deleteMovie(id: movie.id, deleteFiles: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteMovie = nil
            }
        } message: { movie in
            Text("Choose whether to remove only \(movie.title) from Radarr or also delete its files.")
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
                ArrCalendarView()
                    .environment(serviceManager)
                    .environment(syncService)
            }
        }
        .sheet(isPresented: $showWantedMissing) {
            NavigationStack {
                ArrWantedView(initialScope: .movies)
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
                return
            }
            let vm = RadarrViewModel(serviceManager: serviceManager)
            viewModel = vm
            async let loadMovies = vm.loadMovies()
            async let loadQueue = vm.loadQueue()
            _ = await (loadMovies, loadQueue)
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
            List {
                ForEach(vm.filteredMovies) { movie in
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
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await vm.toggleMovieMonitored(movie) }
                        } label: {
                            Label(
                                movie.monitored == true ? "Unmonitor" : "Monitor",
                                systemImage: movie.monitored == true ? "bookmark.slash" : "bookmark.fill"
                            )
                        }
                        .tint(movie.monitored == true ? .orange : .blue)

                        if movie.hasFile != true {
                            Button {
                                Task { await vm.searchMovie(movieId: movie.id) }
                            } label: {
                                Label("Search", systemImage: "magnifyingglass")
                            }
                            .tint(.purple)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if let vm = viewModel {
                Menu {
                    ForEach(RadarrFilter.allCases) { filter in
                        Button {
                            vm.selectedFilter = filter
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
                            vm.sortOrder = order
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

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Calendar", systemImage: "calendar") {
                showCalendar = true
            }
            Button("Wanted / Missing", systemImage: "exclamationmark.triangle") {
                showWantedMissing = true
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

    private var navigationSubtitleText: String {
        guard let vm = viewModel else { return "" }
        let count = vm.filteredMovies.count
        return count == 1 ? "1 movie" : "\(count) movies"
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
        profiles.first(where: { $0.resolvedServiceType == .radarr })
    }

    private var isShowingConnectingState: Bool {
        radarrProfile != nil && (serviceManager.isInitializing || serviceManager.radarrIsConnecting)
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
                    if let studio = movie.studio, !studio.isEmpty {
                        Text("• \(studio)").font(.caption2)
                    }
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
