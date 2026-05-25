import Foundation

/// Decoded representation of a qBittorrent RSS auto-download rule.
///
/// `torrentParams` is preserved as opaque JSON so newer qBittorrent payloads round-trip
/// untouched even though the editor doesn't surface those fields.
struct QBittorrentRSSRule: Codable, Sendable {
    var enabled: Bool
    var mustContain: String
    var mustNotContain: String
    var useRegex: Bool
    var episodeFilter: String
    var smartFilter: Bool
    var previouslyMatchedEpisodes: [String]
    var affectedFeeds: [String]
    var ignoreDays: Int
    var lastMatch: String
    var addPaused: Bool?
    var assignedCategory: String
    var savePath: String
    var torrentContentLayout: String?
    var torrentParams: JSONValue?

    init(
        enabled: Bool = true,
        mustContain: String = "",
        mustNotContain: String = "",
        useRegex: Bool = false,
        episodeFilter: String = "",
        smartFilter: Bool = false,
        previouslyMatchedEpisodes: [String] = [],
        affectedFeeds: [String] = [],
        ignoreDays: Int = 0,
        lastMatch: String = "",
        addPaused: Bool? = nil,
        assignedCategory: String = "",
        savePath: String = "",
        torrentContentLayout: String? = nil,
        torrentParams: JSONValue? = nil
    ) {
        self.enabled = enabled
        self.mustContain = mustContain
        self.mustNotContain = mustNotContain
        self.useRegex = useRegex
        self.episodeFilter = episodeFilter
        self.smartFilter = smartFilter
        self.previouslyMatchedEpisodes = previouslyMatchedEpisodes
        self.affectedFeeds = affectedFeeds
        self.ignoreDays = ignoreDays
        self.lastMatch = lastMatch
        self.addPaused = addPaused
        self.assignedCategory = assignedCategory
        self.savePath = savePath
        self.torrentContentLayout = torrentContentLayout
        self.torrentParams = torrentParams
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mustContain
        case mustNotContain
        case useRegex
        case episodeFilter
        case smartFilter
        case previouslyMatchedEpisodes
        case affectedFeeds
        case ignoreDays
        case lastMatch
        case addPaused
        case assignedCategory
        case savePath
        case torrentContentLayout
        case torrentParams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.mustContain = try container.decodeIfPresent(String.self, forKey: .mustContain) ?? ""
        self.mustNotContain = try container.decodeIfPresent(String.self, forKey: .mustNotContain) ?? ""
        self.useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        self.episodeFilter = try container.decodeIfPresent(String.self, forKey: .episodeFilter) ?? ""
        self.smartFilter = try container.decodeIfPresent(Bool.self, forKey: .smartFilter) ?? false
        self.previouslyMatchedEpisodes = try container.decodeIfPresent([String].self, forKey: .previouslyMatchedEpisodes) ?? []
        self.affectedFeeds = try container.decodeIfPresent([String].self, forKey: .affectedFeeds) ?? []
        self.ignoreDays = try container.decodeIfPresent(Int.self, forKey: .ignoreDays) ?? 0
        self.lastMatch = try container.decodeIfPresent(String.self, forKey: .lastMatch) ?? ""
        self.addPaused = try container.decodeIfPresent(Bool.self, forKey: .addPaused)
        self.assignedCategory = try container.decodeIfPresent(String.self, forKey: .assignedCategory) ?? ""
        self.savePath = try container.decodeIfPresent(String.self, forKey: .savePath) ?? ""
        self.torrentContentLayout = try container.decodeIfPresent(String.self, forKey: .torrentContentLayout)
        self.torrentParams = try container.decodeIfPresent(JSONValue.self, forKey: .torrentParams)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mustContain, forKey: .mustContain)
        try container.encode(mustNotContain, forKey: .mustNotContain)
        try container.encode(useRegex, forKey: .useRegex)
        try container.encode(episodeFilter, forKey: .episodeFilter)
        try container.encode(smartFilter, forKey: .smartFilter)
        try container.encode(previouslyMatchedEpisodes, forKey: .previouslyMatchedEpisodes)
        try container.encode(affectedFeeds, forKey: .affectedFeeds)
        try container.encode(ignoreDays, forKey: .ignoreDays)
        try container.encode(lastMatch, forKey: .lastMatch)
        try container.encode(assignedCategory, forKey: .assignedCategory)
        try container.encode(savePath, forKey: .savePath)
        // Tri-state fields: emit explicit null so qBittorrent treats absence vs. default
        // consistently with the WebUI behaviour.
        if let addPaused {
            try container.encode(addPaused, forKey: .addPaused)
        } else {
            try container.encodeNil(forKey: .addPaused)
        }
        if let torrentContentLayout {
            try container.encode(torrentContentLayout, forKey: .torrentContentLayout)
        } else {
            try container.encodeNil(forKey: .torrentContentLayout)
        }
        try container.encodeIfPresent(torrentParams, forKey: .torrentParams)
    }
}
