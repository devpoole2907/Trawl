import Foundation

// MARK: - Indexer

nonisolated struct ProwlarrIndexer: Codable, Identifiable, Sendable {
    let id: Int
    var name: String?
    var enable: Bool
    let implementation: String?
    let implementationName: String?
    let configContract: String?
    let infoLink: String?
    var tags: [Int]?
    var priority: Int?
    let appProfileId: Int?
    let shouldSearch: Bool?
    let supportsRss: Bool?
    let supportsSearch: Bool?
    let `protocol`: ProwlarrIndexerProtocol?
    let fields: [ProwlarrIndexerField]?
    private let _schemaListID: String

    init(
        id: Int,
        name: String?,
        enable: Bool,
        implementation: String?,
        implementationName: String?,
        configContract: String?,
        infoLink: String?,
        tags: [Int]?,
        priority: Int?,
        appProfileId: Int?,
        shouldSearch: Bool?,
        supportsRss: Bool?,
        supportsSearch: Bool?,
        protocol: ProwlarrIndexerProtocol?,
        fields: [ProwlarrIndexerField]?
    ) {
        self.id = id
        self.name = name
        self.enable = enable
        self.implementation = implementation
        self.implementationName = implementationName
        self.configContract = configContract
        self.infoLink = infoLink
        self.tags = tags
        self.priority = priority
        self.appProfileId = appProfileId
        self.shouldSearch = shouldSearch
        self.supportsRss = supportsRss
        self.supportsSearch = supportsSearch
        self.protocol = `protocol`
        self.fields = fields
        self._schemaListID = ProwlarrIndexer.computeSchemaListID(id: id, implementation: implementation, configContract: configContract, implementationName: implementationName, name: name)
    }

    // Schema endpoint omits `id` and `enable` for template entries.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        implementation = try c.decodeIfPresent(String.self, forKey: .implementation)
        implementationName = try c.decodeIfPresent(String.self, forKey: .implementationName)
        configContract = try c.decodeIfPresent(String.self, forKey: .configContract)
        infoLink = try c.decodeIfPresent(String.self, forKey: .infoLink)
        tags = try c.decodeIfPresent([Int].self, forKey: .tags)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        appProfileId = try c.decodeIfPresent(Int.self, forKey: .appProfileId)
        shouldSearch = try c.decodeIfPresent(Bool.self, forKey: .shouldSearch)
        supportsRss = try c.decodeIfPresent(Bool.self, forKey: .supportsRss)
        supportsSearch = try c.decodeIfPresent(Bool.self, forKey: .supportsSearch)
        let protocolValue = try c.decodeIfPresent(String.self, forKey: .protocol)
        `protocol` = protocolValue.flatMap(ProwlarrIndexerProtocol.init(rawValue:))
        fields = try c.decodeIfPresent([ProwlarrIndexerField].self, forKey: .fields)
        _schemaListID = ProwlarrIndexer.computeSchemaListID(id: id, implementation: implementation, configContract: configContract, implementationName: implementationName, name: name)
    }

    var schemaListID: String { _schemaListID }

    private static func computeSchemaListID(id: Int, implementation: String?, configContract: String?, implementationName: String?, name: String?) -> String {
        if id != 0 { return "indexer-\(id)" }
        let components = [
            implementation,
            configContract,
            implementationName,
            name
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        return components.isEmpty ? "template-unknown-\(UUID().uuidString)" : "template-" + components.joined(separator: "::")
    }
}

nonisolated enum ProwlarrIndexerProtocol: String, Codable, Sendable {
    case usenet = "usenet"
    case torrent = "torrent"

    var displayName: String {
        switch self {
        case .usenet: "Usenet"
        case .torrent: "Torrent"
        }
    }

    var isTorrent: Bool { self == .torrent }

    var systemImage: String {
        switch self {
        case .torrent: "arrow.down.circle"
        case .usenet: "envelope.circle"
        }
    }
}

