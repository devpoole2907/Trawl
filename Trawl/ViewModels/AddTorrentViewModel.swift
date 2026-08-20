import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AddTorrentViewModel {
    // Input
    var source: AddDownloadSource = .magnet
    var magnetLink: String = ""
    var linkURL: String = ""
    var torrentFileData: Data?
    var torrentFileName: String?
    var nzbFileData: Data?
    var nzbFileName: String?

    /// Destination used when a pasted URL is neither obviously a torrent nor an NZB
    /// and both clients are set up, so the app can't route it on its own.
    var preferredURLDestination: AddDownloadDestination = .qBittorrent

    // qBittorrent options
    var savePath: String = ""
    var selectedCategory: String = ""
    var startPaused: Bool = false
    var sequentialDownload: Bool = false
    var firstLastPiecePriority: Bool = false

    // SABnzbd options
    var sabCategory: String = ""
    /// SABnzbd post-processing script. Empty means "server default".
    var sabScript: String = ""
    var sabPriority: AddDownloadPriority = .default
    var sabPostProcessing: AddDownloadPostProcessing = .default
    var sabPassword: String = ""

    /// Which clients the user has configured. Pushed in by the sheet, which owns
    /// the SwiftData queries for the two profile types.
    var hasQBittorrent: Bool = false
    var hasSABnzbd: Bool = false

    // State
    var isSubmitting: Bool = false
    var error: String?
    var submissionErrorAlert: ErrorAlertItem?
    var availableCategories: [String] = []
    var sabCategories: [String] = []
    var sabScripts: [String] = []
    var recentSavePaths: [RecentSavePath] = []
    var serverDefaultSavePath: String?

    private let torrentService: TorrentService
    private let syncService: SyncService
    private let sabnzbdManager: SABnzbdServiceManager?

    init(
        torrentService: TorrentService,
        syncService: SyncService,
        sabnzbdManager: SABnzbdServiceManager? = nil
    ) {
        self.torrentService = torrentService
        self.syncService = syncService
        self.sabnzbdManager = sabnzbdManager
    }

    // MARK: - Sources and routing

    /// Sources the user can actually pick, given the configured clients.
    var availableSources: [AddDownloadSource] {
        var sources: [AddDownloadSource] = []
        if hasQBittorrent { sources.append(contentsOf: [.magnet, .torrentFile]) }
        if hasSABnzbd { sources.append(.nzbFile) }
        if hasQBittorrent || hasSABnzbd { sources.append(.url) }
        return sources
    }

    var hasAnyClient: Bool { hasQBittorrent || hasSABnzbd }

    /// What the text in the URL field looks like, which is how a URL add is routed.
    var linkKind: AddDownloadLinkKind { Self.linkKind(for: linkURL) }

    /// True when a pasted URL gives no hint and both clients could take it, so the
    /// user has to say where it goes rather than the app guessing.
    var needsURLDestinationChoice: Bool {
        source == .url && linkKind == .unknown && hasQBittorrent && hasSABnzbd
    }

    /// The client this add will go to, or `nil` when the required client isn't set up.
    var destination: AddDownloadDestination? {
        switch source {
        case .magnet, .torrentFile:
            return hasQBittorrent ? .qBittorrent : nil
        case .nzbFile:
            return hasSABnzbd ? .sabnzbd : nil
        case .url:
            switch linkKind {
            case .magnet, .torrent:
                return hasQBittorrent ? .qBittorrent : nil
            case .nzb:
                return hasSABnzbd ? .sabnzbd : nil
            case .unknown:
                if hasQBittorrent && hasSABnzbd { return preferredURLDestination }
                if hasQBittorrent { return .qBittorrent }
                return hasSABnzbd ? .sabnzbd : nil
            }
        }
    }

    /// Set when the link is clearly for a client the user hasn't configured.
    var routingWarning: String? {
        guard source == .url, destination == nil, !trimmedLinkURL.isEmpty else { return nil }
        switch linkKind {
        case .magnet, .torrent:
            return "This looks like a torrent link, but qBittorrent isn't set up."
        case .nzb:
            return "This looks like an NZB link, but SABnzbd isn't set up."
        case .unknown:
            return "No download client is set up."
        }
    }

    var canSubmit: Bool {
        if isSubmitting { return false }
        guard destination != nil else { return false }
        switch source {
        case .magnet:
            return !magnetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .torrentFile:
            return torrentFileData != nil
        case .nzbFile:
            return nzbFileData != nil
        case .url:
            return !trimmedLinkURL.isEmpty
        }
    }

    /// Drop input belonging to the sources we just moved away from, so a stale
    /// file or link can never be submitted to the wrong client.
    func clearInputOtherThanCurrentSource() {
        if source != .magnet { magnetLink = "" }
        if source != .url { linkURL = "" }
        if source != .torrentFile {
            torrentFileData = nil
            torrentFileName = nil
        }
        if source != .nzbFile {
            nzbFileData = nil
            nzbFileName = nil
        }
    }

    // MARK: - Defaults

    /// Load categories from sync state and recent paths from SwiftData.
    func loadDefaults(modelContext: ModelContext) async {
        availableCategories = syncService.sortedCategoryNames
        serverDefaultSavePath = syncService.defaultSavePath
        await loadSABnzbdOptions()

        // Load recent save paths, sorted by most recently used
        let descriptor = FetchDescriptor<RecentSavePath>(sortBy: [SortDescriptor(\.lastUsed, order: .reverse)])
        do {
            recentSavePaths = try modelContext.fetch(descriptor)
        } catch {
            recentSavePaths = []
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Load Recent Paths",
                message: error.localizedDescription
            )
        }

        // Pre-fill save path from the most recent path
        if savePath.isEmpty, let recent = recentSavePaths.first {
            savePath = recent.path
        }
    }

    /// Move the selection onto a source the user can actually use — a SABnzbd-only
    /// setup has no magnet source to land on.
    func normalizeSourceForAvailableClients() {
        let sources = availableSources
        guard !sources.isEmpty, !sources.contains(source) else { return }
        source = sources[0]
        clearInputOtherThanCurrentSource()
    }

    // MARK: - Submission

    /// Submit the download to whichever client the current source routes to.
    /// Returns true on success.
    func submit(modelContext: ModelContext) async -> Bool {
        isSubmitting = true
        error = nil
        submissionErrorAlert = nil

        guard let destination else {
            return reportFailure("No download client is set up for this kind of link.")
        }

        do {
            switch destination {
            case .qBittorrent:
                try await submitToQBittorrent(modelContext: modelContext)
            case .sabnzbd:
                try await submitToSABnzbd()
            }

            isSubmitting = false
            return true
        } catch {
            return reportFailure(error.localizedDescription)
        }
    }

    private func submitToQBittorrent(modelContext: ModelContext) async throws {
        let path = savePath.isEmpty ? nil : savePath
        let category = selectedCategory.isEmpty ? nil : selectedCategory

        switch source {
        case .magnet, .url:
            let link = source == .magnet ? magnetLink : linkURL
            try await torrentService.addTorrentURL(
                url: link,
                savePath: path,
                category: category,
                paused: startPaused,
                sequentialDownload: sequentialDownload,
                firstLastPiecePriority: firstLastPiecePriority
            )
        case .torrentFile:
            guard let fileData = torrentFileData, let fileName = torrentFileName else {
                throw AddDownloadError.noFileSelected("No torrent file selected.")
            }
            try await torrentService.addTorrentFile(
                fileData: fileData,
                fileName: fileName,
                savePath: path,
                category: category,
                paused: startPaused,
                sequentialDownload: sequentialDownload,
                firstLastPiecePriority: firstLastPiecePriority
            )
        case .nzbFile:
            throw AddDownloadError.clientUnavailable("An NZB can't be sent to qBittorrent.")
        }

        // Persist save path for future use
        if let path, !path.isEmpty {
            await persistSavePath(path, modelContext: modelContext)
        }

        // Force a sync so the new torrent is in the list immediately rather
        // than waiting up to one polling interval.
        await syncService.refreshNow()
    }

    private func submitToSABnzbd() async throws {
        guard let sabnzbdManager else {
            throw AddDownloadError.clientUnavailable("SABnzbd isn't set up on this device.")
        }

        let options = SABnzbdAddOptions(
            password: sabPassword.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
            category: sabCategory.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
            script: sabScript.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
            priority: sabPriority.apiValue,
            postProcessing: sabPostProcessing.apiValue
        )

        switch source {
        case .nzbFile:
            guard let fileData = nzbFileData, let fileName = nzbFileName else {
                throw AddDownloadError.noFileSelected("No NZB file selected.")
            }
            try await sabnzbdManager.addNZB(data: fileData, filename: fileName, options: options)
        case .url:
            guard let url = URL(string: trimmedLinkURL), url.scheme != nil else {
                throw AddDownloadError.invalidURL
            }
            try await sabnzbdManager.addURL(url, options: options)
        case .magnet, .torrentFile:
            throw AddDownloadError.clientUnavailable("A torrent can't be sent to SABnzbd.")
        }
    }

    private func reportFailure(_ message: String) -> Bool {
        error = message
        submissionErrorAlert = ErrorAlertItem(
            title: "Couldn't Add Download",
            message: message
        )
        isSubmitting = false
        return false
    }

    private func persistSavePath(_ path: String, modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<RecentSavePath>(predicate: #Predicate { $0.path == path })
        do {
            if let existing = try modelContext.fetch(descriptor).first {
                existing.lastUsed = .now
                existing.useCount += 1
            } else {
                modelContext.insert(RecentSavePath(path: path))
            }
            try modelContext.save()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Download Added",
                message: "The download was added, but the recent save path couldn't be stored. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private var trimmedLinkURL: String {
        linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SABnzbd exposes no category listing endpoint, so offer the categories that
    /// already appear on the server's own jobs.
    /// Asks the server for its categories and scripts, falling back to whatever the
    /// queue and history happen to show if the call fails — a fresh install with an
    /// empty queue has nothing to infer from, which is exactly when this matters.
    private func loadSABnzbdOptions() async {
        guard let sabnzbdManager else {
            sabCategories = []
            sabScripts = []
            return
        }

        let (categories, scripts) = await sabnzbdManager.categoriesAndScripts()
        sabCategories = categories.isEmpty ? Self.knownCategories(from: sabnzbdManager) : categories
        sabScripts = scripts
    }

    private static func knownCategories(from manager: SABnzbdServiceManager?) -> [String] {
        guard let manager else { return [] }
        let categories = (manager.activeJobs + manager.historyJobs)
            .compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "*" }
        return Array(Set(categories)).sorted()
    }

    static func linkKind(for raw: String) -> AddDownloadLinkKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        if trimmed.lowercased().hasPrefix("magnet:") { return .magnet }
        guard let url = URL(string: trimmed) else { return .unknown }

        switch url.pathExtension.lowercased() {
        case "torrent":
            return .torrent
        case "nzb":
            return .nzb
        default:
            // Indexers commonly hand out `something.nzb.gz`.
            if url.deletingPathExtension().pathExtension.lowercased() == "nzb" { return .nzb }
            return .unknown
        }
    }
}

