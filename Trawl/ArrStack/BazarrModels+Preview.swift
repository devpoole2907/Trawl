#if DEBUG
import Foundation

extension BazarrSeries {
    static let preview = BazarrSeries.makePreview()
    static let previewMissingSubtitles = BazarrSeries.makePreview(
        sonarrSeriesId: 2,
        title: "The Bear",
        episodeFileCount: 28,
        episodeMissingCount: 6,
        profileId: 2
    )
    static let previewUnmonitored = BazarrSeries.makePreview(
        sonarrSeriesId: 3,
        title: "Slow Horses",
        monitored: false,
        episodeFileCount: 24,
        episodeMissingCount: 0
    )
    static let previewMissingArt = BazarrSeries.makePreview(
        sonarrSeriesId: 4,
        title: "Andor",
        poster: nil,
        fanart: nil,
        episodeFileCount: 24,
        episodeMissingCount: 2
    )
    static let previewLongTitle = BazarrSeries.makePreview(
        sonarrSeriesId: 5,
        title: "Don't Forget the Lyrics! With Niecy Nash-Betts Live from Las Vegas",
        episodeFileCount: 48,
        episodeMissingCount: 12
    )
    static let previewList: [BazarrSeries] = [
        preview, previewMissingSubtitles, previewUnmonitored, previewMissingArt, previewLongTitle,
    ]
    static let previewHeavyList: [BazarrSeries] = (1...36).map { index in
        .makePreview(
            sonarrSeriesId: 100 + index,
            title: index.isMultiple(of: 7) ? "Very Long Bazarr Series Title \(index) With Multiple Subtitle Languages Missing" : "Series \(index)",
            year: index.isMultiple(of: 5) ? nil : String(2010 + (index % 14)),
            poster: index.isMultiple(of: 4) ? nil : "https://example.com/bazarr-series-\(index).jpg",
            monitored: !index.isMultiple(of: 6),
            episodeFileCount: 8 + index,
            episodeMissingCount: index.isMultiple(of: 3) ? index % 9 + 1 : 0,
            profileId: index.isMultiple(of: 2) ? 1 : 2
        )
    }

    fileprivate static func makePreview(
        sonarrSeriesId: Int = 1,
        title: String = "Breaking Bad",
        year: String? = "2008",
        overview: String? = "A high school chemistry teacher turns to crime while trying to provide for his family.",
        poster: String? = "https://example.com/breaking-bad.jpg",
        fanart: String? = "https://example.com/breaking-bad-fanart.jpg",
        monitored: Bool = true,
        episodeFileCount: Int = 62,
        episodeMissingCount: Int = 0,
        profileId: Int? = 1
    ) -> BazarrSeries {
        let json: [String: Any?] = [
            "sonarrSeriesId": sonarrSeriesId,
            "title": title,
            "year": year,
            "overview": overview,
            "poster": poster,
            "fanart": fanart,
            "monitored": monitored,
            "profileId": profileId,
            "seriesType": "standard",
            "episodeFileCount": episodeFileCount,
            "episodeMissingCount": episodeMissingCount,
            "audio_language": [["name": "English", "code2": "en", "code3": "eng"]],
            "tags": [String](),
            "alternativeTitles": [String](),
            "ended": false,
            "lastAired": "2024-01-10"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 }, options: [])
        return try! JSONDecoder().decode(BazarrSeries.self, from: data)
    }
}

extension BazarrMovie {
    static let preview = BazarrMovie.makePreview()
    static let previewMissingSubtitles = BazarrMovie.makePreview(
        radarrId: 2,
        title: "Oppenheimer",
        year: "2023",
        subtitles: [.englishSubtitle],
        missingSubtitles: [.spanishMissing, .forcedEnglishMissing]
    )
    static let previewNoSubtitles = BazarrMovie.makePreview(
        radarrId: 3,
        title: "Dune: Part Two",
        year: "2024",
        subtitles: [],
        missingSubtitles: [.englishMissing, .spanishMissing]
    )
    static let previewMissingArt = BazarrMovie.makePreview(
        radarrId: 4,
        title: "Past Lives",
        year: "2023",
        poster: nil,
        fanart: nil
    )
    static let previewLongTitle = BazarrMovie.makePreview(
        radarrId: 5,
        title: "The Assassination of Jesse James by the Coward Robert Ford",
        year: "2007"
    )
    static let previewList: [BazarrMovie] = [
        preview, previewMissingSubtitles, previewNoSubtitles, previewMissingArt, previewLongTitle,
    ]
    static let previewHeavyList: [BazarrMovie] = (1...32).map { index in
        .makePreview(
            radarrId: 200 + index,
            title: index.isMultiple(of: 6) ? "Very Long Movie Title \(index) With Edition Tags and Release Group Metadata" : "Movie \(index)",
            year: index.isMultiple(of: 4) ? nil : String(1995 + (index % 30)),
            poster: index.isMultiple(of: 5) ? nil : "https://example.com/bazarr-movie-\(index).jpg",
            monitored: !index.isMultiple(of: 7),
            profileId: index.isMultiple(of: 2) ? 1 : 2,
            subtitles: index.isMultiple(of: 3) ? [] : [.englishSubtitle],
            missingSubtitles: index.isMultiple(of: 3) ? [.englishMissing, .spanishMissing] : []
        )
    }

