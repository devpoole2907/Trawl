#if DEBUG
import Foundation

extension SonarrSeries {
    static let preview = SonarrSeries.makePreview()
    static let previewEnded = SonarrSeries.makePreview(id: 2, title: "Severance", status: "ended", monitored: false)
    static let previewMissingArt = SonarrSeries.makePreview(id: 3, title: "The Bear", remotePoster: nil, images: nil)
    static let previewLongTitle = SonarrSeries.makePreview(
        id: 4,
        title: "Don't Forget the Lyrics! With Niecy Nash-Betts Live from Las Vegas",
        sortTitle: "dont forget lyrics niecy nash"
    )
    static let previewDiscover = SonarrSeries.makePreview(
        id: -94221,
        title: "Silo",
        sortTitle: "silo",
        status: "continuing",
        network: "Apple TV+",
        year: 2023,
        tvdbId: 415665,
        titleSlug: "silo",
        episodeCount: 20,
        episodeFileCount: 0
    )

    static let previewList: [SonarrSeries] = [
        preview, previewEnded, previewMissingArt,
        .makePreview(id: 5, title: "Andor", status: "continuing", monitored: true),
        .makePreview(id: 6, title: "Slow Horses", status: "continuing", monitored: true),
    ]

    static let previewHeavyList: [SonarrSeries] = (1...40).map { i in
        .makePreview(
            id: 100 + i,
            title: i.isMultiple(of: 7) ? "Very Long Show Title Number \(i) That Wraps Across Many Lines" : "Show \(i)",
            status: i.isMultiple(of: 3) ? "ended" : "continuing",
            monitored: !i.isMultiple(of: 5),
            remotePoster: i.isMultiple(of: 4) ? nil : "https://example.com/poster\(i).jpg"
        )
    }

    fileprivate static func makePreview(
        id: Int = 1,
        title: String = "Breaking Bad",
        sortTitle: String = "breaking bad",
        status: String = "ended",
        network: String? = "AMC",
        year: Int? = 2008,
        tvdbId: Int = 81189,
        titleSlug: String? = nil,
        monitored: Bool = true,
        remotePoster: String? = "https://example.com/bb.jpg",
        images: [ArrImage]? = [.init(coverType: "poster", url: "https://example.com/bb.jpg", remoteUrl: nil)],
        episodeCount: Int = 62,
        episodeFileCount: Int = 62
    ) -> SonarrSeries {
        func value<T>(_ optional: T?) -> Any {
            optional.map { $0 as Any } ?? NSNull()
        }

        let seasons: [[String: Any]] = (1...5).map { season in
            [
                "seasonNumber": season,
                "monitored": true,
                "statistics": [
                    "episodeCount": season == 1 ? 7 : 13,
                    "episodeFileCount": season == 1 ? min(7, episodeFileCount) : 13,
                    "totalEpisodeCount": season == 1 ? 7 : 13,
                    "sizeOnDisk": 32_000_000_000
                ]
            ]
        }
        let json: [String: Any] = [
            "id": id, "title": title, "sortTitle": sortTitle, "status": status,
            "monitored": monitored, "remotePoster": value(remotePoster),
            "images": images.map { _ in [["coverType": "poster", "url": remotePoster ?? "", "remoteUrl": NSNull()]] } ?? [],
            "overview": "A high school chemistry teacher turned methamphetamine producer.",
            "network": value(network), "year": value(year), "tvdbId": tvdbId, "imdbId": "tt0903747",
            "titleSlug": titleSlug ?? title.lowercased().replacingOccurrences(of: " ", with: "-"),
            "seriesType": "standard", "seasonFolder": true, "rootFolderPath": "/tv", "path": "/tv/\(title)",
            "qualityProfileId": 1, "tags": [Int](),
            "genres": ["Crime", "Drama"],
            "runtime": 47,
            "ratings": ["votes": 12000, "value": 8.9],
            "seasons": seasons,
            "alternateTitles": [["title": "\(title) (US)", "seasonNumber": NSNull()]],
            "statistics": ["seasonCount": 5, "episodeCount": episodeCount, "episodeFileCount": episodeFileCount,
                           "totalEpisodeCount": episodeCount, "sizeOnDisk": 178_000_000_000]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SonarrSeries.self, from: data)
    }
}

