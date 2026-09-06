//
//  QueueDownloadCollisionTests.swift
//  TrawlTests
//
//  The live half of the shared-download-client fault.
//

import Foundation
import Testing

@testable import Trawl

@Suite("Queue download collisions")
struct QueueDownloadCollisionTests {

    private static let hdID = UUID()
    private static let uhdID = UUID()

    private static func instance(
        _ id: UUID,
        type: ArrServiceType = .radarr,
        name: String = "Radarr",
        tier: ArrQualityTier = .hd
    ) -> ArrInstanceRef {
        ArrInstanceRef(id: id, serviceType: type, displayName: name, tier: tier)
    }

    /// Built through the decoder rather than a memberwise initialiser because
    /// `ArrQueueItem` has none - it is a wire model, and the preview helper pins
    /// `downloadId` to a value derived from the row id, which is the one field
    /// every test here needs to control.
    private static func queueItem(id: Int, downloadId: String?, title: String = "American Hustle") -> ArrQueueItem {
        var json: [String: Any] = [
            "id": id,
            "title": title,
            "status": "downloading",
            "protocol": "usenet",
            "downloadClient": "SABnzbd"
        ]
        if let downloadId { json["downloadId"] = downloadId }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ArrQueueItem.self, from: data)
    }

    private static func row(
        _ item: ArrQueueItem,
        on instance: ArrInstanceRef
    ) -> ArrInstanced<ArrQueueItem> {
        ArrInstanced(item, on: instance, elementID: String(item.id))
    }

    // MARK: The collision itself

    /// The incident this exists for: one SABnzbd deduped two grabs of the same
    /// release into a single job, and both Radarrs now hold a queue entry pointing
    /// at it. Whichever imports first moves the file into its own library and the
    /// other's import fails against a folder that is no longer there.
    @Test("One download id in two instances' queues is a collision")
    func sameDownloadIdAcrossInstances() {
        let rows = [
            Self.row(Self.queueItem(id: 527, downloadId: "1d7faff2"), on: Self.instance(Self.hdID)),
            Self.row(Self.queueItem(id: 210, downloadId: "1d7faff2"), on: Self.instance(Self.uhdID, name: "Radarr 4K", tier: .uhd))
        ]
        let found = QueueDownloadCollisionDetector.find(in: rows)

        #expect(found.count == 1)
        #expect(found.first?.downloadId == "1d7faff2")
        // One entry per instance, not per queue row - the banner names who is
        // involved, and a count of rows would be a different question.
        #expect(found.first?.entries.count == 2)
        #expect(found.first?.instances.map(\.id) == [Self.hdID, Self.uhdID])
    }

    /// Ordered by tier, like every other badge row in the app, so the banner reads
    /// "Radarr Default and Radarr 4K" rather than in whatever order a dictionary
    /// happened to hand back.
    @Test("The instances are reported in tier order")
    func instancesAreTierOrdered() {
        let rows = [
            Self.row(Self.queueItem(id: 210, downloadId: "abc"), on: Self.instance(Self.uhdID, name: "Radarr 4K", tier: .uhd)),
            Self.row(Self.queueItem(id: 527, downloadId: "abc"), on: Self.instance(Self.hdID))
        ]
        let found = QueueDownloadCollisionDetector.find(in: rows)
        #expect(found.first?.instances.map(\.tier) == [.hd, .uhd])
    }

    /// Download clients hand out ids as hex hashes or opaque tokens, and nothing in
    /// either API guarantees two Arrs re-report one client's id with the same
    /// casing or without stray whitespace.
    @Test("Ids match regardless of case and surrounding whitespace")
    func idComparisonIsNormalized() {
        let rows = [
            Self.row(Self.queueItem(id: 1, downloadId: "1D7FAFF2"), on: Self.instance(Self.hdID)),
            Self.row(Self.queueItem(id: 2, downloadId: " 1d7faff2 "), on: Self.instance(Self.uhdID, tier: .uhd))
        ]
        #expect(QueueDownloadCollisionDetector.find(in: rows).count == 1)
    }

    // MARK: What must never be reported

    /// The false positive that would fire on every ordinary Sonarr. A season pack
    /// downloading five episodes produces five queue rows sharing one download id
    /// inside a *single* instance - that is one download doing its job. Grouping on
    /// rows rather than instances would flag it, and flag it constantly.
    @Test("One instance reporting a download id many times is not a collision")
    func repeatedIdWithinOneInstanceIsSilent() {
        let sonarr = Self.instance(Self.hdID, type: .sonarr, name: "Sonarr")
        let rows = (1...5).map {
            Self.row(Self.queueItem(id: $0, downloadId: "season-pack", title: "The Bear S03E0\($0)"), on: sonarr)
        }
        #expect(QueueDownloadCollisionDetector.find(in: rows).isEmpty)
    }

    /// Two rows that are each missing an id are not "the same download with no id",
    /// they are two unrelated rows both missing a fact - an item still waiting to be
    /// grabbed, or a decode that did not populate the field. Bucketing absences
    /// together would manufacture a collision out of nothing, and it would do it on
    /// the most ordinary setup there is.
    @Test("Missing and empty download ids never group together")
    func absentIdsDoNotCollide() {
        for absent in [nil, "", "   "] as [String?] {
            let rows = [
                Self.row(Self.queueItem(id: 1, downloadId: absent), on: Self.instance(Self.hdID)),
                Self.row(Self.queueItem(id: 2, downloadId: absent), on: Self.instance(Self.uhdID, tier: .uhd))
            ]
            #expect(QueueDownloadCollisionDetector.find(in: rows).isEmpty)
        }
    }

    /// Two instances downloading different things is the normal state of a working
    /// HD/4K pair, and the check has to stay silent through it or it says nothing at
    /// all.
    @Test("Different downloads in two queues are silent")
    func distinctDownloadsAreSilent() {
        let rows = [
            Self.row(Self.queueItem(id: 1, downloadId: "aaa"), on: Self.instance(Self.hdID)),
            Self.row(Self.queueItem(id: 2, downloadId: "bbb"), on: Self.instance(Self.uhdID, tier: .uhd))
        ]
        #expect(QueueDownloadCollisionDetector.find(in: rows).isEmpty)
    }

    /// An empty queue, and a single instance's queue, are both trivially fine - and
    /// both are what the detector sees on most launches, so neither may crash or
    /// report.
    @Test("No queues and one queue are silent")
    func emptyAndSingleInstanceAreSilent() {
        #expect(QueueDownloadCollisionDetector.find(in: []).isEmpty)
        let rows = [Self.row(Self.queueItem(id: 1, downloadId: "aaa"), on: Self.instance(Self.hdID))]
        #expect(QueueDownloadCollisionDetector.find(in: rows).isEmpty)
    }

    // MARK: Stability

    /// Several collisions at once come back in a fixed order. The banner shows the
    /// first, and an order that changed between polls would rotate which collision
    /// the user is looking at every few seconds.
    @Test("Multiple collisions are ordered stably")
    func multipleCollisionsAreOrdered() {
        let hd = Self.instance(Self.hdID)
        let uhd = Self.instance(Self.uhdID, name: "Radarr 4K", tier: .uhd)
        let rows = [
            Self.row(Self.queueItem(id: 1, downloadId: "zzz"), on: hd),
            Self.row(Self.queueItem(id: 2, downloadId: "zzz"), on: uhd),
            Self.row(Self.queueItem(id: 3, downloadId: "aaa"), on: hd),
            Self.row(Self.queueItem(id: 4, downloadId: "aaa"), on: uhd)
        ]
        #expect(QueueDownloadCollisionDetector.find(in: rows).map(\.downloadId) == ["aaa", "zzz"])
        // And the same answer from the reversed input, or the "stable" ordering is
        // only stable for the order the rows happened to arrive in.
        #expect(QueueDownloadCollisionDetector.find(in: rows.reversed()).map(\.downloadId) == ["aaa", "zzz"])
    }
}
