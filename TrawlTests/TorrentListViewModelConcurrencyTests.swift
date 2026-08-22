import Foundation
import Testing
@testable import Trawl

@Suite("Torrent list filtering concurrency", .serialized)
struct TorrentListViewModelConcurrencyTests {
    @Test("A canceled older search cannot replace a newer search result")
    @MainActor
    func newerSearchWinsWhenOlderComputeFinishesLast() async throws {
        let syncService = SyncService(apiClient: StaticTorrentSyncSource(data: try fixtureData()))
        await syncService.refreshNow()

        let gate = ControlledFilterGate()
        let completions = FilterWorkCompletions()
        let torrentService = TorrentService(
            apiClient: QBittorrentAPIClient(
                baseURL: "https://torrent-list.test",
                authService: AuthService(serverProfileID: UUID())
            )
        )
        let viewModel = TorrentListViewModel(
            syncService: syncService,
            torrentService: torrentService,
            beforeFilterCompute: { search in await gate.wait(for: search) },
            didFinishFilterWork: { search, applied in completions.record(search: search, applied: applied) }
        )
        defer { viewModel.stopSync() }

        viewModel.searchText = "Alpha"
        viewModel.startSync()
        await gate.waitUntilStarted("Alpha")

        viewModel.searchText = "Beta"
        await gate.waitUntilStarted("Beta")

        await gate.release("Beta")
        let betaApplied = await completions.wait(for: "Beta")
        #expect(betaApplied)
        #expect(viewModel.filteredTorrents.map(\.name) == ["Beta Release"])
        #expect(viewModel.filterCounts[.all] == 2)

        await gate.release("Alpha")
        let alphaApplied = await completions.wait(for: "Alpha")
        #expect(!alphaApplied)
        #expect(viewModel.filteredTorrents.map(\.name) == ["Beta Release"])
        #expect(viewModel.filterCounts[.all] == 2)
    }

    private func fixtureData() throws -> SyncMainData {
        let json = """
        {
          "rid": 1,
          "full_update": true,
          "torrents": {
            "alpha-hash": {
              "name": "Alpha Release",
              "progress": 0.5,
              "state": "downloading"
            },
            "beta-hash": {
              "name": "Beta Release",
              "progress": 0.5,
              "state": "downloading"
            }
          }
        }
        """
        return try JSONDecoder().decode(SyncMainData.self, from: Data(json.utf8))
    }
}

@MainActor
private final class StaticTorrentSyncSource: SyncDataFetching {
    private let data: SyncMainData

    init(data: SyncMainData) {
        self.data = data
    }

    func syncMainData(rid: Int) async throws -> SyncMainData {
        data
    }
}

private actor ControlledFilterGate {
    private var started: Set<String> = []
    private var startWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func wait(for search: String) async {
        started.insert(search)
        startWaiters.removeValue(forKey: search)?.resume()
        await withCheckedContinuation { continuation in
            releaseWaiters[search] = continuation
        }
    }

    func waitUntilStarted(_ search: String) async {
        guard !started.contains(search) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[search] = continuation
        }
    }

    func release(_ search: String) {
        releaseWaiters.removeValue(forKey: search)?.resume()
    }
}

@MainActor
private final class FilterWorkCompletions {
    private var results: [String: Bool] = [:]
    private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]

    func record(search: String, applied: Bool) {
        results[search] = applied
        waiters.removeValue(forKey: search)?.resume(returning: applied)
    }

    func wait(for search: String) async -> Bool {
        if let result = results[search] { return result }
        return await withCheckedContinuation { continuation in
            waiters[search] = continuation
        }
    }
}