extension SonarrEpisode {
    static let preview = SonarrEpisode.makePreview()
    static let previewList: [SonarrEpisode] = (1...10).map {
        .makePreview(
            id: $0,
            episodeNumber: $0,
            title: $0 == 1 ? "Pilot" : "Episode \($0)",
            hasFile: $0 <= 6,
            episodeFileId: $0 <= 3 ? 1000 + $0 : nil
        )
    }
    static let previewUnaired: [SonarrEpisode] = (1...5).map {
        .makePreview(id: 100 + $0, episodeNumber: $0, monitored: true, hasFile: false,
                     airDateUtc: "2030-01-0\($0)T20:00:00Z")
    }

    fileprivate static func makePreview(
        id: Int = 1, seriesId: Int = 1, seasonNumber: Int = 1, episodeNumber: Int = 1,
        title: String = "Pilot", monitored: Bool = true, hasFile: Bool = true,
        episodeFileId: Int? = 1001,
        airDate: String? = "2008-01-20",
        airDateUtc: String? = "2008-01-20T20:00:00Z"
    ) -> SonarrEpisode {
        func value<T>(_ optional: T?) -> Any {
            optional.map { $0 as Any } ?? NSNull()
        }

        let json: [String: Any] = [
            "id": id, "seriesId": seriesId, "seasonNumber": seasonNumber,
            "episodeNumber": episodeNumber, "title": title, "monitored": monitored,
            "episodeFileId": value(episodeFileId),
            "hasFile": hasFile, "airDate": value(airDate), "airDateUtc": value(airDateUtc),
            "overview": "Episode \(episodeNumber)"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SonarrEpisode.self, from: data)
    }
}

extension SonarrEpisodeFile {
    static let preview = SonarrEpisodeFile(
        id: 1001,
        seriesId: 1,
        seasonNumber: 1,
        relativePath: "Season 01/Breaking Bad - S01E01 - Pilot.mkv",
        path: "/tv/Breaking Bad/Season 01/Breaking Bad - S01E01 - Pilot.mkv",
        size: 4_800_000_000,
        dateAdded: "2024-01-15T12:00:00Z",
        quality: ArrHistoryQuality(quality: ArrQuality(id: 7, name: "Bluray-1080p", source: "bluray", resolution: 1080)),
        mediaInfo: SonarrMediaInfo(
            audioBitrate: 640000,
            audioChannels: 5.1,
            audioCodec: "AC3",
            audioLanguages: "English",
            audioStreamCount: 1,
            videoBitDepth: 10,
            videoBitrate: 8_500_000,
            videoCodec: "HEVC",
            videoFps: 23.976,
            resolution: "1920x1080",
            runTime: "00:58:12",
            scanType: "Progressive",
            subtitles: "English"
        )
    )

    static let previewList: [SonarrEpisodeFile] = [
        preview,
        SonarrEpisodeFile(
            id: 1002,
            seriesId: 1,
            seasonNumber: 1,
            relativePath: "Season 01/Breaking Bad - S01E02 - Cat's in the Bag.mkv",
            path: "/tv/Breaking Bad/Season 01/Breaking Bad - S01E02 - Cat's in the Bag.mkv",
            size: 4_400_000_000,
            dateAdded: "2024-01-16T12:00:00Z",
            quality: ArrHistoryQuality(quality: ArrQuality(id: 7, name: "Bluray-1080p", source: "bluray", resolution: 1080)),
            mediaInfo: preview.mediaInfo
        ),
        SonarrEpisodeFile(
            id: 1003,
            seriesId: 1,
            seasonNumber: 1,
            relativePath: "Season 01/Breaking Bad - S01E03 - ...And the Bag's in the River.mkv",
            path: "/tv/Breaking Bad/Season 01/Breaking Bad - S01E03 - ...And the Bag's in the River.mkv",
            size: 4_300_000_000,
            dateAdded: "2024-01-17T12:00:00Z",
            quality: ArrHistoryQuality(quality: ArrQuality(id: 7, name: "Bluray-1080p", source: "bluray", resolution: 1080)),
            mediaInfo: preview.mediaInfo
        ),
    ]
}
#endif