    fileprivate static func makePreview(
        radarrId: Int = 1,
        title: String = "The Shawshank Redemption",
        year: String? = "1994",
        overview: String? = "Two imprisoned men bond over a number of years, finding solace and redemption through acts of decency.",
        poster: String? = "https://example.com/shawshank.jpg",
        fanart: String? = "https://example.com/shawshank-fanart.jpg",
        monitored: Bool = true,
        profileId: Int? = 1,
        subtitles: [BazarrSubtitle] = [.englishSubtitle, .englishHISubtitle],
        missingSubtitles: [BazarrSubtitleLanguage] = []
    ) -> BazarrMovie {
        let json: [String: Any?] = [
            "radarrId": radarrId,
            "title": title,
            "year": year,
            "overview": overview,
            "poster": poster,
            "fanart": fanart,
            "monitored": monitored,
            "profileId": profileId,
            "audio_language": [["name": "English", "code2": "en", "code3": "eng"]],
            "subtitles": subtitles.map(\.previewJSON),
            "missing_subtitles": missingSubtitles.map(\.previewJSON),
            "tags": [String](),
            "alternativeTitles": [String](),
            "sceneName": "\(title).\(year ?? "Unknown").1080p.WEB-DL"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 }, options: [])
        return try! JSONDecoder().decode(BazarrMovie.self, from: data)
    }
}

extension BazarrEpisode {
    static let preview = BazarrEpisode.makePreview()
    static let previewMissing = BazarrEpisode.makePreview(
        sonarrEpisodeId: 2,
        episode: 2,
        title: "Cat's in the Bag...",
        subtitles: [.englishSubtitle],
        missingSubtitles: [.spanishMissing]
    )
    static let previewNoSubtitles = BazarrEpisode.makePreview(
        sonarrEpisodeId: 3,
        episode: 3,
        title: "...And the Bag's in the River",
        subtitles: [],
        missingSubtitles: [.englishMissing, .spanishMissing]
    )
    static let previewForced = BazarrEpisode.makePreview(
        sonarrEpisodeId: 4,
        episode: 4,
        title: "Cancer Man",
        subtitles: [.englishSubtitle],
        missingSubtitles: [.forcedEnglishMissing]
    )
    static let previewLongTitle = BazarrEpisode.makePreview(
        sonarrEpisodeId: 5,
        season: 2,
        episode: 1,
        title: "A Very Long Episode Title That Needs To Wrap Cleanly In Compact Rows",
        subtitles: [],
        missingSubtitles: [.englishMissing]
    )

    static let previewList: [BazarrEpisode] = [
        preview, previewMissing, previewNoSubtitles, previewForced, previewLongTitle,
        .makePreview(sonarrEpisodeId: 6, season: 2, episode: 2, title: "Grilled"),
        .makePreview(sonarrEpisodeId: 7, season: 2, episode: 3, title: "Bit by a Dead Bee", missingSubtitles: [.spanishMissing]),
        .makePreview(sonarrEpisodeId: 8, season: 2, episode: 4, title: "Down"),
    ]

    fileprivate static func makePreview(
        sonarrEpisodeId: Int = 1,
        sonarrSeriesId: Int = 1,
        season: Int = 1,
        episode: Int = 1,
        title: String = "Pilot",
        monitored: Bool = true,
        subtitles: [BazarrSubtitle] = [.englishSubtitle],
        missingSubtitles: [BazarrSubtitleLanguage] = []
    ) -> BazarrEpisode {
        let json: [String: Any?] = [
            "sonarrEpisodeId": sonarrEpisodeId,
            "sonarrSeriesId": sonarrSeriesId,
            "season": season,
            "episode": episode,
            "title": title,
            "monitored": monitored,
            "subtitles": subtitles.map(\.previewJSON),
            "missing_subtitles": missingSubtitles.map(\.previewJSON),
            "audio_language": [["name": "English", "code2": "en", "code3": "eng"]],
            "path": "/media/tv/Breaking Bad/Season \(season)/S\(season)E\(episode).mkv",
            "sceneName": "Breaking.Bad.S\(season)E\(episode).1080p.WEB-DL"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 }, options: [])
        return try! JSONDecoder().decode(BazarrEpisode.self, from: data)
    }
}

extension BazarrLanguageProfile {
    static let preview = BazarrLanguageProfile.makePreview()
    static let previewBilingual = BazarrLanguageProfile.makePreview(
        profileId: 2,
        name: "English & Spanish",
        items: [
            .init(bazarrId: 20, language: "en"),
            .init(bazarrId: 21, language: "es"),
        ]
    )
    static let previewForcedOnly = BazarrLanguageProfile.makePreview(
        profileId: 3,
        name: "Forced English",
        items: [.init(bazarrId: 30, language: "en", forced: true)]
    )
    static let previewNoLanguages = BazarrLanguageProfile.makePreview(profileId: 4, name: "Empty Profile", items: [])
    static let previewList: [BazarrLanguageProfile] = [
        preview, previewBilingual, previewForcedOnly, previewNoLanguages,
    ]

