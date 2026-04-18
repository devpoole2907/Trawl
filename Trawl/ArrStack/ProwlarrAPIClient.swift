import Foundation

/// Prowlarr-specific API methods. Wraps ArrAPIClient.
/// Prowlarr uses /api/v1/ (not /api/v3/ like Sonarr/Radarr).
actor ProwlarrAPIClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String) {
        self.base = ArrAPIClient(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - System

    func getSystemStatus() async throws -> ArrSystemStatus {
        try await base.get("/api/v1/system/status")
    }

    func getHealth() async throws -> [ArrHealthCheck] {
        try await base.get("/api/v1/health")
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

    // MARK: - Tags

    func getTags() async throws -> [ArrTag] {
        try await base.get("/api/v1/tag")
    }
}