nonisolated struct ProwlarrIndexerField: Codable, Sendable {
    let name: String?
    let label: String?
    let value: AnyCodableValue?
    let type: String?
    let advanced: Bool?
    let hidden: String?
    let selectOptions: [ProwlarrSelectOption]?
}

nonisolated struct ProwlarrSelectOption: Codable, Identifiable, Sendable {
    let name: String?
    let value: AnyCodableValue?
    let order: Int?
    let hint: String?

    var id: String {
        if let value, let display = value.displayString { return "val-\(display)" }
        return "opt-\(name ?? "")-\(order ?? 0)"
    }
}

/// Type-erased JSON value for indexer config fields
nonisolated enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v) }
        else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var displayString: String? {
        switch self {
        case .string(let v): return v.isEmpty ? nil : v.strippingHTML
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "Yes" : "No"
        case .array(let v): return v.isEmpty ? nil : v.compactMap(\.displayString).joined(separator: ", ")
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        default: return nil
        }
    }
}

private extension String {
    nonisolated var strippingHTML: String {
        var s = self
        // Block elements → newline
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // Strip all remaining tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Common HTML entities
        s = s.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
        // Collapse multiple blank lines
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Search

nonisolated enum ProwlarrSearchType: String, CaseIterable, Identifiable, Sendable {
    case search
    case tvsearch
    case moviesearch
    case audiosearch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .search: "All"
        case .tvsearch: "TV"
        case .moviesearch: "Movies"
        case .audiosearch: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .tvsearch: "tv"
        case .moviesearch: "film"
        case .audiosearch: "music.note"
        }
    }
}

nonisolated struct ProwlarrSearchResult: Codable, Identifiable, Sendable {
    let guid: String?
    let title: String?
    let indexerId: Int?
    let indexer: String?
    let size: Int64?
    let seeders: Int?
    let leechers: Int?
    let categories: [ProwlarrCategory]?
    let downloadUrl: String?
    let infoUrl: String?
    let publishDate: String?
    let grabs: Int?
    let files: Int?
    let downloadVolumeFactor: Double?
    let uploadVolumeFactor: Double?
    let `protocol`: ProwlarrIndexerProtocol?
    private let _id: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guid = try c.decodeIfPresent(String.self, forKey: .guid)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        indexerId = try c.decodeIfPresent(Int.self, forKey: .indexerId)
        indexer = try c.decodeIfPresent(String.self, forKey: .indexer)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        seeders = try c.decodeIfPresent(Int.self, forKey: .seeders)
        leechers = try c.decodeIfPresent(Int.self, forKey: .leechers)
        categories = try c.decodeIfPresent([ProwlarrCategory].self, forKey: .categories)
        downloadUrl = try c.decodeIfPresent(String.self, forKey: .downloadUrl)
        infoUrl = try c.decodeIfPresent(String.self, forKey: .infoUrl)
        publishDate = try c.decodeIfPresent(String.self, forKey: .publishDate)
        grabs = try c.decodeIfPresent(Int.self, forKey: .grabs)
        files = try c.decodeIfPresent(Int.self, forKey: .files)
        downloadVolumeFactor = try c.decodeIfPresent(Double.self, forKey: .downloadVolumeFactor)
        uploadVolumeFactor = try c.decodeIfPresent(Double.self, forKey: .uploadVolumeFactor)
        let protocolValue = try c.decodeIfPresent(String.self, forKey: .protocol)
        `protocol` = protocolValue.flatMap(ProwlarrIndexerProtocol.init(rawValue:))
        _id = ProwlarrSearchResult.computeID(guid: guid, indexerId: indexerId, title: title, downloadUrl: downloadUrl, infoUrl: infoUrl, publishDate: publishDate, size: size, seeders: seeders, leechers: leechers)
    }

    private enum CodingKeys: String, CodingKey {
        case guid, title, indexerId, indexer, size, seeders, leechers, categories
        case downloadUrl, infoUrl, publishDate, grabs, files
        case downloadVolumeFactor, uploadVolumeFactor
        case `protocol`
    }

    var id: String { _id }

    private static func computeID(guid: String?, indexerId: Int?, title: String?, downloadUrl: String?, infoUrl: String?, publishDate: String?, size: Int64?, seeders: Int?, leechers: Int?) -> String {
        if let guid = guid, !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return guid
        }
        let components = [
            normalizedIDComponent(indexerId.map(String.init)),
            normalizedIDComponent(title),
            normalizedIDComponent(downloadUrl ?? infoUrl),
            normalizedIDComponent(publishDate),
            normalizedIDComponent(size.map(String.init)),
            normalizedIDComponent(seeders.map(String.init)),
            normalizedIDComponent(leechers.map(String.init))
        ]
        .compactMap { $0 }

        return components.isEmpty ? "search-result-unknown-\(UUID().uuidString)" : "search-result-" + components.joined(separator: "|")
    }

    var isFreeleech: Bool { downloadVolumeFactor == 0.0 }

    var isTorrent: Bool { `protocol` == .torrent }

    var isMagnet: Bool {
        guard let url = downloadUrl else { return false }
        return url.lowercased().hasPrefix("magnet:")
    }

    var ageDescription: String? {
        guard let publishDate else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()

        let date =
            fractionalFormatter.date(from: publishDate) ??
            fallbackFormatter.date(from: publishDate)

        guard let date else { return nil }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: Date())
        if let days = components.day, days > 0 {
            return days == 1 ? "1d ago" : "\(days)d ago"
        }
        if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        }
        if let minutes = components.minute, minutes > 0 {
            return minutes == 1 ? "1m ago" : "\(minutes)m ago"
        }
        return "Just now"
    }

    private static func normalizedIDComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? trimmed
    }
}

