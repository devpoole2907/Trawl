#if DEBUG
import Foundation

extension Torrent {
    static let preview = Torrent.makePreview()
    static let previewDownloading = Torrent.makePreview(
        name: "Ubuntu 24.04 LTS Desktop", progress: 0.42,
        dlspeed: 4_500_000, upspeed: 120_000, eta: 480, state: .downloading
    )
    static let previewSeeding = Torrent.makePreview(
        name: "Big Buck Bunny", progress: 1.0,
        dlspeed: 0, upspeed: 800_000, ratio: 4.21, state: .uploading
    )
    static let previewStalled = Torrent.makePreview(
        name: "Some Linux ISO", progress: 0.05, numSeeds: 0, state: .stalledDL
    )
    static let previewError = Torrent.makePreview(name: "Broken", state: .error)
    static let previewLongName = Torrent.makePreview(
        name: "[Release.Group] A.Very.Long.Show.Name.S01E01.2160p.UHD.BluRay.HEVC.HDR10.DTS-HD.MA.5.1-GROUP.mkv"
    )

    static let previewList: [Torrent] = [
        previewDownloading, previewSeeding, previewStalled, previewError, previewLongName,
    ]

    static let previewHeavyList: [Torrent] = (1...60).map { i in
        .makePreview(
            hash: String(format: "%040x", i),
            name: i.isMultiple(of: 7) ? "Very Long Torrent Name \(i)" : "Torrent \(i)",
            progress: Double(i % 11) / 10.0,
            state: [.downloading, .uploading, .stalledDL, .pausedDL, .queuedDL][i % 5]
        )
    }

    fileprivate static func makePreview(
        hash: String = "abc123def456abc123def456abc123def456abc1",
        name: String = "Sample Torrent",
        size: Int64 = 1_500_000_000,
        progress: Double = 0.5,
        dlspeed: Int64 = 1_000_000,
        upspeed: Int64 = 100_000,
        numSeeds: Int = 12,
        numLeechs: Int = 3,
        ratio: Double = 1.2,
        eta: Int = 600,
        state: TorrentState = .downloading,
        category: String? = "movies"
    ) -> Torrent {
        Torrent(
            hash: hash, name: name, size: size, progress: progress,
            dlspeed: dlspeed, upspeed: upspeed, priority: 0,
            numSeeds: numSeeds, numLeechs: numLeechs, ratio: ratio, eta: eta,
            state: state, category: category, tags: nil,
            addedOn: Int(Date().timeIntervalSince1970) - 3600,
            completionOn: progress >= 1 ? Int(Date().timeIntervalSince1970) : -1,
            savePath: "/downloads",
            downloadedSession: 500_000_000,
            uploadedSession: 100_000_000,
            amountLeft: Int64(Double(size) * (1 - progress)),
            totalSize: size, comment: nil,
            sequentialDownload: false, firstLastPiecePriority: false
        )
    }
}
#endif
