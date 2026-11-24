import Foundation
import Testing
@testable import Trawl

/// Downloads hides a segment with nothing in it, keeps the one you're on, and
/// opening on an empty one lands on the first that has downloads. These drive the
/// real section pipeline with torrents from the client, so "empty" means what the
/// segment bar would compute, not a list handed in.
@Suite("Downloads empty segments")
@MainActor
struct DownloadsEmptySegmentTests {
    private let all = DownloadSection.allCases

    @Test("Only segments holding a download count as non-empty, whatever the search says")
    func nonEmptyFollowsTheData() throws {
        let model = DownloadsViewModel()
        let manager = ArrServiceManager()
        model.searchText = "nothing matches this"

        let nonEmpty = model.nonEmptySections(
            all, scope: .torrents, serviceManager: manager,
            torrents: try Self.torrents(["seed": "uploading"]),
            sabActiveJobs: [], sabHistoryJobs: [], sabRevision: 0, torrentsRevision: 1
        )

        #expect(nonEmpty == [.seeding], "A search narrows the list; it doesn't hide segments.")
    }

    @Test("A segment that empties disappears once the data changes, unless you're on it")
    func emptiedSegmentDisappears() throws {
        let model = DownloadsViewModel()
        let manager = ArrServiceManager()

        let before = model.nonEmptySections(
            all, scope: .torrents, serviceManager: manager,
            torrents: try Self.torrents(["seed": "uploading", "pull": "downloading"]),
            sabActiveJobs: [], sabHistoryJobs: [], sabRevision: 0, torrentsRevision: 1
        )
        #expect(before.contains(.active))
        #expect(DownloadsViewModel.visibleSections(all, nonEmpty: before, selected: .seeding).contains(.active))

        // The download finishes: the next revision has nothing downloading.
        let after = model.nonEmptySections(
            all, scope: .torrents, serviceManager: manager,
            torrents: try Self.torrents(["seed": "uploading", "pull": "uploading"]),
            sabActiveJobs: [], sabHistoryJobs: [], sabRevision: 0, torrentsRevision: 2
        )
        #expect(!after.contains(.active))
        #expect(!DownloadsViewModel.visibleSections(all, nonEmpty: after, selected: .seeding).contains(.active))
        #expect(DownloadsViewModel.visibleSections(all, nonEmpty: after, selected: .active).contains(.active),
                "The segment you're on stays until you leave it.")
    }

    @Test("Opening on an empty segment lands on the first with downloads, and only then")
    func landingSection() {
        let nonEmpty: Set<DownloadSection> = [.seeding, .history]
        #expect(DownloadsViewModel.landingSection(all, nonEmpty: nonEmpty, selected: .active) == .seeding)
        #expect(DownloadsViewModel.landingSection(all, nonEmpty: nonEmpty, selected: .history) == nil)
        #expect(DownloadsViewModel.landingSection(all, nonEmpty: [], selected: .active) == nil,
                "With everything empty there is nowhere better to go.")
    }

    private static func torrents(_ states: [String: String]) throws -> [String: Torrent] {
        var result: [String: Torrent] = [:]
        for (hash, state) in states {
            let json = """
            {
              "hash": "\(hash)", "name": "\(hash)", "size": 1000, "progress": \(state == "downloading" ? 0.5 : 1),
              "dlspeed": 0, "upspeed": 0, "priority": 1, "num_seeds": 2, "num_leechs": 1,
              "ratio": 0.5, "eta": 600, "state": "\(state)", "category": "", "tags": "",
              "added_on": 0, "completion_on": 0, "save_path": "/downloads",
              "downloaded_session": 0, "uploaded_session": 0, "amount_left": 0, "total_size": 1000,
              "seq_dl": false, "f_l_piece_prio": false
            }
            """
            result[hash] = try JSONDecoder().decode(Torrent.self, from: Data(json.utf8))
        }
        return result
    }
}