    fileprivate static func makePreview(
        profileId: Int = 1,
        name: String = "English",
        items: [BazarrLanguageProfileItem] = [.init(bazarrId: 10, language: "en")],
        mustContain: [String]? = nil,
        mustNotContain: [String]? = ["cam", "telesync"]
    ) -> BazarrLanguageProfile {
        let data = try! JSONEncoder().encode(items)
        let itemsJSON = String(data: data, encoding: .utf8)
        return BazarrLanguageProfile(
            profileId: profileId,
            name: name,
            cutoff: items.first?.bazarrId,
            itemsJSON: itemsJSON,
            mustContain: mustContain,
            mustNotContain: mustNotContain,
            originalFormat: nil,
            tag: nil
        )
    }
}

extension BazarrLanguage {
    static let preview = BazarrLanguage(name: "English", code2: "en", code3: "eng", enabled: true)
    static let previewList: [BazarrLanguage] = [
        preview,
        .init(name: "Spanish", code2: "es", code3: "spa", enabled: true),
        .init(name: "French", code2: "fr", code3: "fra", enabled: false),
        .init(name: "German", code2: "de", code3: "deu", enabled: true),
        .init(name: "Japanese", code2: "ja", code3: "jpn", enabled: true),
    ]
}

extension BazarrProvider {
    static let preview = BazarrProvider(name: "opensubtitlescom", status: "Running", retry: nil)
    static let previewWarning = BazarrProvider(name: "addic7ed", status: "Error: throttled", retry: "2024-01-20T12:00:00Z")
    static let previewList: [BazarrProvider] = [
        preview,
        .init(name: "embeddedsubtitles", status: "Running", retry: nil),
        previewWarning,
    ]
}

extension BazarrInteractiveSearchResult {
    static let previewList: [BazarrInteractiveSearchResult] = [
        makePreview(provider: "OpenSubtitles.com", score: 93, matches: ["hash", "title"], releaseInfo: "Breaking.Bad.S01E01.1080p.WEB-DL"),
        makePreview(provider: "Embedded Subtitles", score: 78, matches: ["title"], releaseInfo: "Internal English SDH", hearingImpaired: true),
        makePreview(provider: "Addic7ed", score: 62, matches: ["series"], releaseInfo: "HDTV release", forcedSubtitle: true),
    ]

    fileprivate static func makePreview(
        provider: String,
        score: Double,
        matches: [String],
        releaseInfo: String,
        hearingImpaired: Bool = false,
        forcedSubtitle: Bool = false
    ) -> BazarrInteractiveSearchResult {
        let json: [String: Any] = [
            "provider": provider,
            "subtitle": "\(provider)-subtitle-id",
            "score": score,
            "matches": matches,
            "release_info": releaseInfo,
            "title": releaseInfo,
            "hearing_impaired": hearingImpaired,
            "forced_subtitle": forcedSubtitle,
            "language": ["name": "English", "code2": "en", "code3": "eng"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(BazarrInteractiveSearchResult.self, from: data)
    }
}

fileprivate extension BazarrSubtitle {
    static let englishSubtitle = makePreview(name: "English", code2: "en", code3: "eng", path: "/media/subtitles/en.srt")
    static let englishHISubtitle = makePreview(name: "English HI", code2: "en", code3: "eng", path: "/media/subtitles/en-hi.srt", hi: true)

    var previewJSON: [String: Any] {
        [
            "name": name,
            "code2": code2,
            "code3": code3,
            "path": path ?? "",
            "forced": forced,
            "hi": hi,
            "file_size": fileSize ?? 48_000,
        ]
    }

    static func makePreview(
        name: String,
        code2: String,
        code3: String,
        path: String?,
        forced: Bool = false,
        hi: Bool = false
    ) -> BazarrSubtitle {
        let json: [String: Any?] = [
            "name": name,
            "code2": code2,
            "code3": code3,
            "path": path,
            "forced": forced,
            "hi": hi,
            "file_size": 48_000,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 }, options: [])
        return try! JSONDecoder().decode(BazarrSubtitle.self, from: data)
    }
}

fileprivate extension BazarrSubtitleLanguage {
    static let englishMissing = makePreview(name: "English", code2: "en", code3: "eng")
    static let forcedEnglishMissing = makePreview(name: "English", code2: "en", code3: "eng", forced: true)
    static let spanishMissing = makePreview(name: "Spanish", code2: "es", code3: "spa")

    var previewJSON: [String: Any] {
        [
            "name": name,
            "code2": code2,
            "code3": code3,
            "forced": forced,
            "hi": hi,
        ]
    }

    static func makePreview(
        name: String,
        code2: String,
        code3: String,
        forced: Bool = false,
        hi: Bool = false
    ) -> BazarrSubtitleLanguage {
        let json: [String: Any] = [
            "name": name,
            "code2": code2,
            "code3": code3,
            "forced": forced,
            "hi": hi,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(BazarrSubtitleLanguage.self, from: data)
    }
}
#endif
