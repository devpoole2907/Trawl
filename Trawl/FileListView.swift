import SwiftUI

struct FileListView: View {
    @Bindable var viewModel: TorrentDetailViewModel

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.files.isEmpty {
                ProgressView("Loading files...")
            } else if viewModel.files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc.questionmark", description: Text("No files found for this torrent."))
            } else {
                ForEach(viewModel.files) { file in
                    FileRow(file: file) { priority in
                        Task {
                            await viewModel.setFilePriority(indices: [file.index], priority: priority)
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        .task {
            await viewModel.loadFiles()
        }
    }
}

// MARK: - File Row

private struct FileRow: View {
    let file: TorrentFile
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("\(Int(file.progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

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
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
