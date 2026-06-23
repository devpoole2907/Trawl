import Foundation

// MARK: - Library Options
//
// Mirrors Jellyfin's `LibraryOptions` object (returned inside each
// `/Library/VirtualFolders` entry and round-tripped via
// `POST /Library/VirtualFolders/LibraryOptions`). Jellyfin's update endpoint
// *replaces* the whole object, so we model a broad set of fields and decode
// losslessly (defaults fill any key an older server omits) to avoid clobbering
// settings we don't surface in the UI.
//
// All model structs are `nonisolated` so they stay `Sendable` and decode off the
// main actor, matching the rest of `JellyfinSharedModels`.

nonisolated struct JellyfinLibraryOptions: Codable, Sendable, Equatable {
    var enablePhotos: Bool = true
    var enableRealtimeMonitor: Bool = true
    var enableLUFSScan: Bool = true
    var enableChapterImageExtraction: Bool = false
    var extractChapterImagesDuringLibraryScan: Bool = false
    var enableTrickplayImageExtraction: Bool = false
    var extractTrickplayImagesDuringLibraryScan: Bool = false
    var saveTrickplayWithMedia: Bool = false
    var saveLocalMetadata: Bool = false
    var enableInternetProviders: Bool = true
    var enableAutomaticSeriesGrouping: Bool = false
    var enableEmbeddedTitles: Bool = false
    var enableEmbeddedExtrasTitles: Bool = false
    var enableEmbeddedEpisodeInfos: Bool = false
    var automaticRefreshIntervalDays: Int = 30
    var preferredMetadataLanguage: String = ""
    var metadataCountryCode: String = ""
    var seasonZeroDisplayName: String = "Specials"
    var metadataSavers: [String] = []
    var disabledLocalMetadataReaders: [String] = []
    var localMetadataReaderOrder: [String] = []
    var disabledSubtitleFetchers: [String] = []
    var subtitleFetcherOrder: [String] = []
    var skipSubtitlesIfEmbeddedSubtitlesPresent: Bool = false
    var skipSubtitlesIfAudioTrackMatches: Bool = false
    var subtitleDownloadLanguages: [String] = []
    var requirePerfectSubtitleMatch: Bool = true
    var saveSubtitlesWithMedia: Bool = true
    var saveLyricsWithMedia: Bool = false
    var automaticallyAddToCollection: Bool = false
    var allowEmbeddedSubtitles: String = JellyfinEmbeddedSubtitleOption.allowAll.rawValue
    var pathInfos: [JellyfinLibraryPathInfo] = []
    var typeOptions: [JellyfinTypeOptions] = []

    enum CodingKeys: String, CodingKey {
        case enablePhotos = "EnablePhotos"
        case enableRealtimeMonitor = "EnableRealtimeMonitor"
        case enableLUFSScan = "EnableLUFSScan"
        case enableChapterImageExtraction = "EnableChapterImageExtraction"
        case extractChapterImagesDuringLibraryScan = "ExtractChapterImagesDuringLibraryScan"
        case enableTrickplayImageExtraction = "EnableTrickplayImageExtraction"
        case extractTrickplayImagesDuringLibraryScan = "ExtractTrickplayImagesDuringLibraryScan"
        case saveTrickplayWithMedia = "SaveTrickplayWithMedia"
        case saveLocalMetadata = "SaveLocalMetadata"
        case enableInternetProviders = "EnableInternetProviders"
        case enableAutomaticSeriesGrouping = "EnableAutomaticSeriesGrouping"
        case enableEmbeddedTitles = "EnableEmbeddedTitles"
        case enableEmbeddedExtrasTitles = "EnableEmbeddedExtrasTitles"
        case enableEmbeddedEpisodeInfos = "EnableEmbeddedEpisodeInfos"
        case automaticRefreshIntervalDays = "AutomaticRefreshIntervalDays"
        case preferredMetadataLanguage = "PreferredMetadataLanguage"
        case metadataCountryCode = "MetadataCountryCode"
        case seasonZeroDisplayName = "SeasonZeroDisplayName"
        case metadataSavers = "MetadataSavers"
        case disabledLocalMetadataReaders = "DisabledLocalMetadataReaders"
        case localMetadataReaderOrder = "LocalMetadataReaderOrder"
        case disabledSubtitleFetchers = "DisabledSubtitleFetchers"
        case subtitleFetcherOrder = "SubtitleFetcherOrder"
        case skipSubtitlesIfEmbeddedSubtitlesPresent = "SkipSubtitlesIfEmbeddedSubtitlesPresent"
        case skipSubtitlesIfAudioTrackMatches = "SkipSubtitlesIfAudioTrackMatches"
        case subtitleDownloadLanguages = "SubtitleDownloadLanguages"
        case requirePerfectSubtitleMatch = "RequirePerfectSubtitleMatch"
        case saveSubtitlesWithMedia = "SaveSubtitlesWithMedia"
        case saveLyricsWithMedia = "SaveLyricsWithMedia"
        case automaticallyAddToCollection = "AutomaticallyAddToCollection"
        case allowEmbeddedSubtitles = "AllowEmbeddedSubtitles"
        case pathInfos = "PathInfos"
        case typeOptions = "TypeOptions"
    }
}

