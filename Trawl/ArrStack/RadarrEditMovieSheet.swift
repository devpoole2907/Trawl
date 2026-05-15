import SwiftUI

struct RadarrEditMovieSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RadarrViewModel
    let movie: RadarrMovie

    @State private var monitored: Bool
    @State private var qualityProfileId: Int
    @State private var minimumAvailability: String
    @State private var rootFolderPath: String
    @State private var selectedTags: Set<Int>
    @State private var moveFiles: Bool
    @State private var isSaving = false

    init(viewModel: RadarrViewModel, movie: RadarrMovie) {
        self.viewModel = viewModel
        self.movie = movie
        _monitored = State(initialValue: movie.monitored ?? true)
        _qualityProfileId = State(initialValue: movie.qualityProfileId ?? viewModel.qualityProfiles.first?.id ?? 0)
        _minimumAvailability = State(initialValue: movie.minimumAvailability ?? "released")
        _rootFolderPath = State(initialValue: movie.rootFolderPath ?? viewModel.rootFolders.first?.path ?? "")
        _selectedTags = State(initialValue: Set(movie.tags ?? []))
        _moveFiles = State(initialValue: false)
    }

    var body: some View {
        ArrEditItemSheet(
            title: "Edit Movie",
            serviceType: .radarr,
            itemKindLabel: "movie",
            serviceName: "Radarr",
            monitored: $monitored,
            qualityProfileId: $qualityProfileId,
            rootFolderPath: $rootFolderPath,
            selectedTags: $selectedTags,
            moveFiles: $moveFiles,
            isSaving: isSaving,
            hasExistingFiles: movie.hasFile ?? false,
            rootFolderChanged: rootFolderPath != (movie.rootFolderPath ?? ""),
            qualityProfiles: viewModel.qualityProfiles,
            rootFolders: viewModel.rootFolders,
            tags: viewModel.tags,
            onSave: { Task { await saveChanges() } }
        ) {
            Picker("Minimum Availability", selection: $minimumAvailability) {
                Text("Announced").tag("announced")
                Text("In Cinemas").tag("inCinemas")
                Text("Released").tag("released")
                Text("Predb").tag("preDB")
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
        let folderChanged = rootFolderPath != (movie.rootFolderPath ?? "")
        let hasFile = movie.hasFile ?? false
        let success = await viewModel.updateMovie(
            movie,
            monitored: monitored,
            qualityProfileId: qualityProfileId,
            minimumAvailability: minimumAvailability,
            rootFolderPath: rootFolderPath,
            tags: Array(selectedTags).sorted(),
            moveFiles: folderChanged && hasFile && moveFiles
        )
        isSaving = false
        if success { dismiss() }
    }
}
