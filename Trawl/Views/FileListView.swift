import SwiftUI

struct FileListView: View {
    @Environment(\.dismiss) private var dismiss
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
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    selectAllButton
                }
            }

            if editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    priorityMenu
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.files.isEmpty {
                    editButton
                }
            }
        }
        #else
        .safeAreaInset(edge: .bottom) {
            macBottomBar
        }
        #endif
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

    private var selectAllButton: some View {
        Button(selectedIndices.count == viewModel.files.count ? "Deselect All" : "Select All") {
            if selectedIndices.count == viewModel.files.count {
                selectedIndices = []
            } else {
                selectedIndices = Set(viewModel.files.map(\.index))
            }
        }
    }

    private var priorityMenu: some View {
        Menu {
            #if os(macOS)
            ForEach(FilePriority.allCases) { priority in
                Button {
                    setPriority(priority)
                } label: {
                    Label(priority.displayName, systemImage: priority.systemImage)
                }
            }
            #else
            Menu("Set Priority") {
                ForEach(FilePriority.allCases) { priority in
                    Button {
                        setPriority(priority)
                    } label: {
                        Label(priority.displayName, systemImage: priority.systemImage)
                    }
                }
            }
            #endif
        } label: {
            #if os(macOS)
            Text("Set Priority")
            #else
            Label("File Actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
            #endif
        }
        .disabled(selectedIndices.isEmpty)
    }

    private var editButton: some View {
        Button(editButtonTitle) {
            withAnimation {
                selectedIndices = []
                editMode = editMode.isEditing ? .inactive : .active
            }
        }
    }

    private var editButtonTitle: String {
        guard editMode.isEditing else { return "Edit" }
        #if os(macOS)
        return "Done Editing"
        #else
        return "Done"
        #endif
    }

    #if os(macOS)
    private var macBottomBar: some View {
        HStack(spacing: 10) {
            Spacer()

            if editMode.isEditing {
                selectAllButton
                    .fixedSize()
                priorityMenu
                    .fixedSize()
            }

            if !viewModel.files.isEmpty {
                editButton
                    .fixedSize()
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
    #endif

    private func setPriority(_ priority: FilePriority) {
        let indices = Array(selectedIndices)
        Task {
            await viewModel.setFilePriority(indices: indices, priority: priority)
            selectedIndices = []
            withAnimation {
                editMode = .inactive
            }
        }
    }
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
                        #if os(iOS)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        #endif
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
