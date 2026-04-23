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
        _moveFiles = State(initialValue: movie.hasFile ?? false)
    }

    private var rootFolderChanged: Bool {
        rootFolderPath != (movie.rootFolderPath ?? "")
    }

    private var hasExistingFiles: Bool {
        movie.hasFile ?? false
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
                Section {
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
                    
                    if rootFolderChanged && hasExistingFiles {
                        Toggle("Move Existing Files", isOn: $moveFiles)
                    }
                } header: {
                    Text("Library")
                } footer: {
                    if rootFolderChanged {
                        if hasExistingFiles {
                            Text(moveFiles
                                 ? "This updates the movie folder and asks Radarr to move existing files into the new root."
                                 : "This updates the movie folder, but existing files stay where they are until you move them manually.")
                        } else {
                            Text("This updates the movie folder so future imports target the new root.")
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
            tags: Array(selectedTags).sorted(),
            moveFiles: rootFolderChanged && hasExistingFiles && moveFiles
        )
        isSaving = false

        if success {
            dismiss()
        }
    }
}