extension JellyfinLibraryOptions {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enablePhotos = try c.decodeIfPresent(Bool.self, forKey: .enablePhotos) ?? d.enablePhotos
        enableRealtimeMonitor = try c.decodeIfPresent(Bool.self, forKey: .enableRealtimeMonitor) ?? d.enableRealtimeMonitor
        enableLUFSScan = try c.decodeIfPresent(Bool.self, forKey: .enableLUFSScan) ?? d.enableLUFSScan
        enableChapterImageExtraction = try c.decodeIfPresent(Bool.self, forKey: .enableChapterImageExtraction) ?? d.enableChapterImageExtraction
        extractChapterImagesDuringLibraryScan = try c.decodeIfPresent(Bool.self, forKey: .extractChapterImagesDuringLibraryScan) ?? d.extractChapterImagesDuringLibraryScan
        enableTrickplayImageExtraction = try c.decodeIfPresent(Bool.self, forKey: .enableTrickplayImageExtraction) ?? d.enableTrickplayImageExtraction
        extractTrickplayImagesDuringLibraryScan = try c.decodeIfPresent(Bool.self, forKey: .extractTrickplayImagesDuringLibraryScan) ?? d.extractTrickplayImagesDuringLibraryScan
        saveTrickplayWithMedia = try c.decodeIfPresent(Bool.self, forKey: .saveTrickplayWithMedia) ?? d.saveTrickplayWithMedia
        saveLocalMetadata = try c.decodeIfPresent(Bool.self, forKey: .saveLocalMetadata) ?? d.saveLocalMetadata
        enableInternetProviders = try c.decodeIfPresent(Bool.self, forKey: .enableInternetProviders) ?? d.enableInternetProviders
        enableAutomaticSeriesGrouping = try c.decodeIfPresent(Bool.self, forKey: .enableAutomaticSeriesGrouping) ?? d.enableAutomaticSeriesGrouping
        enableEmbeddedTitles = try c.decodeIfPresent(Bool.self, forKey: .enableEmbeddedTitles) ?? d.enableEmbeddedTitles
        enableEmbeddedExtrasTitles = try c.decodeIfPresent(Bool.self, forKey: .enableEmbeddedExtrasTitles) ?? d.enableEmbeddedExtrasTitles
        enableEmbeddedEpisodeInfos = try c.decodeIfPresent(Bool.self, forKey: .enableEmbeddedEpisodeInfos) ?? d.enableEmbeddedEpisodeInfos
        automaticRefreshIntervalDays = try c.decodeIfPresent(Int.self, forKey: .automaticRefreshIntervalDays) ?? d.automaticRefreshIntervalDays
        preferredMetadataLanguage = try c.decodeIfPresent(String.self, forKey: .preferredMetadataLanguage) ?? d.preferredMetadataLanguage
        metadataCountryCode = try c.decodeIfPresent(String.self, forKey: .metadataCountryCode) ?? d.metadataCountryCode
        seasonZeroDisplayName = try c.decodeIfPresent(String.self, forKey: .seasonZeroDisplayName) ?? d.seasonZeroDisplayName
        metadataSavers = try c.decodeIfPresent([String].self, forKey: .metadataSavers) ?? d.metadataSavers
        disabledLocalMetadataReaders = try c.decodeIfPresent([String].self, forKey: .disabledLocalMetadataReaders) ?? d.disabledLocalMetadataReaders
        localMetadataReaderOrder = try c.decodeIfPresent([String].self, forKey: .localMetadataReaderOrder) ?? d.localMetadataReaderOrder
        disabledSubtitleFetchers = try c.decodeIfPresent([String].self, forKey: .disabledSubtitleFetchers) ?? d.disabledSubtitleFetchers
        subtitleFetcherOrder = try c.decodeIfPresent([String].self, forKey: .subtitleFetcherOrder) ?? d.subtitleFetcherOrder
        skipSubtitlesIfEmbeddedSubtitlesPresent = try c.decodeIfPresent(Bool.self, forKey: .skipSubtitlesIfEmbeddedSubtitlesPresent) ?? d.skipSubtitlesIfEmbeddedSubtitlesPresent
        skipSubtitlesIfAudioTrackMatches = try c.decodeIfPresent(Bool.self, forKey: .skipSubtitlesIfAudioTrackMatches) ?? d.skipSubtitlesIfAudioTrackMatches
        subtitleDownloadLanguages = try c.decodeIfPresent([String].self, forKey: .subtitleDownloadLanguages) ?? d.subtitleDownloadLanguages
        requirePerfectSubtitleMatch = try c.decodeIfPresent(Bool.self, forKey: .requirePerfectSubtitleMatch) ?? d.requirePerfectSubtitleMatch
        saveSubtitlesWithMedia = try c.decodeIfPresent(Bool.self, forKey: .saveSubtitlesWithMedia) ?? d.saveSubtitlesWithMedia
        saveLyricsWithMedia = try c.decodeIfPresent(Bool.self, forKey: .saveLyricsWithMedia) ?? d.saveLyricsWithMedia
        automaticallyAddToCollection = try c.decodeIfPresent(Bool.self, forKey: .automaticallyAddToCollection) ?? d.automaticallyAddToCollection
        allowEmbeddedSubtitles = try c.decodeIfPresent(String.self, forKey: .allowEmbeddedSubtitles) ?? d.allowEmbeddedSubtitles
        pathInfos = try c.decodeIfPresent([JellyfinLibraryPathInfo].self, forKey: .pathInfos) ?? d.pathInfos
        typeOptions = try c.decodeIfPresent([JellyfinTypeOptions].self, forKey: .typeOptions) ?? d.typeOptions
    }
}

