import SwiftUI

struct SonarrEditSeriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries

    @State private var monitored: Bool
    @State private var qualityProfileId: Int
    @State private var seriesType: String
    @State private var seasonFolder: Bool
    @State private var rootFolderPath: String
    @State private var selectedTags: Set<Int>
    @State private var monitoredSeasons: [Int: Bool]
    @State private var seasonsExpanded = true
    @State private var moveFiles: Bool
    @State private var isSaving = false
    @State private var showMonitorAllEpisodesAlert = false

    private var wasOriginallyUnmonitored: Bool { series.monitored != true }

    init(viewModel: SonarrViewModel, series: SonarrSeries) {
        self.viewModel = viewModel
        self.series = series
        _monitored = State(initialValue: series.monitored ?? true)
        _qualityProfileId = State(initialValue: series.qualityProfileId ?? viewModel.qualityProfiles.first?.id ?? 0)
        _seriesType = State(initialValue: series.seriesType ?? "standard")
        _seasonFolder = State(initialValue: series.seasonFolder ?? true)
        _rootFolderPath = State(initialValue: series.rootFolderPath ?? viewModel.rootFolders.first?.path ?? "")
        _selectedTags = State(initialValue: Set(series.tags ?? []))
        _monitoredSeasons = State(initialValue: Dictionary(uniqueKeysWithValues: (series.seasons ?? []).map {
            ($0.seasonNumber, $0.monitored ?? true)
        }))
        _moveFiles = State(initialValue: (series.statistics?.episodeFileCount ?? 0) > 0)
    }

    var body: some View {
        ArrEditItemSheet(
            title: "Edit Series",
            serviceType: .sonarr,
            itemKindLabel: "series",
            serviceName: "Sonarr",
            monitored: $monitored,
            qualityProfileId: $qualityProfileId,
            rootFolderPath: $rootFolderPath,
            selectedTags: $selectedTags,
            moveFiles: $moveFiles,
            isSaving: isSaving,
            hasExistingFiles: (series.statistics?.episodeFileCount ?? 0) > 0,
            rootFolderChanged: rootFolderPath != (series.rootFolderPath ?? ""),
            qualityProfiles: viewModel.qualityProfiles,
            rootFolders: viewModel.rootFolders,
            tags: viewModel.tags,
            onSave: { attemptSave() }
        ) {
            Toggle("Season Folder", isOn: $seasonFolder)
            Picker("Series Type", selection: $seriesType) {
                Text("Standard").tag("standard")
                Text("Daily").tag("daily")
                Text("Anime").tag("anime")
            }
            if let seasons = series.seasons, !seasons.isEmpty {
                DisclosureGroup("Seasons", isExpanded: $seasonsExpanded) {
                    ForEach(seasons.sorted { $0.seasonNumber < $1.seasonNumber }, id: \.seasonNumber) { season in
                        Toggle(
                            season.seasonNumber == 0 ? "Specials" : "Season \(season.seasonNumber)",
                            isOn: Binding(
                                get: { monitoredSeasons[season.seasonNumber] ?? season.monitored ?? true },
                                set: { monitoredSeasons[season.seasonNumber] = $0 }
                            )
                        )
                    }
                }
            }
        }
        .task {
            await refreshConfiguration()
        }
        .alert("Monitor All Episodes?", isPresented: $showMonitorAllEpisodesAlert) {
            Button("Monitor All") { Task { await saveChanges(monitorAllEpisodes: true) } }
            Button("Series Only") { Task { await saveChanges(monitorAllEpisodes: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This series was unmonitored. Are you sure you want to mark all episodes as monitored?")
        }
    }

    private func refreshConfiguration() async {
        await viewModel.refreshConfiguration()
        if qualityProfileId == 0, let id = viewModel.qualityProfiles.first?.id {
            qualityProfileId = id
        }
        if rootFolderPath.isEmpty, let path = viewModel.rootFolders.first?.path {
            rootFolderPath = path
        }
    }

    private func attemptSave() {
        if wasOriginallyUnmonitored && monitored {
            showMonitorAllEpisodesAlert = true
        } else {
            Task { await saveChanges(monitorAllEpisodes: false) }
        }
    }

    private func saveChanges(monitorAllEpisodes: Bool) async {
        isSaving = true
        let hasFiles = (series.statistics?.episodeFileCount ?? 0) > 0
        let folderChanged = rootFolderPath != (series.rootFolderPath ?? "")
        let success = await viewModel.updateSeries(
            series,
            monitored: monitored,
            qualityProfileId: qualityProfileId,
            seriesType: seriesType,
            seasonFolder: seasonFolder,
            rootFolderPath: rootFolderPath,
            tags: Array(selectedTags).sorted(),
            seasons: series.seasons?.map { season in
                SonarrSeason(
                    seasonNumber: season.seasonNumber,
                    monitored: monitoredSeasons[season.seasonNumber] ?? season.monitored ?? true,
                    statistics: season.statistics
                )
            },
            moveFiles: folderChanged && hasFiles && moveFiles,
            monitorAllSeasons: monitorAllEpisodes
        )
        guard success else {
            isSaving = false
            return
        }
        if monitorAllEpisodes {
            let episodesSuccess = await viewModel.monitorAllEpisodes(seriesId: series.id, instanceID: series.instanceID)
            isSaving = false
            if episodesSuccess { dismiss() }
            return
        }
        isSaving = false
        dismiss()
    }
}

#if DEBUG
#Preview("Typical Inputs") {
    SonarrPreviewHost(state: .sonarrConnectionError("Preview offline.")) { manager in
        SonarrEditSeriesSheet(
            viewModel: SonarrViewModel(previewSeries: [.preview], serviceManager: manager),
            series: .preview
        )
    }
}

#Preview("Missing Metadata") {
    SonarrPreviewHost(state: .sonarrConnectionError("Preview offline.")) { manager in
        SonarrEditSeriesSheet(
            viewModel: SonarrViewModel(previewSeries: [.previewMissingArt], serviceManager: manager),
            series: .previewMissingArt
        )
    }
}

#Preview("Long Title") {
    SonarrPreviewHost(state: .sonarrConnectionError("Preview offline.")) { manager in
        SonarrEditSeriesSheet(
            viewModel: SonarrViewModel(previewSeries: [.previewLongTitle], serviceManager: manager),
            series: .previewLongTitle
        )
    }
}

#Preview("Ended Series") {
    SonarrPreviewHost(state: .sonarrConnectionError("Preview offline.")) { manager in
        SonarrEditSeriesSheet(
            viewModel: SonarrViewModel(previewSeries: [.previewEnded], serviceManager: manager),
            series: .previewEnded
        )
    }
}
#endif
