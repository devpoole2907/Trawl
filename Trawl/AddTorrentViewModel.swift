import Foundation
import Observation
import SwiftData

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

    // State
    var isSubmitting: Bool = false
    var error: String?
    var availableCategories: [String] = []
    var recentSavePaths: [RecentSavePath] = []

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

        // Load recent save paths, sorted by most recently used
        let descriptor = FetchDescriptor<RecentSavePath>(sortBy: [SortDescriptor(\.lastUsed, order: .reverse)])
        recentSavePaths = (try? modelContext.fetch(descriptor)) ?? []

        // Pre-fill save path from the most recent path or server default
        if savePath.isEmpty {
            if let recent = recentSavePaths.first {
                savePath = recent.path
            }
        }
    }

    /// Submit the torrent. Returns true on success.
    func submit(modelContext: ModelContext) async -> Bool {
        isSubmitting = true
        error = nil

        do {
            let path = savePath.isEmpty ? nil : savePath
            let category = selectedCategory.isEmpty ? nil : selectedCategory

            switch inputMode {
            case .magnet:
                try await torrentService.addTorrentMagnet(
                    magnetURL: magnetLink,
                    savePath: path,
                    category: category,
                    paused: startPaused,
                    sequentialDownload: sequentialDownload
                )
            case .file:
                guard let fileData = torrentFileData, let fileName = torrentFileName else {
                    error = "No torrent file selected."
                    isSubmitting = false
                    return false
                }
                try await torrentService.addTorrentFile(
                    fileData: fileData,
                    fileName: fileName,
                    savePath: path,
                    category: category,
                    paused: startPaused,
                    sequentialDownload: sequentialDownload
                )
            }

            // Persist save path for future use
            if let path, !path.isEmpty {
                await persistSavePath(path, modelContext: modelContext)
            }

            isSubmitting = false
            return true
        } catch {
            self.error = error.localizedDescription
            isSubmitting = false
            return false
        }
    }

    private func persistSavePath(_ path: String, modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<RecentSavePath>(predicate: #Predicate { $0.path == path })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastUsed = .now
            existing.useCount += 1
        } else {
            modelContext.insert(RecentSavePath(path: path))
        }
        try? modelContext.save()
    }
}

enum AddTorrentInputMode {
    case magnet, file
}
