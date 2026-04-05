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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel?.torrent?.name ?? "Detail")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel == nil {
                let vm = TorrentDetailViewModel(torrentHash: torrentHash, torrentService: torrentService, syncService: syncService)
                viewModel = vm
                async let properties: Void = vm.loadProperties()
                async let files: Void = vm.loadFiles()
                async let trackers: Void = vm.loadTrackers()
                _ = await (properties, files, trackers)
            }
        }
    }

    @ViewBuilder
    private func detailContent(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(torrent: torrent)
                speedSection(torrent: torrent)
                infoSection(torrent: torrent, vm: vm)
                actionsSection(vm: vm, torrent: torrent)
                navigationSection(vm: vm)
                if let error = vm.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
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
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(torrent: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(torrent.name)
                .font(.headline)
                .textSelection(.enabled)

            HStack {
                DetailStatusBadge(
                    title: torrent.state.displayName,
                    systemImage: torrent.state.systemImage,
                    tint: torrent.state.color
                )

                if let category = torrent.category, !category.isEmpty {
                    DetailBadgeLabel(title: category)
                }
            }

            ProgressView(value: torrent.progress)
                .tint(torrent.progress >= 1.0 ? .green : .blue)

            Text("\(Int(torrent.progress * 100))% complete")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func speedSection(torrent: Torrent) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
            MetricCard(title: "Download", value: ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed), systemImage: "arrow.down.circle.fill", tint: .blue)
            MetricCard(title: "Upload", value: ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed), systemImage: "arrow.up.circle.fill", tint: .green)

            if !torrent.state.isCompleted {
                MetricCard(title: "ETA", value: ByteFormatter.formatETA(seconds: torrent.eta), systemImage: "clock.fill", tint: .secondary)
            }
        }
    }

    @ViewBuilder
    private func infoSection(torrent: Torrent, vm: TorrentDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info")
                .font(.subheadline)
                .bold()

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
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func actionsSection(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.subheadline)
                .bold()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
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

                ActionButton(title: "Delete", systemImage: "trash", tint: .red) {
                    showDeleteAlert = true
                }
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
        LabeledContent {
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                .padding(.vertical, 12)
                .background(tint.opacity(0.12))
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)

            Text(value)
                .font(.headline)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct DetailStatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

private struct DetailBadgeLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.tertiary)
            .clipShape(Capsule())
    }
}
