import SwiftUI

struct TorrentDetailView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: TorrentDetailViewModel?

    // Alert state
    @State private var showDeleteAlert = false
    @State private var deleteFiles = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showLocationAlert = false
    @State private var locationText = ""
    @State private var showCategoryPicker = false

    let torrentHash: String

    var body: some View {
        Group {
            if let vm = viewModel, let torrent = vm.torrent {
                detailContent(vm: vm, torrent: torrent)
            } else if let vm = viewModel, vm.torrent == nil {
                ContentUnavailableView("Torrent Not Found", systemImage: "questionmark.circle", description: Text("This torrent may have been removed."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(viewModel?.torrent?.name ?? "Detail")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel == nil {
                let vm = TorrentDetailViewModel(torrentHash: torrentHash, torrentService: torrentService, syncService: syncService)
                viewModel = vm
                await vm.loadProperties()
            }
        }
    }

    @ViewBuilder
    private func detailContent(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                headerSection(torrent: torrent)

                // Speed & ETA
                speedSection(torrent: torrent)

                // Info grid
                infoSection(torrent: torrent, vm: vm)

                // Actions
                actionsSection(vm: vm, torrent: torrent)

                // Navigation links
                navigationSection(vm: vm)

                // Error
                if let error = vm.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
            }
            .padding()
        }
        .alert("Delete Torrent?", isPresented: $showDeleteAlert) {
            Toggle("Also delete files", isOn: $deleteFiles)
            Button("Delete", role: .destructive) {
                Task {
                    await vm.deleteTorrent(deleteFiles: deleteFiles)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Torrent", isPresented: $showRenameAlert) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                Task { await vm.rename(to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Change Save Path", isPresented: $showLocationAlert) {
            TextField("New path", text: $locationText)
            Button("Move") {
                Task { await vm.setLocation(locationText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Set Category", isPresented: $showCategoryPicker) {
            Button("None") {
                Task { await vm.setCategory("") }
            }
            ForEach(vm.availableCategories, id: \.self) { cat in
                Button(cat) {
                    Task { await vm.setCategory(cat) }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(torrent: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(torrent.name)
                .font(.headline)

            HStack {
                Label(torrent.state.displayName, systemImage: torrent.state.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(torrent.state.color)

                if let category = torrent.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }

            ProgressView(value: torrent.progress)
                .tint(torrent.progress >= 1.0 ? .green : .blue)

            Text("\(Int(torrent.progress * 100))% complete")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func speedSection(torrent: Torrent) -> some View {
        HStack(spacing: 24) {
            VStack {
                Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Download")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack {
                Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed), systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Text("Upload")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !torrent.state.isCompleted {
                VStack {
                    Label(ByteFormatter.formatETA(seconds: torrent.eta), systemImage: "clock.fill")
                    Text("ETA")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func infoSection(torrent: Torrent, vm: TorrentDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info")
                .font(.subheadline)
                .fontWeight(.semibold)

            InfoRow(label: "Size", value: ByteFormatter.format(bytes: torrent.totalSize))
            InfoRow(label: "Downloaded", value: ByteFormatter.format(bytes: torrent.totalSize - torrent.amountLeft))
            InfoRow(label: "Ratio", value: String(format: "%.2f", torrent.ratio))
            InfoRow(label: "Seeds", value: "\(torrent.numSeeds)")
            InfoRow(label: "Peers", value: "\(torrent.numLeechs)")
            InfoRow(label: "Added", value: dateString(from: torrent.addedOn))
            InfoRow(label: "Save Path", value: torrent.savePath)

            if let props = vm.properties {
                InfoRow(label: "Total Uploaded", value: ByteFormatter.format(bytes: props.totalUploaded))
                InfoRow(label: "Total Downloaded", value: ByteFormatter.format(bytes: props.totalDownloaded))
                InfoRow(label: "Connections", value: "\(props.nbConnections)")
                InfoRow(label: "Pieces", value: "\(props.piecesHave)/\(props.piecesNum)")
            }

            if let comment = torrent.comment, !comment.isEmpty {
                InfoRow(label: "Comment", value: comment)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func actionsSection(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if torrent.state == .pausedDL || torrent.state == .pausedUP {
                    ActionButton(title: "Resume", systemImage: "play.fill", tint: .green) {
                        Task { await vm.resume() }
                    }
                } else {
                    ActionButton(title: "Pause", systemImage: "pause.fill", tint: .orange) {
                        Task { await vm.pause() }
                    }
                }

                ActionButton(title: "Recheck", systemImage: "arrow.clockwise", tint: .blue) {
                    Task { await vm.recheck() }
                }

                ActionButton(title: "Rename", systemImage: "pencil", tint: .purple) {
                    renameText = torrent.name
                    showRenameAlert = true
                }

                ActionButton(title: "Move", systemImage: "folder", tint: .indigo) {
                    locationText = torrent.savePath
                    showLocationAlert = true
                }

                ActionButton(title: "Category", systemImage: "tag", tint: .teal) {
                    showCategoryPicker = true
                }

                ActionButton(title: "Delete", systemImage: "trash", tint: .red) {
                    showDeleteAlert = true
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func navigationSection(vm: TorrentDetailViewModel) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                FileListView(viewModel: vm)
            } label: {
                HStack {
                    Label("Files", systemImage: "doc.on.doc")
                    Spacer()
                    Text("\(vm.files.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            Divider().padding(.leading)

            NavigationLink {
                TrackerListView(viewModel: vm)
            } label: {
                HStack {
                    Label("Trackers", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text("\(vm.trackers.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func dateString(from timestamp: Int) -> String {
        guard timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Supporting Views

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(tint.opacity(0.12))
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
