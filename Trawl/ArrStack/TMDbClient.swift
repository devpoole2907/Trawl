import Foundation

/// Lightweight TMDb client that proxies requests through the Trawl worker.
/// The worker holds the API key and caches responses for one hour.
actor TMDbClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private static let baseURL = "https://trawl-apns-worker.james-5d8.workers.dev/tmdb"
    static let imageBase = "https://image.tmdb.org/t/p"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Trending

    func trendingMovies() async throws -> [TMDbItem] {
        let result: TMDbPage = try await get("/trending/movie/week")
        return result.results
    }

    func trendingTV() async throws -> [TMDbItem] {
        let result: TMDbPage = try await get("/trending/tv/week")
        return result.results
    }

    func tvExternalIds(tmdbId: Int) async throws -> TMDbExternalIds {
        try await get("/tv/\(tmdbId)/external_ids")
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(Self.baseURL)\(path)") else {
            throw TMDbError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TMDbError.requestFailed(statusCode: 0, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw TMDbError.requestFailed(statusCode: http.statusCode, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDbError.decodingFailed(error)
        }
    }
}

// MARK: - Models

nonisolated struct TMDbExternalIds: Decodable, Sendable {
    let tvdbId: Int?

    enum CodingKeys: String, CodingKey {
        case tvdbId = "tvdb_id"
    }
}

nonisolated struct TMDbPage: Decodable, Sendable {
    let results: [TMDbItem]
}

nonisolated struct TMDbItem: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String?          // movies
    let name: String?           // tv
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let voteAverage: Double?
    let releaseDate: String?    // movies
    let firstAirDate: String?   // tv
    let mediaType: String?      // "movie" or "tv"
    let genreIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case mediaType = "media_type"
        case genreIds = "genre_ids"
    }

    var displayTitle: String { title ?? name ?? "Unknown" }

    var year: String? {
        let date = releaseDate ?? firstAirDate
        guard let date, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    var isMovie: Bool { mediaType == "movie" }

    func posterURL(size: String = "w342") -> URL? {
        guard let path = posterPath else { return nil }
        return URL(string: "\(TMDbClient.imageBase)/\(size)\(path)")
    }

    func backdropURL(size: String = "w780") -> URL? {
        guard let path = backdropPath else { return nil }
        return URL(string: "\(TMDbClient.imageBase)/\(size)\(path)")
    }
}

enum TMDbError: LocalizedError {
    case requestFailed(statusCode: Int, body: String?)
    case invalidURL
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let body):
            "TMDb request failed (\(statusCode)): \(body ?? "Unknown error")"
        case .invalidURL:
            "Invalid TMDb URL."
        case .decodingFailed(let error):
            "Failed to decode TMDb response: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
extension TMDbClient {
    static func preview() -> TMDbClient {
        TMDbClient()
    }
}
#endif
