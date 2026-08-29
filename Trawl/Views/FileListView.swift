import SwiftUI

struct FileListView: View {
    @Bindable var viewModel: TorrentDetailViewModel
    @State private var editMode: SelectionMode = .inactive
    @State private var selectedIndices: Set<Int> = []

    var body: some View {
        List(selection: $selectedIndices) {
            if viewModel.isLoading && viewModel.files.isEmpty {
                ProgressView("Loading files…")
            } else if viewModel.files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc.questionmark", description: Text("No files found for this torrent."))
            } else {
                ForEach(viewModel.files) { file in
                    FileRow(file: file, savePath: viewModel.torrent?.savePath, isEditing: editMode.isEditing) { priority in
                        Task {
                            await viewModel.setFilePriority(indices: [file.index], priority: priority)
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        #if os(iOS)
        .environment(\.editMode, swiftUIEditMode)
        #endif
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: fileSelectionLeadingToolbarPlacement) {
                    Button(selectedIndices.count == viewModel.files.count ? "Deselect All" : "Select All") {
                        if selectedIndices.count == viewModel.files.count {
                            selectedIndices = []
                        } else {
                            selectedIndices = Set(viewModel.files.map(\.index))
                        }
                    }
                }
            }

            if editMode.isEditing {
                ToolbarItem(placement: fileSelectionTrailingToolbarPlacement) {
                    Menu {
                        Menu("Set Priority") {
                            ForEach(FilePriority.allCases) { priority in
                                Button {
                                    let indices = Array(selectedIndices)
                                    Task {
                                        await viewModel.setFilePriority(indices: indices, priority: priority)
                                        selectedIndices = []
                                        withAnimation {
                                            editMode = .inactive
                                        }
                                    }
                                } label: {
                                    Label(priority.displayName, systemImage: priority.systemImage)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(selectedIndices.isEmpty)
                }
            }

            ToolbarItem(placement: fileEditToolbarPlacement) {
                if !viewModel.files.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation {
                            if editMode.isEditing {
                                selectedIndices = []
                                editMode = .inactive
                            } else {
                                editMode = .active
                            }
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.loadFiles()
        }
        .refreshable {
            await viewModel.loadFiles()
        }
    }

    #if os(iOS)
    private var swiftUIEditMode: Binding<EditMode> {
        Binding(
            get: { editMode.isEditing ? .active : .inactive },
            set: { editMode = $0.isEditing ? .active : .inactive }
        )
    }
    #endif
}

private var fileEditToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
}

private var fileSelectionToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .bottomBar
    #else
    .automatic
    #endif
}

private var fileSelectionLeadingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
}

private var fileSelectionTrailingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
}

// MARK: - File Row

private struct FileRow: View {
    let file: TorrentFile
    let savePath: String?
    let isEditing: Bool
    let onSetPriority: (FilePriority) -> Void

    private var fileName: String {
        (file.name as NSString).lastPathComponent
    }

    /// The file's full on-disk directory - the torrent's save path plus any
    /// subfolder from the file's relative name within the torrent. `file.name`
    /// alone has no directory component for single-file torrents, so this is
    /// needed to show a meaningful path rather than nothing.
    private var directoryPath: String? {
        guard let savePath, !savePath.isEmpty else {
            let directory = (file.name as NSString).deletingLastPathComponent
            return directory.isEmpty ? nil : directory
        }
        let fullPath = (savePath as NSString).appendingPathComponent(file.name)
        let directory = (fullPath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fileName)
                .font(.subheadline)
                .lineLimit(2)

            if let directoryPath {
                Text(directoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(value: file.progress)
                .tint(file.progress >= 1.0 ? .green : .blue)

            HStack {
                Text(ByteFormatter.format(bytes: file.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(Int(file.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !isEditing {
                    Menu {
                        ForEach(FilePriority.allCases) { priority in
                            Button {
                                onSetPriority(priority)
                            } label: {
                                if file.priority == priority {
                                    Label(priority.displayName, systemImage: "checkmark")
                                } else {
                                    Label(priority.displayName, systemImage: priority.systemImage)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: file.priority.systemImage)
                            Text(file.priority.displayName)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("Loaded") {
    let vm = TorrentDetailViewModel(files: TorrentFile.previewList)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            FileListView(viewModel: vm)
        }
    }
}

#Preview("Empty") {
    let vm = TorrentDetailViewModel(files: [])
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            FileListView(viewModel: vm)
        }
    }
}

#Preview("Loading") {
    let vm = TorrentDetailViewModel(files: [], isLoading: true)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            FileListView(viewModel: vm)
        }
    }
}

#Preview("Error") {
    let vm = TorrentDetailViewModel(files: [], error: "Failed to load files - connection refused.")
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            FileListView(viewModel: vm)
        }
    }
}
#endif
