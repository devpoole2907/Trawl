import Testing
import Foundation
@testable import Trawl

/// Pure decoding tests for the TMDb cast/credits data layer. No networking —
/// exercises snake_case CodingKeys against realistic TMDb JSON fixtures,
/// including null/missing-field cases.
@Suite("TMDb Credits Model Tests")
struct TMDbCreditsModelTests {

    // MARK: - TMDbCredits / TMDbCastMember / TMDbCrewMember

    @Test("Credits decode cast and crew with full fields")
    func creditsDecodeFull() throws {
        let json = """
        {
            "cast": [
                {
                    "id": 6193,
                    "name": "Leonardo DiCaprio",
                    "character": "Cobb",
                    "profile_path": "/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg",
                    "order": 0
                }
            ],
            "crew": [
                {
                    "id": 525,
                    "name": "Christopher Nolan",
                    "job": "Director",
                    "department": "Directing",
                    "profile_path": "/xuAIuYSmsUzKlUMBFGVZaWsY3DZ.jpg"
                }
            ]
        }
        """.data(using: .utf8)!

        let credits = try JSONDecoder().decode(TMDbCredits.self, from: json)

        let cast = try #require(credits.cast?.first)
        #expect(cast.id == 6193)
        #expect(cast.name == "Leonardo DiCaprio")
        #expect(cast.character == "Cobb")
        #expect(cast.profilePath == "/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg")
        #expect(cast.order == 0)
        #expect(cast.profileURL()?.absoluteString == "https://image.tmdb.org/t/p/w185/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg")
        #expect(cast.profileURL(size: "w500")?.absoluteString == "https://image.tmdb.org/t/p/w500/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg")

        let crew = try #require(credits.crew?.first)
        #expect(crew.id == 525)
        #expect(crew.name == "Christopher Nolan")
        #expect(crew.job == "Director")
        #expect(crew.department == "Directing")
        #expect(crew.profileURL()?.absoluteString == "https://image.tmdb.org/t/p/w185/xuAIuYSmsUzKlUMBFGVZaWsY3DZ.jpg")
    }

    @Test("Cast member decodes with null profile path and missing order")
    func castMemberNullFields() throws {
        let json = """
        { "id": 42, "name": "Someone", "character": null, "profile_path": null }
        """.data(using: .utf8)!

        let cast = try JSONDecoder().decode(TMDbCastMember.self, from: json)

        #expect(cast.id == 42)
        #expect(cast.character == nil)
        #expect(cast.profilePath == nil)
        #expect(cast.order == nil)
        #expect(cast.profileURL() == nil)
    }

    @Test("Crew member decodes with missing department and job")
    func crewMemberMissingFields() throws {
        let json = """
        { "id": 7, "name": "Anon" }
        """.data(using: .utf8)!

        let crew = try JSONDecoder().decode(TMDbCrewMember.self, from: json)

        #expect(crew.id == 7)
        #expect(crew.job == nil)
        #expect(crew.department == nil)
        #expect(crew.profilePath == nil)
        #expect(crew.profileURL() == nil)
    }

    @Test("Credits decode when cast and crew are missing entirely")
    func creditsMissingArrays() throws {
        let json = "{}".data(using: .utf8)!

        let credits = try JSONDecoder().decode(TMDbCredits.self, from: json)

        #expect(credits.cast == nil)
        #expect(credits.crew == nil)
    }

    // MARK: - TMDbPersonDetail

    @Test("Person detail decodes full biography fields")
    func personDetailFull() throws {
        let json = """
        {
            "id": 6193,
            "name": "Leonardo DiCaprio",
            "biography": "Leonardo Wilhelm DiCaprio is an American actor.",
            "birthday": "1974-11-11",
            "deathday": null,
            "place_of_birth": "Los Angeles, California, USA",
            "known_for_department": "Acting",
            "profile_path": "/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg"
        }
        """.data(using: .utf8)!

        let person = try JSONDecoder().decode(TMDbPersonDetail.self, from: json)

        #expect(person.id == 6193)
        #expect(person.name == "Leonardo DiCaprio")
        #expect(person.biography == "Leonardo Wilhelm DiCaprio is an American actor.")
        #expect(person.birthday == "1974-11-11")
        #expect(person.deathday == nil)
        #expect(person.placeOfBirth == "Los Angeles, California, USA")
        #expect(person.knownForDepartment == "Acting")
        #expect(person.profileURL()?.absoluteString == "https://image.tmdb.org/t/p/h632/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg")
        #expect(person.profileURL(size: "w185")?.absoluteString == "https://image.tmdb.org/t/p/w185/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg")
    }

    @Test("Person detail decodes a deceased person and missing profile path")
    func personDetailDeceasedNoProfile() throws {
        let json = """
        {
            "id": 190,
            "name": "Some Actor",
            "biography": "",
            "birthday": "1930-01-01",
            "deathday": "2005-06-01",
            "place_of_birth": null,
            "known_for_department": null,
            "profile_path": null
        }
        """.data(using: .utf8)!

        let person = try JSONDecoder().decode(TMDbPersonDetail.self, from: json)

        #expect(person.deathday == "2005-06-01")
        #expect(person.placeOfBirth == nil)
        #expect(person.knownForDepartment == nil)
        #expect(person.profileURL() == nil)
    }

