import SwiftUI

// MARK: - Helpers

func arrDetailLinkedTorrent(for downloadId: String?, in torrents: [String: Torrent]) -> Torrent? {
    guard let downloadId, !downloadId.isEmpty else { return nil }
    let normalized = downloadId.lowercased()
    if let direct = torrents[downloadId] { return direct }
    if let normalizedMatch = torrents[normalized] { return normalizedMatch }
    return torrents.first { $0.key.caseInsensitiveCompare(downloadId) == .orderedSame }?.value
}

func arrDetailFormattedETA(for torrent: Torrent) -> String? {
    guard torrent.eta > 0, torrent.eta < 8_640_000 else { return nil }
    let hours = torrent.eta / 3600
    let minutes = (torrent.eta % 3600) / 60
    let seconds = torrent.eta % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

func arrDetailIsActiveQueueItem(_ item: ArrQueueItem, linkedTorrent: Torrent?) -> Bool {
    if let torrent = linkedTorrent {
        return torrent.state.filterCategory == .downloading
    }
    return item.isDownloadingQueueItem
}

@ViewBuilder
private func arrDetailIssueActionIcon(systemName: String, tint: Color) -> some View {
    Image(systemName: systemName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(8)
        .glassEffect(.regular.interactive(), in: Circle())
}

// MARK: - Queue card

struct ArrDetailQueueCard<Row: View>: View {
    let items: [ArrQueueItem]
    private let rowContent: (ArrQueueItem) -> Row
    @State private var isExpanded = false

    init(items: [ArrQueueItem], @ViewBuilder rowContent: @escaping (ArrQueueItem) -> Row) {
        self.items = items
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Label(
                            items.count == 1 ? "Current Download" : "Current Downloads",
                            systemImage: "arrow.down.circle"
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        Text("\(items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isExpanded ? 8 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    rowContent(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Import issues card

struct ArrDetailImportIssuesCard<Row: View>: View {
    let items: [ArrQueueItem]
    private let rowContent: (ArrQueueItem) -> Row
    @State private var isExpanded = false

    init(items: [ArrQueueItem], @ViewBuilder rowContent: @escaping (ArrQueueItem) -> Row) {
        self.items = items
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Label(
                            items.count == 1 ? "Import Issue" : "Import Issues",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        Text("\(items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isExpanded ? 8 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    rowContent(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Queue item row

struct ArrDetailQueueItemRow: View {
    @Environment(SyncService.self) private var syncService
    let item: ArrQueueItem

    private var linkedTorrent: Torrent? {
        arrDetailLinkedTorrent(for: item.downloadId, in: syncService.torrents)
    }

    var body: some View {
        let torrent = linkedTorrent
        let progress = torrent?.progress ?? item.progress
        let percent = Int(progress * 100)
        let downloadedBytes = torrent.map { max(0, $0.totalSize - $0.amountLeft) } ?? item.size.map { total in
            Int64(max(0, total - (item.sizeleft ?? total)))
        }
        let totalBytes = torrent.map(\.totalSize).flatMap { $0 > 0 ? $0 : nil } ?? item.size.map { Int64($0) }
        let primaryStatus = torrent?.state.displayName ?? item.trackedDownloadState ?? item.status ?? "queued"
        let title = torrent?.name ?? item.title ?? "Download"
        let etaText = torrent.flatMap(arrDetailFormattedETA(for:)) ?? item.timeleft

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    Text(primaryStatus.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let downloadClient = item.downloadClient, !downloadClient.isEmpty {
                    Text(downloadClient)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
            }

            ProgressView(value: progress)
                .tint(torrent == nil ? .orange : .blue)

            HStack(spacing: 12) {
                Text("\(percent)%")
                if let downloadedBytes, let totalBytes {
                    Text("·")
                    Text("\(ByteFormatter.format(bytes: downloadedBytes)) / \(ByteFormatter.format(bytes: totalBytes))")
                }
                if let etaText, !etaText.isEmpty {
                    Text("·")
                    Text("ETA \(etaText)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let t = torrent {
                NavigationLink {
                    TorrentDetailView(torrentHash: t.hash)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("View Live Torrent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(t.state.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if t.dlspeed > 0 {
                            Label(ByteFormatter.formatSpeed(bytesPerSecond: t.dlspeed), systemImage: "arrow.down")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else if let outputPath = item.outputPath, !outputPath.isEmpty {
                LabeledContent("Destination") {
                    Text(outputPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            }

            if let messages = item.statusMessages?.compactMap(\.messages).flatMap({ $0 }),
               let message = messages.first,
               !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }
}

// MARK: - Queue issue row

struct ArrDetailQueueIssueRow: View {
    @Environment(SyncService.self) private var syncService

    let item: ArrQueueItem
    let rootFolderPath: String?
    let service: ArrServiceType
    let libraryItemID: Int?
    /// "Series" or "Movie" — used in accessibility labels and hint text.
    let editNoun: String
    let isRemoving: Bool
    let isInLibrary: Bool
    let onEdit: () -> Void
    let onSetResolution: (ArrQueueImportIssueResolution) -> Void
    let onSetPendingAction: (ArrDetailPendingQueueAction) -> Void

    private var linkedTorrent: Torrent? {
        arrDetailLinkedTorrent(for: item.downloadId, in: syncService.torrents)
    }

    var body: some View {
        let torrent = linkedTorrent
        let primaryStatus = torrent?.state.displayName ?? item.trackedDownloadState ?? item.status ?? "Issue"
        let message = item.primaryStatusMessage ?? "This item is blocked before import completes."

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(torrent?.name ?? item.title ?? "Queue Item")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    Text(primaryStatus.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text(item.trackedDownloadStatus?.capitalized ?? "Issue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.16))
                    .clipShape(Capsule())
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            if let rootFolder = rootFolderPath, !rootFolder.isEmpty {
                LabeledContent("Library Root") {
                    Text(rootFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let outputPath = item.outputPath, !outputPath.isEmpty {
                LabeledContent("Import Destination") {
                    Text(outputPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { onEdit() } label: {
                    arrDetailIssueActionIcon(systemName: "slider.horizontal.3", tint: .blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(editNoun)")
                .disabled(isRemoving || !isInLibrary)

                if let outputPath = item.outputPath, !outputPath.isEmpty {
                    Button {
                        onSetResolution(ArrQueueImportIssueResolution(
                            id: item.id,
                            path: outputPath,
                            service: service,
                            libraryItemID: libraryItemID,
                            title: torrent?.name ?? item.title ?? "Queue Item",
                            status: primaryStatus.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized,
                            message: message,
                            rootFolder: rootFolderPath
                        ))
                    } label: {
                        arrDetailIssueActionIcon(systemName: "tray.and.arrow.down.fill", tint: .teal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Resolve Import Issue")
                    .disabled(isRemoving)
                }

                Button {
                    onSetPendingAction(ArrDetailPendingQueueAction(
                        itemID: item.id,
                        title: torrent?.name ?? item.title ?? "Queue Item",
                        blocklist: false
                    ))
                } label: {
                    arrDetailIssueActionIcon(systemName: "trash", tint: .red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove from Queue")
                .disabled(isRemoving)

                Button {
                    onSetPendingAction(ArrDetailPendingQueueAction(
                        itemID: item.id,
                        title: torrent?.name ?? item.title ?? "Queue Item",
                        blocklist: true
                    ))
                } label: {
                    arrDetailIssueActionIcon(systemName: "hand.raised.fill", tint: .orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Blocklist")
                .disabled(isRemoving)
            }

            Text("Use Edit \(editNoun) to change the root folder or other import-related settings before retrying.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let t = torrent {
                NavigationLink {
                    TorrentDetailView(torrentHash: t.hash)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("View Torrent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(t.state.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
