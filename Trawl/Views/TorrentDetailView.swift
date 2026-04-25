import SwiftUI

struct TorrentDetailView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: TorrentDetailViewModel?

    @State private var showDeleteAlert = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showLocationAlert = false
    @State private var locationText = ""
    @State private var showTagsSheet = false
    @State private var selectedDownloadLimit: Int64 = 0
    @State private var selectedUploadLimit: Int64 = 0

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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let vm = viewModel, let torrent = vm.torrent {
                ToolbarItem(placement: .automatic) {
                    actionsMenu(vm: vm, torrent: torrent)
                }
            }
        }
        .task {
            if viewModel == nil {
                let vm = TorrentDetailViewModel(torrentHash: torrentHash, torrentService: torrentService, syncService: syncService)
                viewModel = vm
                async let properties: Void = vm.loadProperties()
                async let files: Void = vm.loadFiles()
                async let trackers: Void = vm.loadTrackers()
                _ = await (properties, files, trackers)
                if let properties = vm.properties {
                    selectedDownloadLimit = max(0, properties.dlLimit)
                    selectedUploadLimit = max(0, properties.upLimit)
                }
            }
        }
    }

    @ViewBuilder
    private func detailContent(vm: TorrentDetailViewModel, torrent: Torrent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(torrent: torrent, vm: vm)
                infoSection(torrent: torrent, vm: vm)
                navigationSection(vm: vm)
                if let error = vm.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding()
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
        .sheet(isPresented: $showTagsSheet) {
            TorrentTagsSheet(viewModel: vm)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(torrent: Torrent, vm: TorrentDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(torrent.name)
                .font(.headline)
                .textSelection(.enabled)

            HStack(spacing: 6) {
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

            if !vm.currentTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.currentTags, id: \.self) { tag in
                            DetailTagChip(title: tag)
                        }
                    }
                }
            } else if !vm.availableTags.isEmpty {
                Button {
                    showTagsSheet = true
                } label: {
                    Label("Add Tags", systemImage: "number")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("\(Int(torrent.progress * 100))% complete")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormatter.format(bytes: torrent.totalSize))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            let hasDownload = torrent.dlspeed > 0
            let hasUpload = torrent.upspeed > 0
            let hasETA = !torrent.state.isCompleted && torrent.eta > 0
            if hasDownload || hasUpload || hasETA {
                HStack(spacing: 16) {
                    if hasDownload {
                        Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed), systemImage: "arrow.down")
                            .foregroundStyle(.blue)
                    }
                    if hasUpload {
                        Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed), systemImage: "arrow.up")
                            .foregroundStyle(.green)
                    }
                    if hasETA {
                        Label(ByteFormatter.formatETA(seconds: torrent.eta), systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
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

            Button {
                showTagsSheet = true
            } label: {
                Label("Tags", systemImage: "number")
            }

            Toggle(
                "Sequential Download",
                isOn: Binding(
                    get: { vm.isSequentialDownloadEnabled },
                    set: { enabled in
                        Task { await vm.setSequentialDownload(enabled) }
                    }
                )
            )
            .disabled(vm.isUpdatingSequentialDownload)

            Toggle(
                "First and Last Pieces First",
                isOn: Binding(
                    get: { vm.isFirstLastPiecePriorityEnabled },
                    set: { enabled in
                        Task { await vm.setFirstLastPiecePriority(enabled) }
                    }
                )
            )
            .disabled(vm.isUpdatingFirstLastPiecePriority)

            Divider()

            Menu {
                Picker(
                    "Download Limit",
                    selection: Binding(
                        get: { selectedDownloadLimit },
                        set: { newVal in
                            selectedDownloadLimit = newVal
                            Task { await vm.setTorrentDownloadLimit(newVal) }
                        }
                    )
                ) {
                    ForEach(limitOptions(including: max(0, vm.properties?.dlLimit ?? 0)), id: \.self) { limit in
                        Text(torrentLimitLabel(limit, globalFallback: syncService.serverState?.dlRateLimit)).tag(limit)
                    }
                }
            } label: {
                Label("Download Limit", systemImage: "arrow.down.circle")
            }

            Menu {
                Picker(
                    "Upload Limit",
                    selection: Binding(
                        get: { selectedUploadLimit },
                        set: { newVal in
                            selectedUploadLimit = newVal
                            Task { await vm.setTorrentUploadLimit(newVal) }
                        }
                    )
                ) {
                    ForEach(limitOptions(including: max(0, vm.properties?.upLimit ?? 0)), id: \.self) { limit in
                        Text(torrentLimitLabel(limit, globalFallback: syncService.serverState?.upRateLimit)).tag(limit)
                    }
                }
            } label: {
                Label("Upload Limit", systemImage: "arrow.up.circle")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Torrent", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Helpers

    private func dateString(from timestamp: Int) -> String {
        guard timestamp > 0 else { return "—" }
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

    private func normalizedCategory(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func limitOptions(including currentLimit: Int64) -> [Int64] {
        let megabyte = Int64(1_048_576)
        var options: [Int64] = [
            0,
            megabyte,
            5 * megabyte,
            10 * megabyte,
            25 * megabyte,
            50 * megabyte,
            100 * megabyte
        ]
        if currentLimit > 0, !options.contains(currentLimit) {
            options.append(currentLimit)
            options.sort()
        }
        return options
    }

    private func torrentLimitLabel(_ limit: Int64, globalFallback: Int64?) -> String {
        if limit == 0 {
            let fallback = globalFallback ?? 0
            return fallback == 0 ? "Use Global (Unlimited)" : "Use Global (\(ByteFormatter.formatSpeed(bytesPerSecond: fallback)))"
        }
        return ByteFormatter.formatSpeed(bytesPerSecond: limit)
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

private struct DetailTagChip: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "number")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.12))
            .foregroundStyle(.cyan)
            .clipShape(Capsule())
    }
}

private struct TorrentTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: TorrentDetailViewModel

    var body: some View {
        NavigationStack {
            List {
                if viewModel.availableTags.isEmpty {
                    ContentUnavailableView(
                        "No Tags",
                        systemImage: "number",
                        description: Text("Create tags in More before assigning them to this torrent.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section("Assigned Tags") {
                        ForEach(viewModel.availableTags, id: \.self) { tag in
                            Button {
                                Task { await viewModel.toggleTag(tag) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected(tag) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected(tag) ? .cyan : .secondary)
                                    Text(tag)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isSelected(_ tag: String) -> Bool {
        viewModel.currentTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}