    @Test("Person detail decodes with only required id field present")
    func personDetailMinimal() throws {
        let json = """
        { "id": 1 }
        """.data(using: .utf8)!

        let person = try JSONDecoder().decode(TMDbPersonDetail.self, from: json)

        #expect(person.id == 1)
        #expect(person.name == nil)
        #expect(person.biography == nil)
        #expect(person.birthday == nil)
    }

    // MARK: - TMDbPersonCombinedCredits / TMDbPersonCredit

    @Test("Person combined credits decode movie and tv entries")
    func personCombinedCreditsDecode() throws {
        let json = """
        {
            "cast": [
                {
                    "id": 27205,
                    "media_type": "movie",
                    "title": "Inception",
                    "poster_path": "/9gk7adHYeDvHkCSEqAvQNLV5Uge.jpg",
                    "release_date": "2010-07-15",
                    "character": "Cobb",
                    "vote_average": 8.4,
                    "popularity": 60.1
                },
                {
                    "id": 1396,
                    "media_type": "tv",
                    "name": "Breaking Bad",
                    "poster_path": "/ggFHVNu6YYI5L9pCfOacjizRGt.jpg",
                    "first_air_date": "2008-01-20",
                    "character": "Himself",
                    "vote_average": 8.9,
                    "popularity": 200.5
                }
            ],
            "crew": [
                {
                    "id": 155,
                    "media_type": "movie",
                    "title": "The Dark Knight",
                    "release_date": "2008-07-16",
                    "job": "Director",
                    "vote_average": 8.5,
                    "popularity": 100.2
                }
            ]
        }
        """.data(using: .utf8)!

        let credits = try JSONDecoder().decode(TMDbPersonCombinedCredits.self, from: json)

        let movie = try #require(credits.cast?.first)
        #expect(movie.id == 27205)
        #expect(movie.mediaType == "movie")
        #expect(movie.displayTitle == "Inception")
        #expect(movie.year == "2010")
        #expect(movie.isMovie == true)
        #expect(movie.character == "Cobb")
        #expect(movie.voteAverage == 8.4)
        #expect(movie.popularity == 60.1)
        #expect(movie.posterURL()?.absoluteString == "https://image.tmdb.org/t/p/w342/9gk7adHYeDvHkCSEqAvQNLV5Uge.jpg")

        let tv = try #require(credits.cast?.last)
        #expect(tv.mediaType == "tv")
        #expect(tv.displayTitle == "Breaking Bad")
        #expect(tv.year == "2008")
        #expect(tv.isMovie == false)

        let crew = try #require(credits.crew?.first)
        #expect(crew.job == "Director")
        #expect(crew.displayTitle == "The Dark Knight")
        #expect(crew.character == nil)
    }

    @Test("Person credit falls back to Unknown title and nil year when title/name/dates are missing")
    func personCreditUnknownFallback() throws {
        let json = """
        { "id": 99, "media_type": "movie" }
        """.data(using: .utf8)!

        let credit = try JSONDecoder().decode(TMDbPersonCredit.self, from: json)

        #expect(credit.displayTitle == "Unknown")
        #expect(credit.year == nil)
        #expect(credit.posterURL() == nil)
        #expect(credit.isMovie == true)
    }

    @Test("Person combined credits decode when cast and crew are missing")
    func personCombinedCreditsMissingArrays() throws {
        let json = "{}".data(using: .utf8)!

        let credits = try JSONDecoder().decode(TMDbPersonCombinedCredits.self, from: json)

        #expect(credits.cast == nil)
        #expect(credits.crew == nil)
    }

    // MARK: - TMDbFindResults

    @Test("Find results decode both movie and tv result arrays")
    func findResultsDecodeBoth() throws {
        let json = """
        {
            "movie_results": [
                { "id": 27205, "title": "Inception", "release_date": "2010-07-15" }
            ],
            "tv_results": [
                { "id": 1396, "name": "Breaking Bad", "first_air_date": "2008-01-20" }
            ],
            "person_results": [],
            "tv_episode_results": [],
            "tv_season_results": []
        }
        """.data(using: .utf8)!

        let results = try JSONDecoder().decode(TMDbFindResults.self, from: json)

        #expect(results.movieResults?.first?.id == 27205)
        #expect(results.movieResults?.first?.displayTitle == "Inception")
        #expect(results.tvResults?.first?.id == 1396)
        #expect(results.tvResults?.first?.displayTitle == "Breaking Bad")
    }

    @Test("Find results decode when only tv_results is present (tvdb_id lookup)")
    func findResultsTvOnly() throws {
        let json = """
        {
            "movie_results": [],
            "tv_results": [
                { "id": 1399, "name": "Game of Thrones", "first_air_date": "2011-04-17" }
            ]
        }
        """.data(using: .utf8)!

        let results = try JSONDecoder().decode(TMDbFindResults.self, from: json)

        #expect(results.movieResults?.isEmpty == true)
        #expect(results.tvResults?.first?.id == 1399)
    }

    @Test("Find results decode when both result arrays are missing")
    func findResultsMissingArrays() throws {
        let json = "{}".data(using: .utf8)!

        let results = try JSONDecoder().decode(TMDbFindResults.self, from: json)

        #expect(results.movieResults == nil)
        #expect(results.tvResults == nil)
    }
}
