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
    @State private var moveFiles: Bool
    @State private var isSaving = false

    init(viewModel: SonarrViewModel, series: SonarrSeries) {
        self.viewModel = viewModel
        self.series = series
        _monitored = State(initialValue: series.monitored ?? true)
        _qualityProfileId = State(initialValue: series.qualityProfileId ?? viewModel.qualityProfiles.first?.id ?? 0)
        _seriesType = State(initialValue: series.seriesType ?? "standard")
        _seasonFolder = State(initialValue: series.seasonFolder ?? true)
        _rootFolderPath = State(initialValue: series.rootFolderPath ?? viewModel.rootFolders.first?.path ?? "")
        _selectedTags = State(initialValue: Set(series.tags ?? []))
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
            onSave: { Task { await saveChanges() } }
        ) {
            Toggle("Season Folder", isOn: $seasonFolder)
            Picker("Series Type", selection: $seriesType) {
                Text("Standard").tag("standard")
                Text("Daily").tag("daily")
                Text("Anime").tag("anime")
            }
        }
        .task {
            await refreshConfiguration()
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

    private func saveChanges() async {
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
            moveFiles: folderChanged && hasFiles && moveFiles
        )
        isSaving = false
        if success { dismiss() }
    }
}