// MARK: - Source, destination and option models

/// Where the download comes from. The first three imply a client; `.url` is routed
/// by inspecting the link (and, when that's inconclusive, by asking the user).
enum AddDownloadSource: Hashable, Identifiable {
    case magnet
    case torrentFile
    case nzbFile
    case url

    var id: Self { self }

    /// Segment-bar item for the source selector at the top of the Add Download sheet.
    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(pickerTitle, value: self)
    }

    /// Short label for the source selector.
    var pickerTitle: String {
        switch self {
        case .magnet: "Magnet"
        case .torrentFile: "Torrent"
        case .nzbFile: "NZB"
        case .url: "URL"
        }
    }

    /// Confirm-button title: client-neutral, but specific about what's being added.
    var confirmTitle: String {
        switch self {
        case .magnet: "Add Magnet"
        case .torrentFile: "Add Torrent"
        case .nzbFile: "Add NZB"
        case .url: "Add Link"
        }
    }

    var footerText: String {
        switch self {
        case .magnet: "Paste a magnet link from Safari or another app."
        case .torrentFile: "Choose a .torrent file to upload to qBittorrent."
        case .nzbFile: "Choose a .nzb file to upload to SABnzbd."
        case .url: "Paste any download link. Torrent links go to qBittorrent, NZB links go to SABnzbd."
        }
    }
}