// MARK: - Embedded subtitle policy

nonisolated enum JellyfinEmbeddedSubtitleOption: String, CaseIterable, Identifiable, Sendable {
    case allowAll = "AllowAll"
    case allowText = "AllowText"
    case allowImage = "AllowImage"
    case allowNone = "AllowNone"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allowAll: "Allow All"
        case .allowText: "Text Only"
        case .allowImage: "Image Only"
        case .allowNone: "None"
        }
    }
}

// MARK: - Media path info

nonisolated struct JellyfinLibraryPathInfo: Codable, Sendable, Equatable {
    var path: String = ""
    var networkPath: String?

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case networkPath = "NetworkPath"
    }
}

extension JellyfinLibraryPathInfo {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        networkPath = try c.decodeIfPresent(String.self, forKey: .networkPath)
    }
}

// MARK: - Per content-type options

nonisolated struct JellyfinTypeOptions: Codable, Sendable, Equatable, Identifiable {
    var type: String = ""
    var metadataFetchers: [String] = []
    var metadataFetcherOrder: [String] = []
    var imageFetchers: [String] = []
    var imageFetcherOrder: [String] = []
    var imageOptions: [JellyfinImageOption] = []

    var id: String { type }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case metadataFetchers = "MetadataFetchers"
        case metadataFetcherOrder = "MetadataFetcherOrder"
        case imageFetchers = "ImageFetchers"
        case imageFetcherOrder = "ImageFetcherOrder"
        case imageOptions = "ImageOptions"
    }

    /// "Movie" -> "Movies", "Series" -> "TV Shows", etc.
    var displayName: String {
        switch type {
        case "Movie": "Movies"
        case "Series": "TV Shows"
        case "Season": "Seasons"
        case "Episode": "Episodes"
        case "MusicAlbum": "Albums"
        case "MusicArtist": "Artists"
        case "Audio": "Songs"
        case "MusicVideo": "Music Videos"
        case "Book": "Books"
        case "BoxSet": "Collections"
        case "Trailer": "Trailers"
        default: type
        }
    }

    var systemImage: String {
        switch type {
        case "Movie", "Trailer": "film"
        case "Series", "Season", "Episode": "tv"
        case "MusicAlbum", "MusicArtist", "Audio": "music.note"
        case "MusicVideo": "music.note.tv"
        case "Book": "book"
        case "BoxSet": "rectangle.stack"
        default: "square.grid.2x2"
        }
    }
}

