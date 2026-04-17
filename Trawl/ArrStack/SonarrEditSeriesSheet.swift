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
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Library") {
                    Toggle("Monitored", isOn: $monitored)
                    Toggle("Season Folder", isOn: $seasonFolder)

                    Picker("Quality Profile", selection: $qualityProfileId) {
                        ForEach(viewModel.qualityProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }

                    Picker("Series Type", selection: $seriesType) {
                        Text("Standard").tag("standard")
                        Text("Daily").tag("daily")
                        Text("Anime").tag("anime")
                    }

                    Picker("Root Folder", selection: $rootFolderPath) {
                        ForEach(viewModel.rootFolders) { folder in
                            Text(folder.path).tag(folder.path)
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
            .navigationTitle("Edit Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveChanges() }
                    }
                    .disabled(isSaving || qualityProfileId == 0 || rootFolderPath.isEmpty)
                }
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

    private func saveChanges() async {
        isSaving = true
        let success = await viewModel.updateSeries(
            series,
            monitored: monitored,
            qualityProfileId: qualityProfileId,
            seriesType: seriesType,
            seasonFolder: seasonFolder,
            rootFolderPath: rootFolderPath,
            tags: Array(selectedTags).sorted()
        )
        isSaving = false

        if success {
            dismiss()
        }
    }
}
