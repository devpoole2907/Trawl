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
    @State private var isSaving = false

    private var rootFolderOptions: [String] {
        let availablePaths = viewModel.rootFolders.map(\.path)
        guard !rootFolderPath.isEmpty, !availablePaths.contains(rootFolderPath) else {
            return availablePaths
        }
        return [rootFolderPath] + availablePaths
    }

    init(viewModel: RadarrViewModel, movie: RadarrMovie) {
        self.viewModel = viewModel
        self.movie = movie
        _monitored = State(initialValue: movie.monitored ?? true)
        _qualityProfileId = State(initialValue: movie.qualityProfileId ?? viewModel.qualityProfiles.first?.id ?? 0)
        _minimumAvailability = State(initialValue: movie.minimumAvailability ?? "released")
        _rootFolderPath = State(initialValue: movie.rootFolderPath ?? viewModel.rootFolders.first?.path ?? "")
        _selectedTags = State(initialValue: Set(movie.tags ?? []))
    }

    var body: some View {
        ArrSheetShell(
            title: "Edit Movie",
            confirmTitle: "Save",
            isConfirmDisabled: isSaving || qualityProfileId == 0 || rootFolderPath.isEmpty,
            isConfirmLoading: isSaving,
            onConfirm: {
                Task { await saveChanges() }
            }
        ) {
            Form {
                Section("Library") {
                    Toggle("Monitored", isOn: $monitored)

                    Picker("Quality Profile", selection: $qualityProfileId) {
                        ForEach(viewModel.qualityProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }

                    Picker("Minimum Availability", selection: $minimumAvailability) {
                        Text("Announced").tag("announced")
                        Text("In Cinemas").tag("inCinemas")
                        Text("Released").tag("released")
                        Text("Predb").tag("preDB")
                    }

                    Picker("Root Folder", selection: $rootFolderPath) {
                        ForEach(rootFolderOptions, id: \.self) { path in
                            Text(path).tag(path)
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
        let success = await viewModel.updateMovie(
            movie,
            monitored: monitored,
            qualityProfileId: qualityProfileId,
            minimumAvailability: minimumAvailability,
            rootFolderPath: rootFolderPath,
            tags: Array(selectedTags).sorted()
        )
        isSaving = false

        if success {
            dismiss()
        }
    }
}
