import SwiftUI

struct FileListView: View {
    @Bindable var viewModel: TorrentDetailViewModel
    @State private var editMode: EditMode = .inactive
    @State private var selectedIndices: Set<Int> = []

    var body: some View {
        List(selection: $selectedIndices) {
            if viewModel.isLoading && viewModel.files.isEmpty {
                ProgressView("Loading files…")
            } else if viewModel.files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc.questionmark", description: Text("No files found for this torrent."))
            } else {
                ForEach(viewModel.files) { file in
                    FileRow(file: file, isEditing: editMode.isEditing) { priority in
                        Task {
                            await viewModel.setFilePriority(indices: [file.index], priority: priority)
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.files.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                }
            }
            
            if editMode.isEditing {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button(selectedIndices.count == viewModel.files.count ? "Deselect All" : "Select All") {
                            if selectedIndices.count == viewModel.files.count {
                                selectedIndices = []
                            } else {
                                selectedIndices = Set(viewModel.files.map(\.index))
                            }
                        }
                        
                        Spacer()
                        
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
                        .disabled(selectedIndices.isEmpty)
                    }
                }
            }
        }
        .task {
            await viewModel.loadFiles()
        }
    }
}

// MARK: - File Row

private struct FileRow: View {
    let file: TorrentFile
    let isEditing: Bool
    let onSetPriority: (FilePriority) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.name)
                .font(.subheadline)
                .lineLimit(2)

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
                        Label(file.priority.displayName, systemImage: file.priority.systemImage)
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