extension JellyfinTypeOptions {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        metadataFetchers = try c.decodeIfPresent([String].self, forKey: .metadataFetchers) ?? []
        metadataFetcherOrder = try c.decodeIfPresent([String].self, forKey: .metadataFetcherOrder) ?? []
        imageFetchers = try c.decodeIfPresent([String].self, forKey: .imageFetchers) ?? []
        imageFetcherOrder = try c.decodeIfPresent([String].self, forKey: .imageFetcherOrder) ?? []
        imageOptions = try c.decodeIfPresent([JellyfinImageOption].self, forKey: .imageOptions) ?? []
    }
}

nonisolated struct JellyfinImageOption: Codable, Sendable, Equatable {
    var type: String = ""
    var limit: Int = 1
    var minWidth: Int = 0

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case limit = "Limit"
        case minWidth = "MinWidth"
    }
}

extension JellyfinImageOption {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 1
        minWidth = try c.decodeIfPresent(Int.self, forKey: .minWidth) ?? 0
    }
}

// MARK: - Available options (GET /Libraries/AvailableOptions)

nonisolated struct JellyfinAvailableLibraryOptions: Decodable, Sendable {
    var metadataSavers: [JellyfinLibraryOptionInfo] = []
    var metadataReaders: [JellyfinLibraryOptionInfo] = []
    var subtitleFetchers: [JellyfinLibraryOptionInfo] = []
    var typeOptions: [JellyfinAvailableTypeOptions] = []

    enum CodingKeys: String, CodingKey {
        case metadataSavers = "MetadataSavers"
        case metadataReaders = "MetadataReaders"
        case subtitleFetchers = "SubtitleFetchers"
        case typeOptions = "TypeOptions"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadataSavers = try c.decodeIfPresent([JellyfinLibraryOptionInfo].self, forKey: .metadataSavers) ?? []
        metadataReaders = try c.decodeIfPresent([JellyfinLibraryOptionInfo].self, forKey: .metadataReaders) ?? []
        subtitleFetchers = try c.decodeIfPresent([JellyfinLibraryOptionInfo].self, forKey: .subtitleFetchers) ?? []
        typeOptions = try c.decodeIfPresent([JellyfinAvailableTypeOptions].self, forKey: .typeOptions) ?? []
    }

    func typeOptions(for type: String) -> JellyfinAvailableTypeOptions? {
        typeOptions.first { $0.type == type }
    }
}

nonisolated struct JellyfinLibraryOptionInfo: Decodable, Sendable, Identifiable, Equatable {
    var name: String = ""
    var defaultEnabled: Bool = true

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case defaultEnabled = "DefaultEnabled"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        defaultEnabled = try c.decodeIfPresent(Bool.self, forKey: .defaultEnabled) ?? true
    }
}

nonisolated struct JellyfinAvailableTypeOptions: Decodable, Sendable {
    var type: String = ""
    var metadataFetchers: [JellyfinLibraryOptionInfo] = []
    var imageFetchers: [JellyfinLibraryOptionInfo] = []

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case metadataFetchers = "MetadataFetchers"
        case imageFetchers = "ImageFetchers"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        metadataFetchers = try c.decodeIfPresent([JellyfinLibraryOptionInfo].self, forKey: .metadataFetchers) ?? []
        imageFetchers = try c.decodeIfPresent([JellyfinLibraryOptionInfo].self, forKey: .imageFetchers) ?? []
    }
}

// MARK: - Update body (POST /Library/VirtualFolders/LibraryOptions)

nonisolated struct JellyfinUpdateLibraryOptionsBody: Encodable, Sendable {
    let id: String
    let libraryOptions: JellyfinLibraryOptions

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case libraryOptions = "LibraryOptions"
    }
}
