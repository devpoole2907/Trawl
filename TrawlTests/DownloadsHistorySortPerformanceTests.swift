//
//  DownloadsHistorySortPerformanceTests.swift
//  TrawlTests
//
//  The Downloads History section froze the tab with a real library's worth of
//  history. This measures the sort that does it.
//

import Foundation
import Testing
@testable import Trawl

@Suite("Downloads history sort performance")
@MainActor
struct DownloadsHistorySortPerformanceTests {
    private static let decoder = JSONDecoder()

    /// Real Sonarr history shape. `date` is deliberately identical across most rows:
    /// history arrives in bursts, so ties are the common case, and a tie is what
    /// pushes the comparator past its primary key into the name tiebreaker.
    private static func historyItems(count: Int) throws -> [DownloadListItem] {
        try (0..<count).map { index in
            let json = """
            {
              "id": \(index),
              "eventType": "downloadFolderImported",
              "date": "2026-08-30T12:00:00Z",
              "sourceTitle": "Fixture Release \(index % 50) S01E\(index % 24)",
              "downloadId": "abc\(index)",
              "data": {"releaseTitle": "Fixture Release \(index)", "indexer": "Fixture Indexer"}
            }
            """
            let record = try Self.decoder.decode(ArrHistoryRecord.self, from: Data(json.utf8))
            return .arrHistory(HistoryItem(record: record, source: .sonarr))
        }
    }

    private static func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date.now
        work()
        return Date.now.timeIntervalSince(start)
    }

    /// The shape the view used: `sortValues` is a computed property, so `sorted`
    /// rebuilt it twice per comparison - roughly `2 · n log n` constructions, each
    /// doing string interpolation, a formatter lookup and two dictionary reads.
    @Test("Sorting history by recomputing the key per comparison is the slow path")
    func recomputingKeysIsSlow() throws {
        let items = try Self.historyItems(count: 2_000)
        let sortOrder = DownloadSortCriterion.date

        let naive = Self.elapsed {
            _ = items.sorted { sortOrder.areInIncreasingOrder($0.sortValues, $1.sortValues) }
        }

        // The production path, which builds the key once per item.
        let decorated = Self.elapsed {
            _ = items.sortedByDownloadOrder(sortOrder)
        }

        // Recorded rather than asserted as a hard ratio: the point is the shape of
        // the difference, and a machine-dependent multiple would be a flaky test.
        print("TRAWL-PERF history sort n=2000 recomputed=\(naive)s decorated=\(decorated)s")

        #expect(decorated < naive, "Building the sort key once per item must beat rebuilding it per comparison.")
    }

    /// A faster sort that reorders the list is not a fix. The production helper has
    /// to agree, row for row, with the comparator applied directly.
    @Test("Building the key once produces exactly the same order")
    func decoratedSortMatchesTheDirectComparator() throws {
        let items = try Self.historyItems(count: 300)
        for criterion in [DownloadSortCriterion.date, .name, .status, .size] {
            let direct = items.sorted { criterion.areInIncreasingOrder($0.sortValues, $1.sortValues) }
            let decorated = items.sortedByDownloadOrder(criterion)
            #expect(direct.map(\.id) == decorated.map(\.id), "Order diverged for \(criterion).")
        }
    }

    /// The guard that matters: whatever the implementation, sorting a realistic
    /// history has to stay far below anything a user would perceive as a freeze.
    @Test("Sorting a realistic history stays well inside a frame budget")
    func sortingStaysFast() throws {
        let items = try Self.historyItems(count: 2_000)
        let sortOrder = DownloadSortCriterion.date

        let decorated = Self.elapsed {
            _ = items.sortedByDownloadOrder(sortOrder)
        }

        // Generous by design - this is a regression guard, not a benchmark. The
        // failing behaviour it protects against was seconds, not milliseconds.
        #expect(decorated < 1.0, "Sorting 2,000 history rows should not take anywhere near a second.")
    }
}
