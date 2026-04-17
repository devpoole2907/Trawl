import Foundation
import Observation

@Observable
final class TorrentService {
    private let apiClient: QBittorrentAPIClient

    init(apiClient: QBittorrentAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - App

    func getAppVersion() async throws -> String {
        try await apiClient.getAppVersion()
    }

    func getPreferences() async throws -> AppPreferences {
        try await apiClient.getPreferences()
    }

    // MARK: - Torrents

    func getTorrents(filter: String? = nil, category: String? = nil, sort: String? = nil) async throws -> [Torrent] {
        try await apiClient.getTorrents(filter: filter, category: category, sort: sort)
    }

    func addTorrentMagnet(magnetURL: String, savePath: String?, category: String?, paused: Bool = false, sequentialDownload: Bool = false) async throws {
        let trimmed = magnetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:") else {
            throw QBError.serverError(statusCode: 0, message: "Invalid magnet link format")
        }
        try await apiClient.addTorrentMagnet(magnetURL: trimmed, savePath: savePath, category: category, paused: paused, sequentialDownload: sequentialDownload)
    }

    func addTorrentFile(fileData: Data, fileName: String, savePath: String?, category: String?, paused: Bool = false, sequentialDownload: Bool = false) async throws {
        guard !fileData.isEmpty else {
            throw QBError.serverError(statusCode: 0, message: "Torrent file data is empty")
        }
        try await apiClient.addTorrentFile(fileData: fileData, fileName: fileName, savePath: savePath, category: category, paused: paused, sequentialDownload: sequentialDownload)
    }

    func deleteTorrents(hashes: [String], deleteFiles: Bool) async throws {
        guard !hashes.isEmpty else { return }
        try await apiClient.deleteTorrents(hashes: hashes, deleteFiles: deleteFiles)
    }

    func pauseTorrents(hashes: [String]) async throws {
        guard !hashes.isEmpty else { return }
        try await apiClient.pauseTorrents(hashes: hashes)
    }

    func resumeTorrents(hashes: [String]) async throws {
        guard !hashes.isEmpty else { return }
        try await apiClient.resumeTorrents(hashes: hashes)
    }

    func recheckTorrents(hashes: [String]) async throws {
        guard !hashes.isEmpty else { return }
        try await apiClient.recheckTorrents(hashes: hashes)
    }

    func getTorrentFiles(hash: String) async throws -> [TorrentFile] {
        try await apiClient.getTorrentFiles(hash: hash)
    }

    func setFilePriority(hash: String, fileIndices: [Int], priority: FilePriority) async throws {
        try await apiClient.setFilePriority(hash: hash, fileIndices: fileIndices, priority: priority)
    }

    func getTorrentProperties(hash: String) async throws -> TorrentProperties {
        try await apiClient.getTorrentProperties(hash: hash)
    }

    func setTorrentLocation(hashes: [String], location: String) async throws {
        try await apiClient.setTorrentLocation(hashes: hashes, location: location)
    }

    func setTorrentCategory(hashes: [String], category: String) async throws {
        try await apiClient.setTorrentCategory(hashes: hashes, category: category)
    }

    func renameTorrent(hash: String, name: String) async throws {
        try await apiClient.renameTorrent(hash: hash, name: name)
    }

    func getCategories() async throws -> [String: SyncCategory] {
        try await apiClient.getCategories()
    }

    func createCategory(name: String, savePath: String?) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedSavePath = savePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await apiClient.createCategory(name: trimmedName, savePath: trimmedSavePath)
    }

    func removeCategories(names: [String]) async throws {
        try await apiClient.removeCategories(names: names)
    }

    func getTrackers(hash: String) async throws -> [TorrentTracker] {
        try await apiClient.getTrackers(hash: hash)
    }

    // MARK: - Transfer

    func getTransferInfo() async throws -> TransferInfo {
        try await apiClient.getTransferInfo()
    }
}