enum AddDownloadDestination: Hashable, Identifiable {
    case qBittorrent
    case sabnzbd

    var id: Self { self }

    var displayName: String {
        switch self {
        case .qBittorrent: "qBittorrent"
        case .sabnzbd: "SABnzbd"
        }
    }
}

/// What a pasted link appears to be, used to route a `.url` add.
enum AddDownloadLinkKind: Hashable {
    case magnet
    case torrent
    case nzb
    case unknown
}

/// SABnzbd queue priority. `default` omits the parameter so the server's own
/// category/default priority applies.
enum AddDownloadPriority: Int, CaseIterable, Identifiable {
    case `default`
    case paused
    case low
    case normal
    case high
    case force

    var id: Self { self }

    var displayName: String {
        switch self {
        case .default: "Server Default"
        case .paused: "Paused"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .force: "Force"
        }
    }

    var apiValue: Int? {
        switch self {
        case .default: nil
        case .paused: -2
        case .low: -1
        case .normal: 0
        case .high: 1
        case .force: 2
        }
    }
}

/// SABnzbd post-processing (`pp`) level.
enum AddDownloadPostProcessing: Int, CaseIterable, Identifiable {
    case `default`
    case downloadOnly
    case repair
    case repairUnpack
    case repairUnpackDelete