nonisolated struct ProwlarrCategory: Codable, Sendable {
    let id: Int?
    let name: String?
}

// MARK: - Indexer Stats

nonisolated struct ProwlarrIndexerStats: Codable, Sendable {
    let indexers: [ProwlarrIndexerStatEntry]?
}

nonisolated struct ProwlarrIndexerStatEntry: Codable, Identifiable, Sendable {
    let indexerId: Int?
    let indexerName: String?
    let averageResponseTime: Double?
    let numberOfQueries: Int?
    let numberOfGrabs: Int?
    let numberOfRssQueries: Int?
    let numberOfAuthQueries: Int?
    let numberOfFailedQueries: Int?
    let numberOfFailedGrabs: Int?
    let numberOfFailedRssQueries: Int?
    let numberOfFailedAuthQueries: Int?

    var id: String {
        if let indexerId {
            return "indexer-\(indexerId)"
        } else {
            return "indexer-unknown-\(indexerName ?? "unnamed")"
        }
    }

    var successRate: Double? {
        guard let total = numberOfQueries, total > 0, let failed = numberOfFailedQueries else { return nil }
        return Double(total - failed) / Double(total)
    }

    var avgResponseTimeFormatted: String? {
        guard let ms = averageResponseTime else { return nil }
        return String(format: "%.0fms", ms)
    }
}

// MARK: - Indexer Status

nonisolated struct ProwlarrIndexerStatus: Codable, Identifiable, Sendable {
    let id: Int
    let indexerId: Int?
    let disabledTill: String?
    let lastRssSyncReleaseDate: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        indexerId = try c.decodeIfPresent(Int.self, forKey: .indexerId)
        disabledTill = try c.decodeIfPresent(String.self, forKey: .disabledTill)
        lastRssSyncReleaseDate = try c.decodeIfPresent(String.self, forKey: .lastRssSyncReleaseDate)
    }

    var stableID: String {
        if id != 0 { return "status-\(id)" }
        return "status-indexer-\(indexerId ?? 0)"
    }

    var isDisabled: Bool {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()

        guard let disabledTill,
              let date = fractionalFormatter.date(from: disabledTill) ??
                  fallbackFormatter.date(from: disabledTill) else { return false }
        return date > Date()
    }
}
