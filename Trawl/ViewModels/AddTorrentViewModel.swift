import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AddTorrentViewModel {
    // Input
    var magnetLink: String = ""
    var torrentFileData: Data?
    var torrentFileName: String?

    // Options
    var savePath: String = ""
    var selectedCategory: String = ""
    var startPaused: Bool = false
    var sequentialDownload: Bool = false
    var firstLastPiecePriority: Bool = false

    // State
    var isSubmitting: Bool = false
    var error: String?
    var submissionErrorAlert: ErrorAlertItem?
    var availableCategories: [String] = []
    var recentSavePaths: [RecentSavePath] = []
    var serverDefaultSavePath: String?

    private let torrentService: TorrentService
    private let syncService: SyncService

    init(torrentService: TorrentService, syncService: SyncService) {
        self.torrentService = torrentService
        self.syncService = syncService
    }

    var inputMode: AddTorrentInputMode {
        if torrentFileData != nil { return .file }
        return .magnet
    }

    var canSubmit: Bool {
        if isSubmitting { return false }
        switch inputMode {
        case .magnet:
            return !magnetLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            return torrentFileData != nil
        }
    }

    /// Load categories from sync state and recent paths from SwiftData.
    func loadDefaults(modelContext: ModelContext) async {
        availableCategories = syncService.sortedCategoryNames
        serverDefaultSavePath = syncService.defaultSavePath

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

    /// Submit the torrent. Returns true on success.
    func submit(modelContext: ModelContext) async -> Bool {
        isSubmitting = true
        error = nil
        submissionErrorAlert = nil

        do {
            let path = savePath.isEmpty ? nil : savePath
            let category = selectedCategory.isEmpty ? nil : selectedCategory

            switch inputMode {
            case .magnet:
                try await torrentService.addTorrentURL(
                    url: magnetLink,
                    savePath: path,
                    category: category,
                    paused: startPaused,
                    sequentialDownload: sequentialDownload,
                    firstLastPiecePriority: firstLastPiecePriority
                )
            case .file:
                guard let fileData = torrentFileData, let fileName = torrentFileName else {
                    error = "No torrent file selected."
                    submissionErrorAlert = ErrorAlertItem(
                        title: "Couldn't Add Torrent",
                        message: "No torrent file selected."
                    )
                    isSubmitting = false
                    return false
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
            }

            // Persist save path for future use
            if let path, !path.isEmpty {
                await persistSavePath(path, modelContext: modelContext)
            }

            // Force a sync so the new torrent is in the list immediately rather
            // than waiting up to one polling interval.
            await syncService.refreshNow()

            isSubmitting = false
            return true
        } catch {
            self.error = error.localizedDescription
            submissionErrorAlert = ErrorAlertItem(
                title: "Couldn't Add Torrent",
                message: error.localizedDescription
            )
            isSubmitting = false
            return false
        }
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
                title: "Torrent Added",
                message: "The torrent was added, but the recent save path couldn't be stored. \(error.localizedDescription)"
            )
        }
    }
}

enum AddTorrentInputMode {
    case magnet, file
}

#if DEBUG
extension AddTorrentViewModel {
    convenience init(
        previewMagnetLink: String = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Ubuntu%2024.04%20LTS",
        previewTorrentFileName: String? = nil,
        previewTorrentFileData: Data? = nil,
        savePath: String = "/downloads/incoming",
        selectedCategory: String = "linux-isos",
        startPaused: Bool = false,
        sequentialDownload: Bool = false,
        firstLastPiecePriority: Bool = false,
        isSubmitting: Bool = false,
        error: String? = nil,
        submissionErrorAlert: ErrorAlertItem? = nil,
        availableCategories: [String] = ["linux-isos", "movies", "tv"],
        recentSavePaths: [RecentSavePath] = [],
        serverDefaultSavePath: String? = "/downloads",
        torrentService: TorrentService = .preview(),
        syncService: SyncService = .preview()
    ) {
        self.init(torrentService: torrentService, syncService: syncService)
        self.magnetLink = previewMagnetLink
        self.torrentFileName = previewTorrentFileName
        self.torrentFileData = previewTorrentFileData
        self.savePath = savePath
        self.selectedCategory = selectedCategory
        self.startPaused = startPaused
        self.sequentialDownload = sequentialDownload
        self.firstLastPiecePriority = firstLastPiecePriority
        self.isSubmitting = isSubmitting
        self.error = error
        self.submissionErrorAlert = submissionErrorAlert
        self.availableCategories = availableCategories
        self.recentSavePaths = recentSavePaths
        self.serverDefaultSavePath = serverDefaultSavePath
    }
}
#endif