    var id: Self { self }

    var displayName: String {
        switch self {
        case .default: "Server Default"
        case .downloadOnly: "Download Only"
        case .repair: "Repair"
        case .repairUnpack: "Repair & Unpack"
        case .repairUnpackDelete: "Repair, Unpack & Delete"
        }
    }

    var apiValue: Int? {
        switch self {
        case .default: nil
        case .downloadOnly: 0
        case .repair: 1
        case .repairUnpack: 2
        case .repairUnpackDelete: 3
        }
    }
}

private enum AddDownloadError: LocalizedError {
    case noFileSelected(String)
    case clientUnavailable(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .noFileSelected(let message): message
        case .clientUnavailable(let message): message
        case .invalidURL: "That doesn't look like a valid URL."
        }
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
extension AddTorrentViewModel {
    convenience init(
        previewSource: AddDownloadSource = .magnet,
        previewMagnetLink: String = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Ubuntu%2024.04%20LTS",
        previewLinkURL: String = "",
        previewTorrentFileName: String? = nil,
        previewTorrentFileData: Data? = nil,
        previewNZBFileName: String? = nil,
        previewNZBFileData: Data? = nil,
        hasQBittorrent: Bool = true,
        hasSABnzbd: Bool = false,
        savePath: String = "/downloads/incoming",
        selectedCategory: String = "linux-isos",
        startPaused: Bool = false,
        sequentialDownload: Bool = false,
        firstLastPiecePriority: Bool = false,
        sabCategory: String = "",
        isSubmitting: Bool = false,
        error: String? = nil,
        submissionErrorAlert: ErrorAlertItem? = nil,
        availableCategories: [String] = ["linux-isos", "movies", "tv"],
        sabCategories: [String] = ["movies", "tv"],
        recentSavePaths: [RecentSavePath] = [],
        serverDefaultSavePath: String? = "/downloads",
        torrentService: TorrentService = .preview(),
        syncService: SyncService = .preview(),
        sabnzbdManager: SABnzbdServiceManager? = nil
    ) {
        self.init(torrentService: torrentService, syncService: syncService, sabnzbdManager: sabnzbdManager)
        self.source = previewSource
        self.magnetLink = previewMagnetLink
        self.linkURL = previewLinkURL
        self.torrentFileName = previewTorrentFileName
        self.torrentFileData = previewTorrentFileData
        self.nzbFileName = previewNZBFileName
        self.nzbFileData = previewNZBFileData
        self.hasQBittorrent = hasQBittorrent
        self.hasSABnzbd = hasSABnzbd
        self.savePath = savePath
        self.selectedCategory = selectedCategory
        self.startPaused = startPaused
        self.sequentialDownload = sequentialDownload
        self.firstLastPiecePriority = firstLastPiecePriority
        self.sabCategory = sabCategory
        self.isSubmitting = isSubmitting
        self.error = error
        self.submissionErrorAlert = submissionErrorAlert
        self.availableCategories = availableCategories
        self.sabCategories = sabCategories
        self.recentSavePaths = recentSavePaths
        self.serverDefaultSavePath = serverDefaultSavePath
    }
}
#endif
