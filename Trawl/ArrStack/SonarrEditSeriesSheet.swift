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
    @State private var qualityProfileForDetails: ArrQualityProfile?

    private var rootFolderOptions: [String] {
        let availablePaths = viewModel.rootFolders.map(\.path)
        guard !rootFolderPath.isEmpty, !availablePaths.contains(rootFolderPath) else {
            return availablePaths
        }
        return [rootFolderPath] + availablePaths
    }

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

    private var rootFolderChanged: Bool {
        rootFolderPath != (series.rootFolderPath ?? "")
    }

    private var hasExistingFiles: Bool {
        (series.statistics?.episodeFileCount ?? 0) > 0
    }

    var body: some View {
        ArrSheetShell(
            title: "Edit Series",
            confirmTitle: "Save",
            isConfirmDisabled: isSaving || qualityProfileId == 0 || rootFolderPath.isEmpty,
            isConfirmLoading: isSaving,
            onConfirm: {
                Task { await saveChanges() }
            }
        ) {
            Form {
                Section {
                    Toggle("Monitored", isOn: $monitored)
                    Toggle("Season Folder", isOn: $seasonFolder)

                    Picker("Quality Profile", selection: $qualityProfileId) {
                        ForEach(viewModel.qualityProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }

                    if let selectedQualityProfile {
                        Button {
                            qualityProfileForDetails = selectedQualityProfile
                        } label: {
                            Label("View Selected Profile Details", systemImage: "info.circle")
                        }
                    }

                    Picker("Series Type", selection: $seriesType) {
                        Text("Standard").tag("standard")
                        Text("Daily").tag("daily")
                        Text("Anime").tag("anime")
                    }

                    Picker("Root Folder", selection: $rootFolderPath) {
                        ForEach(rootFolderOptions, id: \.self) { path in
                            let freeSpace = viewModel.rootFolders.first(where: { $0.path == path })?.freeSpace
                            let freeLabel = freeSpace.map { " · " + ByteFormatter.formatRounded(bytes: $0) + " free" } ?? ""
                            Text(path + freeLabel).tag(path)
                        }
                    }

                    if rootFolderChanged && hasExistingFiles {
                        Toggle("Move Existing Files", isOn: $moveFiles)
                    }
                } header: {
                    Text("Library")
                } footer: {
                    if rootFolderChanged {
                        if hasExistingFiles {
                            Text(moveFiles
                                 ? "This updates the series folder and asks Sonarr to move existing files into the new root."
                                 : "This updates the series folder, but existing files stay where they are until you move them manually.")
                        } else {
                            Text("This updates the series folder so future imports target the new root.")
                        }
                    }
                }

                Section("Tags") {
                    if viewModel.tags.isEmpty {
                        Text("No tags available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.tags) { tag in
                            Toggle(isOn: tagBinding(for: tag.id)) {
                                Text(tag.label)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $qualityProfileForDetails) { profile in
            NavigationStack {
                ArrQualityProfileDetailView(serviceType: .sonarr, profile: profile)
            }
        }
    }

    private func tagBinding(for tagId: Int) -> Binding<Bool> {
        Binding(
            get: { selectedTags.contains(tagId) },
            set: { isSelected in
                if isSelected {
                    selectedTags.insert(tagId)
                } else {
                    selectedTags.remove(tagId)
                }
            }
        )
    }

    private var selectedQualityProfile: ArrQualityProfile? {
        viewModel.qualityProfiles.first { $0.id == qualityProfileId }
    }

    private func saveChanges() async {
        isSaving = true
        let success = await viewModel.updateSeries(
            series,
            monitored: monitored,
            qualityProfileId: qualityProfileId,
            seriesType: seriesType,
            seasonFolder: seasonFolder,
            rootFolderPath: rootFolderPath,
            tags: Array(selectedTags).sorted(),
            moveFiles: rootFolderChanged && hasExistingFiles && moveFiles
        )
        isSaving = false

        if success {
            dismiss()
        }
    }
}
