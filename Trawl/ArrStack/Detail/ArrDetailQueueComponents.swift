import SwiftUI

// MARK: - Helpers

func arrDetailLinkedTorrent(for downloadId: String?, in torrents: [String: Torrent]) -> Torrent? {
    guard let downloadId, !downloadId.isEmpty else { return nil }
    let normalized = downloadId.lowercased()
    if let direct = torrents[downloadId] { return direct }
    if let normalizedMatch = torrents[normalized] { return normalizedMatch }
    return torrents.first { $0.key.caseInsensitiveCompare(downloadId) == .orderedSame }?.value
}

/// Usenet counterpart to `arrDetailLinkedTorrent`. Arr stores SABnzbd's `nzo_id`
/// in `downloadId`, but the two servers disagree on casing, so match the way
/// `DownloadsViewModel` does.
func arrDetailLinkedSABJob(for downloadId: String?, in jobs: [SABnzbdJob]) -> SABnzbdJob? {
    guard let downloadId = downloadId?.trimmingCharacters(in: .whitespacesAndNewlines),
          !downloadId.isEmpty else { return nil }
    return jobs.first { $0.id.caseInsensitiveCompare(downloadId) == .orderedSame }
}

/// Queue jobs, post-processing history entries, and terminal history entries — a
/// grab can be sitting in any of the three while Arr still lists it in the queue.
func arrDetailSABJobs(from serviceManager: SABnzbdServiceManager?) -> [SABnzbdJob] {
    guard let serviceManager else { return [] }
    return serviceManager.activeJobs + serviceManager.historyJobs
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

/// SABnzbd already hands us a preformatted `H:MM:SS` string; it just reports a
/// run of zeroes for anything that is not actively downloading.
func arrDetailFormattedETA(for job: SABnzbdJob) -> String? {
    guard let timeRemaining = job.timeRemaining?.trimmingCharacters(in: .whitespacesAndNewlines),
          !timeRemaining.isEmpty else { return nil }
    let isZero = timeRemaining.split(separator: ":").allSatisfy { Int($0) == 0 }
    return isZero ? nil : timeRemaining
}

func arrDetailIsActiveQueueItem(
    _ item: ArrQueueItem,
    linkedTorrent: Torrent?,
    linkedSABJob: SABnzbdJob? = nil
) -> Bool {
    if let torrent = linkedTorrent {
        return torrent.state.filterCategory == .downloading
    }
    if let job = linkedSABJob {
        // `isActive` also covers queued/paused/post-processing so a Usenet grab
        // never falls out of both the download and the import-issue card.
        return job.normalizedStatus.isActive
    }
    return item.isDownloadingQueueItem
}

/// Matches the chip styling `ArrInfoRowView` uses for release metadata.
@ViewBuilder
private func arrDetailInfoChip(_ label: String, color: Color, isProminent: Bool = false) -> some View {
    Text(label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(isProminent ? 0.22 : 0.1))
        .clipShape(Capsule())
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
    /// Optional: movie/series detail is also reachable from search and the Bazarr
    /// browser, which do not inject the SABnzbd manager.
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    let item: ArrQueueItem
    var isRemoving = false
    var onSetPendingAction: ((ArrDetailPendingQueueAction) -> Void)?

    private var linkedTorrent: Torrent? {
        arrDetailLinkedTorrent(for: item.downloadId, in: syncService.torrents)
    }

    private var linkedSABJob: SABnzbdJob? {
        arrDetailLinkedSABJob(for: item.downloadId, in: arrDetailSABJobs(from: sabnzbdServiceManager))
    }

    var body: some View {
        let torrent = linkedTorrent
        let sabJob = torrent == nil ? linkedSABJob : nil
        let progress = torrent?.progress ?? sabJob?.progress ?? item.progress
        let percent = Int(progress * 100)
        let primaryStatus = torrent?.state.displayName
            ?? sabJob?.normalizedStatus.displayName
            ?? item.trackedDownloadState
            ?? item.status
            ?? "queued"
        let title = torrent?.name ?? sabJob?.name ?? item.title ?? "Download"
        let etaText = torrent.flatMap(arrDetailFormattedETA(for:))
            ?? sabJob.flatMap(arrDetailFormattedETA(for:))
            ?? item.timeleft

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
                VStack(alignment: .trailing, spacing: 6) {
                    if let downloadClient = item.downloadClient, !downloadClient.isEmpty {
                        Text(downloadClient)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: Capsule())
                    }
                    if let qualityName = item.qualityName {
                        arrDetailInfoChip(qualityName, color: .primary)
                    }
                }
            }

            ProgressView(value: progress)
                .tint(progressTint(torrent: torrent, sabJob: sabJob))

            HStack(spacing: 12) {
                Text("\(percent)%")
                if let sizeSummary = sizeSummary(torrent: torrent, sabJob: sabJob) {
                    Text("·")
                    Text(sizeSummary)
                }
                if let etaText, !etaText.isEmpty {
                    Text("·")
                    Text("ETA \(etaText)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let onSetPendingAction {
                HStack(spacing: 10) {
                    Button {
                        onSetPendingAction(ArrDetailPendingQueueAction(
                            itemID: item.id,
                            title: title,
                            blocklist: false
                        ))
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    if item.canBeBlocklisted {
                        Button {
                            onSetPendingAction(ArrDetailPendingQueueAction(
                                itemID: item.id,
                                title: title,
                                blocklist: true
                            ))
                        } label: {
                            Label("Blocklist", systemImage: "hand.raised.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                .font(.caption.weight(.semibold))
                .disabled(isRemoving)
            }

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
            } else if let job = sabJob {
                // SABnzbd has no per-job screen to push, so the live detail is
                // shown inline instead of behind a link.
                ArrDetailSABJobPanel(job: job)
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
               let message = messages.first(where: { !$0.isEmpty }),
               !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private func progressTint(torrent: Torrent?, sabJob: SABnzbdJob?) -> Color {
        if torrent != nil { return .blue }
        if let sabJob { return sabJob.normalizedStatus.color }
        return .orange
    }

    /// SABnzbd only reports preformatted size strings, so the Usenet variant
    /// reads "1.2 GB left of 4.0 GB" rather than a downloaded/total pair.
    private func sizeSummary(torrent: Torrent?, sabJob: SABnzbdJob?) -> String? {
        if let torrent, torrent.totalSize > 0 {
            let downloaded = max(0, torrent.totalSize - torrent.amountLeft)
            return "\(ByteFormatter.format(bytes: downloaded)) / \(ByteFormatter.format(bytes: torrent.totalSize))"
        }
        if let sabJob {
            guard let sizeRemaining = sabJob.sizeRemaining, !sizeRemaining.isEmpty else { return sabJob.size }
            return "\(sizeRemaining) left of \(sabJob.size)"
        }
        guard let total = item.size else { return nil }
        let downloaded = Int64(max(0, total - (item.sizeleft ?? total)))
        return "\(ByteFormatter.format(bytes: downloaded)) / \(ByteFormatter.format(bytes: Int64(total)))"
    }
}

// MARK: - SABnzbd job panel

/// Inline stand-in for `TorrentDetailView` on Usenet-backed queue items.
struct ArrDetailSABJobPanel: View {
    let job: SABnzbdJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: job.normalizedStatus.systemImage)
                    .foregroundStyle(job.normalizedStatus.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SABnzbd")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(job.normalizedStatus.displayName)
                        .font(.caption)
                        .foregroundStyle(job.normalizedStatus.color)
                }
                Spacer()
                if let timeRemaining = arrDetailFormattedETA(for: job) {
                    Label(timeRemaining, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                arrDetailInfoChip("\(Int(job.progress * 100))%", color: job.normalizedStatus.color, isProminent: true)
                arrDetailInfoChip(job.size, color: .secondary)
                if let category = job.category, !category.isEmpty {
                    arrDetailInfoChip(category, color: .primary)
                }
            }

            if let failureMessage = job.failureMessage, !failureMessage.isEmpty {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Queue issue row

struct ArrDetailQueueIssueRow: View {
    @Environment(SyncService.self) private var syncService
    /// Optional for the same reason as `ArrDetailQueueItemRow`.
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?

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

    private var linkedSABJob: SABnzbdJob? {
        arrDetailLinkedSABJob(for: item.downloadId, in: arrDetailSABJobs(from: sabnzbdServiceManager))
    }

    var body: some View {
        let torrent = linkedTorrent
        let sabJob = torrent == nil ? linkedSABJob : nil
        let primaryStatus = torrent?.state.displayName
            ?? sabJob?.normalizedStatus.displayName
            ?? item.trackedDownloadState
            ?? item.status
            ?? "Issue"
        let message = item.primaryStatusMessage
            ?? sabJob?.failureMessage
            ?? "This item is blocked before import completes."

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(torrent?.name ?? sabJob?.name ?? item.title ?? "Queue Item")
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

                if item.canBeBlocklisted {
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
            } else if let job = sabJob {
                ArrDetailSABJobPanel(job: job)
            }
        }
    }
}
