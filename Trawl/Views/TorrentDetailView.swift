import SwiftUI

struct TorrentDetailView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: TorrentDetailViewModel?

    @State private var showDeleteAlert = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showLocationAlert = false
    @State private var locationText = ""

    let torrentHash: String
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init(torrentHash: String) {
        self.torrentHash = torrentHash
    }

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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let vm = viewModel, let torrent = vm.torrent {
                #if os(macOS)
                // A split view has one window toolbar on macOS. Separate this
                // detail action from the list column's toolbar group.
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    actionsMenu(vm: vm, torrent: torrent)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    actionsMenu(vm: vm, torrent: torrent)
                }
                #endif
            }
        }
        .task {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            if viewModel == nil {
                let vm = TorrentDetailViewModel(torrentHash: torrentHash, torrentService: torrentService, syncService: syncService, notificationCenter: inAppNotificationCenter)
                viewModel = vm
                async let properties: Void = vm.loadProperties()
                async let files: Void = vm.loadFiles()
                async let trackers: Void = {
                    do {
                        try await vm.loadTrackers()
                    } catch {}
                }()
                _ = await (properties, files, trackers)
            }
        }
    }

    @ViewBuilder
    private func detailContent(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        List {
            Section {
                headerSection(torrent: torrent, vm: vm)
            }

            Section("Browse") {
                navigationSection(vm: vm)
            }

            Section("Info") {
                infoSection(torrent: torrent, vm: vm)
            }

            if let error = vm.error {
                Section {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text(error)
                    }
                        .foregroundStyle(.red)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .refreshable {
            await syncService.refreshNow()
            async let properties: Void = vm.loadProperties()
            async let files: Void = vm.loadFiles()
            async let trackers: Void = {
                do {
                    try await vm.loadTrackers()
                } catch {}
            }()
            _ = await (properties, files, trackers)
        }
        .alert("Delete Torrent?", isPresented: $showDeleteAlert) {
            Button("Delete and Remove Files", role: .destructive) {
                Task {
                    if await vm.deleteTorrent(deleteFiles: true) { dismiss() }
                }
            }
            Button("Delete Torrent Only", role: .destructive) {
                Task {
                    if await vm.deleteTorrent(deleteFiles: false) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action can't be undone.")
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
        .alert(item: Binding(
            get: { vm.actionErrorAlert },
            set: { vm.actionErrorAlert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(torrent: Torrent, vm: TorrentDetailViewModel) -> some View {
        let currentTags = vm.currentTags

        TorrentSummaryView(
            torrent: torrent,
            titleFont: .headline,
            titleLineLimit: nil,
            isTitleSelectable: true,
            displayedSize: torrent.totalSize
        ) {
            if !currentTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(currentTags, id: \.self) { tag in
                            DetailTagChip(title: tag)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.snappy, value: currentTags)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: currentTags)
    }

    @ViewBuilder
    private func infoSection(torrent: Torrent, vm: TorrentDetailViewModel) -> some View {
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

    @ViewBuilder
    private func actionsMenu(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        let isPaused = torrent.state == .pausedDL || torrent.state == .pausedUP
            || torrent.state == .stoppedDL || torrent.state == .stoppedUP

        Menu {
            if isPaused {
                Button {
                    Task { await vm.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
            } else {
                Button {
                    Task { await vm.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            }

            Button {
                Task { await vm.recheck() }
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                renameText = torrent.name
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                locationText = torrent.savePath
                showLocationAlert = true
            } label: {
                Label("Move", systemImage: "folder")
            }

            Menu {
                categoryMenuButton(title: "None", category: "", currentCategory: torrent.category)
                ForEach(vm.availableCategories, id: \.self) { category in
                    categoryMenuButton(title: category, category: category, currentCategory: torrent.category)
                }
            } label: {
                Label("Category", systemImage: "tag")
            }

            Menu {
                if vm.availableTags.isEmpty {
                    Text("No tags available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.availableTags, id: \.self) { tag in
                        tagMenuButton(title: tag, viewModel: vm)
                    }
                }
            } label: {
                Label("Tags", systemImage: "number")
            }

            Divider()

            TorrentDownloadOptionsMenu(
                torrent: torrent,
                torrentService: torrentService,
                syncService: syncService,
                notificationCenter: inAppNotificationCenter,
                downloadLimitFallback: syncService.serverState?.dlRateLimit,
                uploadLimitFallback: syncService.serverState?.upRateLimit
            )

            Divider()

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Torrent", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Torrent Actions")
    }

    @ViewBuilder
    private func navigationSection(vm: TorrentDetailViewModel) -> some View {
        NavigationLink {
            FileListView(viewModel: vm)
        } label: {
            HStack {
                Label("Files", systemImage: "doc.on.doc")
                Spacer()
                Text("\(vm.files.count)")
                    .foregroundStyle(.secondary)
            }
        }

        NavigationLink {
            TrackerListView(viewModel: vm)
        } label: {
            HStack {
                Label("Trackers", systemImage: "antenna.radiowaves.left.and.right")
                Spacer()
                Text("\(vm.trackers.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func dateString(from timestamp: Int) -> String {
        guard timestamp > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func categoryMenuButton(title: String, category: String, currentCategory: String?) -> some View {
        Button {
            Task { await viewModel?.setCategory(category) }
        } label: {
            if normalizedCategory(currentCategory) == normalizedCategory(category) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func tagMenuButton(title: String, viewModel: TorrentDetailViewModel) -> some View {
        Button {
            Task { await viewModel.toggleTag(title) }
        } label: {
            if viewModel.currentTags.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func normalizedCategory(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

private struct DetailTagChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "number")
            Text(title)
        }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.12))
            .foregroundStyle(.cyan)
            .clipShape(Capsule())
    }
}

#if DEBUG
extension TorrentDetailView {
    init(
        torrentHash: String,
        previewViewModel: TorrentDetailViewModel?,
        skipsAutomaticLoading: Bool = true
    ) {
        self.torrentHash = torrentHash
        self._viewModel = State(initialValue: previewViewModel)
        self.skipsAutomaticLoading = skipsAutomaticLoading
    }
}

#Preview("Typical") {
    let vm = TorrentDetailViewModel(previewTorrent: .previewDownloading)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentDetailView(torrentHash: Torrent.previewDownloading.hash, previewViewModel: vm)
        }
    }
}

#Preview("Long Name") {
    let vm = TorrentDetailViewModel(previewTorrent: .previewLongName)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentDetailView(torrentHash: Torrent.previewLongName.hash, previewViewModel: vm)
        }
    }
}

#Preview("Errored") {
    let vm = TorrentDetailViewModel(
        previewTorrent: .previewError,
        error: "Tracker returned an unreachable host error."
    )
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentDetailView(torrentHash: Torrent.previewError.hash, previewViewModel: vm)
        }
    }
}

#Preview("Loading") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentDetailView(torrentHash: Torrent.preview.hash, previewViewModel: nil)
        }
    }
}

#Preview("Missing Torrent") {
    let vm = TorrentDetailViewModel(
        torrentHash: "missing",
        torrentService: .preview(),
        syncService: .preview()
    )
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentDetailView(torrentHash: "missing", previewViewModel: vm)
        }
    }
}
#endif
