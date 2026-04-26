import Foundation

/// Prowlarr-specific API methods. Wraps ArrAPIClient.
/// Prowlarr uses /api/v1/ (not /api/v3/ like Sonarr/Radarr).
actor ProwlarrAPIClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        self.base = ArrAPIClient(baseURL: baseURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
    }

    // MARK: - System

    func getSystemStatus() async throws -> ArrSystemStatus {
        try await base.get("/api/v1/system/status")
    }

    func getHealth() async throws -> [ArrHealthCheck] {
        try await base.get("/api/v1/health")
    }

    func getQualityProfiles() async throws -> [ArrQualityProfile] {
        try await base.get("/api/v1/qualityprofile")
    }

    func getRootFolders() async throws -> [ArrRootFolder] {
        try await base.get("/api/v1/rootfolder")
    }

    func getQueue(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize,
        includeUnknownMovieItems: Bool = true
    ) async throws -> ArrQueuePage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeUnknownMovieItems", value: String(includeUnknownMovieItems)),
            URLQueryItem(name: "includeUnknownSeriesItems", value: "true")
        ]
        return try await base.get("/api/v1/queue", queryItems: params)
    }

    func getHistory(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize,
        sortKey: String = "date",
        sortDirection: String = "descending"
    ) async throws -> ArrHistoryPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection)
        ]
        return try await base.get("/api/v1/history", queryItems: params)
    }

    func getDiskSpace() async throws -> [ArrDiskSpace] {
        try await base.get("/api/v1/diskspace")
    }

    // MARK: - Indexers

    func getIndexers() async throws -> [ProwlarrIndexer] {
        try await base.get("/api/v1/indexer")
    }

    func getIndexer(id: Int) async throws -> ProwlarrIndexer {
        try await base.get("/api/v1/indexer/\(id)")
    }

    func deleteIndexer(id: Int) async throws {
        try await base.delete("/api/v1/indexer/\(id)")
    }

    func updateIndexer(_ indexer: ProwlarrIndexer) async throws -> ProwlarrIndexer {
        try await base.putCodable("/api/v1/indexer/\(indexer.id)", body: indexer)
    }

    func getIndexerSchema() async throws -> [ProwlarrIndexer] {
        try await base.get("/api/v1/indexer/schema")
    }

    func createIndexer(_ indexer: ProwlarrIndexer) async throws -> ProwlarrIndexer {
        try await base.postCodable("/api/v1/indexer", body: indexer)
    }

    func testIndexer(_ indexer: ProwlarrIndexer) async throws {
        try await base.postVoidCodable("/api/v1/indexer/test", body: indexer)
    }

    func testAllIndexers() async throws {
        try await base.postVoid("/api/v1/indexer/testall", jsonBody: [:])
    }

    // MARK: - Search

    func search(
        query: String,
        indexerIds: [Int]? = nil,
        type: ProwlarrSearchType = .search,
        categories: [Int]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> [ProwlarrSearchResult] {
        var params: [URLQueryItem] = []
        if !query.isEmpty { params.append(.init(name: "query", value: query)) }
        params.append(.init(name: "type", value: type.rawValue))
        if let ids = indexerIds, !ids.isEmpty {
            for id in ids { params.append(.init(name: "indexerIds", value: String(id))) }
        }
        if let cats = categories, !cats.isEmpty {
            for cat in cats { params.append(.init(name: "categories", value: String(cat))) }
        }
        if let limit { params.append(.init(name: "limit", value: String(limit))) }
        if let offset { params.append(.init(name: "offset", value: String(offset))) }
        return try await base.get("/api/v1/search", queryItems: params)
    }

    // MARK: - Stats & Status

    func getIndexerStats(startDate: Date? = nil, endDate: Date? = nil) async throws -> ProwlarrIndexerStats {
        var params: [URLQueryItem] = []
        let formatter = ISO8601DateFormatter()
        if let start = startDate { params.append(.init(name: "startDate", value: formatter.string(from: start))) }
        if let end = endDate { params.append(.init(name: "endDate", value: formatter.string(from: end))) }
        return try await base.get("/api/v1/indexerstats", queryItems: params)
    }

    func getIndexerStatuses() async throws -> [ProwlarrIndexerStatus] {
        try await base.get("/api/v1/indexerstatus")
    }

    // MARK: - Applications

    func getApplications() async throws -> [ProwlarrApplication] {
        try await base.get("/api/v1/applications")
    }

    func getApplicationSchema() async throws -> [ProwlarrApplication] {
        try await base.get("/api/v1/applications/schema")
    }

    func createApplication(_ application: ProwlarrApplication) async throws -> ProwlarrApplication {
        try await base.postCodable("/api/v1/applications", body: application)
    }

    func updateApplication(_ application: ProwlarrApplication) async throws -> ProwlarrApplication {
        try await base.putCodable("/api/v1/applications/\(application.id)", body: application)
    }

    func deleteApplication(id: Int) async throws {
        try await base.delete("/api/v1/applications/\(id)")
    }

    func testApplication(_ application: ProwlarrApplication) async throws {
        try await base.postVoidCodable("/api/v1/applications/test", body: application)
    }

    // MARK: - Tags

    func getTags() async throws -> [ArrTag] {
        try await base.get("/api/v1/tag")
    }
}
