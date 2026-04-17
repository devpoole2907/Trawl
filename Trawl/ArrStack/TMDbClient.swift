import Foundation

/// Lightweight TMDb API client for fetching trending content.
/// Uses TMDb API v3 trending endpoints.
actor TMDbClient {
    private let apiKey: String
    private let session: URLSession
    private static let baseURL = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p"

    init(apiKey: String) {
        self.apiKey = apiKey
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

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var components = URLComponents(string: "\(Self.baseURL)\(path)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TMDbError.requestFailed
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Models

struct TMDbPage: Decodable, Sendable {
    let results: [TMDbItem]
}

struct TMDbItem: Decodable, Identifiable, Sendable {
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
    case requestFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .requestFailed: "TMDb request failed."
        case .noAPIKey: "No TMDb API key configured."
        }
    }
}
