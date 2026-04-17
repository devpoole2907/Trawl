import SwiftUI
import SwiftData

struct SonarrSeriesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var profiles: [ArrServiceProfile]
    @State private var viewModel: SonarrViewModel?
    @State private var showSettings = false
    @State private var showCalendar = false
    @State private var showWantedMissing = false

    var body: some View {
        Group {
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
                    Text("Add a Sonarr server in Settings to get started.")
                } actions: {
                    Button("Add Server", systemImage: "plus") {
                        showSettings = true
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Series")
        .navigationSubtitle(navigationSubtitleText)
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbarContent }
        .refreshable {
            await viewModel?.loadSeries()
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
        .sheet(isPresented: $showCalendar) {
            NavigationStack {
                ArrCalendarView()
                    .environment(serviceManager)
            }
        }
        .sheet(isPresented: $showWantedMissing) {
            NavigationStack {
                ArrWantedView(initialScope: .series)
                    .environment(serviceManager)
            }
        }
        .navigationDestination(for: Int.self) { seriesId in
            if let vm = viewModel {
                SonarrSeriesDetailView(seriesId: seriesId, viewModel: vm)
            }
        }
        .task(id: serviceManager.sonarrConnected) {
            if serviceManager.sonarrConnected {
                if viewModel == nil {
                    let vm = SonarrViewModel(serviceManager: serviceManager)
                    viewModel = vm
                }
                await viewModel?.loadSeries()
            } else {
                viewModel = nil
            }
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
            List {
                ForEach(vm.filteredSeries) { show in
                    NavigationLink(value: show.id) {
                        SonarrSeriesRow(series: show)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await vm.deleteSeries(id: show.id, deleteFiles: false) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack {
                Button("Calendar", systemImage: "calendar") {
                    showCalendar = true
                }
                Button("Wanted / Missing", systemImage: "exclamationmark.triangle") {
                    showWantedMissing = true
                }
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            if let vm = viewModel {
                Menu {
                    ForEach(SonarrFilter.allCases) { filter in
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
                    ForEach(SonarrSortOrder.allCases) { order in
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

        ToolbarSpacer(.fixed, placement: .automatic)
    }

    private var navigationSubtitleText: String {
        guard let vm = viewModel else { return "" }
        let count = vm.filteredSeries.count
        return count == 1 ? "1 series" : "\(count) series"
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
        profiles.first(where: { $0.resolvedServiceType == .sonarr })
    }

    private var isShowingConnectingState: Bool {
        sonarrProfile != nil && (serviceManager.isInitializing || serviceManager.sonarrIsConnecting)
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

// MARK: - Series Row

struct SonarrSeriesRow: View {
    let series: SonarrSeries

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

                if let stats = series.statistics {
                    let fileCount = stats.episodeFileCount ?? 0
                    let totalCount = stats.episodeCount ?? 0
                    ProgressView(value: totalCount > 0 ? Double(fileCount) / Double(totalCount) : 0)
                        .tint(fileCount == totalCount ? .green : .blue)
                    Text("\(fileCount)/\(totalCount) episodes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if series.monitored == true {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}
