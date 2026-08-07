import Foundation

// MARK: - Movie/TV Credits

nonisolated struct TMDbCredits: Decodable, Sendable {
    let cast: [TMDbCastMember]?
    let crew: [TMDbCrewMember]?
}

nonisolated struct TMDbCastMember: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let character: String?
    let profilePath: String?
    let order: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, character, order
        case profilePath = "profile_path"
    }

    func profileURL(size: String = "w185") -> URL? {
        guard let path = profilePath else { return nil }
        return URL(string: "\(TMDbClient.imageBase)/\(size)\(path)")
    }
}

nonisolated struct TMDbCrewMember: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let job: String?
    let department: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job, department
        case profilePath = "profile_path"
    }

    func profileURL(size: String = "w185") -> URL? {
        guard let path = profilePath else { return nil }
        return URL(string: "\(TMDbClient.imageBase)/\(size)\(path)")
    }
}

// MARK: - Person

nonisolated struct TMDbPersonDetail: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let knownForDepartment: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, deathday
        case placeOfBirth = "place_of_birth"
        case knownForDepartment = "known_for_department"
        case profilePath = "profile_path"
    }

    func profileURL(size: String = "h632") -> URL? {
        guard let path = profilePath else { return nil }
        return URL(string: "\(TMDbClient.imageBase)/\(size)\(path)")
    }
}

nonisolated struct TMDbPersonCombinedCredits: Decodable, Sendable {
    let cast: [TMDbPersonCredit]?
    let crew: [TMDbPersonCredit]?
}

nonisolated struct TMDbPersonCredit: Decodable, Identifiable, Sendable {
    let id: Int
    let mediaType: String?      // "media_type"
    let title: String?          // movies
    let name: String?           // tv
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let character: String?
    let job: String?
    let voteAverage: Double?
    let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, character, job
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case popularity
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
}

// MARK: - Find

nonisolated struct TMDbFindResults: Decodable, Sendable {
    let movieResults: [TMDbItem]?
    let tvResults: [TMDbItem]?

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}
