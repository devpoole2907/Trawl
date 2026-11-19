import Foundation
import Testing
@testable import Trawl

/// Pins Search's result order against lookup results captured verbatim from
/// Radarr 7.0.3 and Sonarr 4.0.20 on 19 November 2026 (first 20 results,
/// trimmed to the fields ranking reads). The originals showed both halves of
/// the bug: Trawl re-sorted Radarr's correct order alphabetically, which put
/// Star Wars (1977) far down the list, and Sonarr's own order is newest-first
/// rather than by relevance, so The Office (US) arrives ninth.
@Suite("Search result relevance")
@MainActor
struct SearchRelevanceTests {

    // MARK: - Captured mixes

    @Test("'star wars' puts the 1977 film first, then the most-voted Star Wars titles from either service")
    func starWarsMixedResults() throws {
        let movies = try Self.decode([RadarrMovie].self, Self.radarrStarWars)
        let series = try Self.decode([SonarrSeries].self, Self.sonarrStarWars)
        let titles = Self.rankedTitles(series: series, movies: movies, query: "star wars")

        #expect(Array(titles.prefix(10)) == [
            "Star Wars",
            "Star Wars: The Force Awakens",
            "Star Wars: Episode I - The Phantom Menace",
            "Star Wars: Episode III - Revenge of the Sith",
            "Star Wars: Episode II - Attack of the Clones",
            "Rogue One: A Star Wars Story",
            "Star Wars: The Last Jedi",
            "Star Wars: The Rise of Skywalker",
            "Solo: A Star Wars Story",
            "Star Wars: The Clone Wars"
        ])
    }

    @Test("'the office' puts The Office (US) first even though Sonarr returns it ninth")
    func theOfficeQualifiedTitleIsAnExactMatch() throws {
        let series = try Self.decode([SonarrSeries].self, Self.sonarrTheOffice)
        let titles = Self.rankedTitles(series: series, movies: [], query: "the office")

        #expect(Array(titles.prefix(2)) == ["The Office (US)", "The Office"])
        // "office" without the article is the same exact match.
        #expect(Self.rankedTitles(series: series, movies: [], query: "Office").first == "The Office (US)")
    }

    @Test("'dune' keeps both well-known adaptations above sequels, and obscure same-name films below them")
    func duneObscureExactMatchesDropBelowPopularSequels() throws {
        let movies = try Self.decode([RadarrMovie].self, Self.radarrDune)
        let ranked = SearchRelevance.ranked(movies, query: "dune", candidate: \.searchRelevanceCandidate)
        let labels = ranked.map { "\($0.title) (\($0.year ?? 0))" }

        #expect(Array(labels.prefix(3)) == ["Dune (2021)", "Dune (1984)", "Dune: Part Two (2024)"])
        let partTwo = try #require(labels.firstIndex(of: "Dune: Part Two (2024)"))
        let obscure = try #require(labels.firstIndex(of: "Dune (2020)"))
        #expect(partTwo < obscure)
    }

    @Test("'lord of the rings' leads with the trilogy, not the little-known 1978 film whose title matches exactly")
    func lordOfTheRingsLeadsWithTheTrilogy() throws {
        let movies = try Self.decode([RadarrMovie].self, Self.radarrLordOfTheRings)
        let series = try Self.decode([SonarrSeries].self, Self.sonarrLordOfTheRings)
        let titles = Self.rankedTitles(series: series, movies: movies, query: "lord of the rings")

        #expect(Array(titles.prefix(4)) == [
            "The Lord of the Rings: The Fellowship of the Ring",
            "The Lord of the Rings: The Return of the King",
            "The Lord of the Rings: The Two Towers",
            "The Lord of the Rings: The Rings of Power"
        ])
    }

    @Test("'it' puts films starting with the word above popular films that merely contain it")
    func oneWordQueryPrefersTitlesStartingWithTheWord() throws {
        let movies = try Self.decode([RadarrMovie].self, Self.radarrIt)
        let titles = Self.rankedTitles(series: [], movies: movies, query: "it")

        #expect(Array(titles.prefix(3)) == ["It", "It Chapter Two", "It Follows"])
        // Wreck-It Ralph has more votes than both sequels but only contains "it".
        let wreckIt = try #require(titles.firstIndex(of: "Wreck-It Ralph"))
        let lastStartingWithIt = try #require(titles.lastIndex(where: { $0.hasPrefix("It ") || $0 == "It!" }))
        #expect(lastStartingWithIt < wreckIt)
    }

    @Test("A lone exact match with no votes yet still comes first")
    func unreleasedExactMatchStillLeads() throws {
        let movies = try Self.decode([RadarrMovie].self, Self.radarrDune)
        let ranked = SearchRelevance.ranked(movies, query: "Dune: Part Three", candidate: \.searchRelevanceCandidate)

        #expect(ranked.first?.title == "Dune: Part Three")
    }

    // MARK: - Title matching

    @Test("Title matching ignores case, accents, punctuation, articles and trailing qualifiers", arguments: [
        ("Amélie", "amelie"),
        ("Schindler's List", "schindlers list"),
        ("The Office (CA) (2012)", "office"),
        ("Fast & Furious", "fast and furious"),
        ("Alien³", "alien3"),
        ("Star Wars", "  STAR   wars ")
    ])
    func exactMatchNormalization(title: String, query: String) {
        #expect(SearchRelevance.matchTier(title: title, query: query) == .exact)
    }

    @Test("Titles containing every query word rank above titles the service matched another way")
    func matchTiers() {
        #expect(SearchRelevance.matchTier(title: "Rogue One: A Star Wars Story", query: "star wars") == .allWords)
        #expect(SearchRelevance.matchTier(title: "Star Wars: Larry", query: "star wars") == .allWords)
        // Starting with the word is its own tier only for one-word queries.
        #expect(SearchRelevance.matchTier(title: "It Chapter Two", query: "it") == .leadingWord)
        #expect(SearchRelevance.matchTier(title: "The Batman Returns", query: "batman") == .leadingWord)
        #expect(SearchRelevance.matchTier(title: "Wreck-It Ralph", query: "it") == .allWords)
        #expect(SearchRelevance.matchTier(title: "Anatomy of a Fall", query: "dune") == .other)
        // Whole words only: "Dunes" is not "Dune".
        #expect(SearchRelevance.matchTier(title: "Dunes", query: "dune") == .other)
    }

    @Test("An empty query keeps the services' order")
    func emptyQueryKeepsOrder() throws {
        let movies = try Self.decode([RadarrMovie].self, Self.radarrDune)
        let ranked = SearchRelevance.ranked(movies, query: "   ", candidate: \.searchRelevanceCandidate)

        #expect(ranked.map(\.tmdbId) == movies.map(\.tmdbId))
    }

    // MARK: - Helpers

    private enum Entry {
        case series(SonarrSeries)
        case movie(RadarrMovie)

        var title: String {
            switch self {
            case .series(let s): s.title
            case .movie(let m): m.title
            }
        }

        var candidate: SearchRelevance.Candidate {
            switch self {
            case .series(let s): s.searchRelevanceCandidate
            case .movie(let m): m.searchRelevanceCandidate
            }
        }
    }

    /// Mirrors `SearchView`: series then movies, ranked together.
    private static func rankedTitles(series: [SonarrSeries], movies: [RadarrMovie], query: String) -> [String] {
        let entries = series.map(Entry.series) + movies.map(Entry.movie)
        return SearchRelevance.ranked(entries, query: query, candidate: \.candidate).map(\.title)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Captured lookups

    private static let radarrStarWars = #"""
        [
        {"title":"Star Wars","year":1977,"tmdbId":11,"ratings":{"imdb":{"votes":1598413},"tmdb":{"votes":23185}}},
        {"title":"Star Wars: The Last Jedi","year":2017,"tmdbId":181808,"ratings":{"imdb":{"votes":730138},"tmdb":{"votes":16867}}},
        {"title":"Star Wars: The Force Awakens","year":2015,"tmdbId":140607,"ratings":{"imdb":{"votes":1038790},"tmdb":{"votes":21123}}},
        {"title":"Star Wars: The Rise of Skywalker","year":2019,"tmdbId":181812,"ratings":{"imdb":{"votes":554015},"tmdb":{"votes":11319}}},
        {"title":"Solo: A Star Wars Story","year":2018,"tmdbId":348350,"ratings":{"imdb":{"votes":416803},"tmdb":{"votes":9643}}},
        {"title":"Rogue One: A Star Wars Story","year":2016,"tmdbId":330459,"ratings":{"imdb":{"votes":769741},"tmdb":{"votes":16984}}},
        {"title":"LEGO Star Wars: The Mandalorian","year":2026,"tmdbId":1731694,"ratings":{"imdb":{"votes":900},"tmdb":{"votes":41}}},
        {"title":"Star Wars: Episode I - The Phantom Menace","year":1999,"tmdbId":1893,"ratings":{"imdb":{"votes":943463},"tmdb":{"votes":16435}}},
        {"title":"Star Wars: The Clone Wars","year":2008,"tmdbId":12180,"ratings":{"imdb":{"votes":85064},"tmdb":{"votes":2313}}},
        {"title":"Star Wars: Episode III - Revenge of the Sith","year":2005,"tmdbId":1895,"ratings":{"imdb":{"votes":938775},"tmdb":{"votes":15516}}},
        {"title":"Star Wars: Starfighter","year":2027,"tmdbId":1417668,"ratings":{"tmdb":{"votes":0}}},
        {"title":"Star Wars: Episode II - Attack of the Clones","year":2002,"tmdbId":1894,"ratings":{"imdb":{"votes":835642},"tmdb":{"votes":14898}}},
        {"title":"LEGO Star Wars Holiday Special","year":2020,"tmdbId":732670,"ratings":{"imdb":{"votes":8885},"tmdb":{"votes":377}}},
        {"title":"Robot Chicken: Star Wars","year":2007,"tmdbId":42979,"ratings":{"imdb":{"votes":9082},"tmdb":{"votes":278}}},
        {"title":"LEGO Star Wars Summer Vacation","year":2022,"tmdbId":980804,"ratings":{"imdb":{"votes":2195},"tmdb":{"votes":109}}},
        {"title":"The Star Wars Holiday Special","year":1978,"tmdbId":74849,"ratings":{"imdb":{"votes":18783},"tmdb":{"votes":531}}},
        {"title":"Phineas and Ferb: Star Wars","year":2014,"tmdbId":392216,"ratings":{"imdb":{"votes":1158},"tmdb":{"votes":233}}},
        {"title":"LEGO Star Wars Terrifying Tales","year":2021,"tmdbId":857702,"ratings":{"imdb":{"votes":3307},"tmdb":{"votes":292}}},
        {"title":"Star Wars Biomes","year":2021,"tmdbId":825647,"ratings":{"imdb":{"votes":1149},"tmdb":{"votes":60}}},
        {"title":"Star Wars: Greatest Moments","year":2015,"tmdbId":378386,"ratings":{"imdb":{"votes":45},"tmdb":{"votes":34}}}
        ]
        """#

    private static let radarrDune = #"""
        [
        {"title":"Dune","year":2021,"tmdbId":438631,"ratings":{"imdb":{"votes":1103333},"tmdb":{"votes":15984}}},
        {"title":"Dune: Part Two","year":2024,"tmdbId":693134,"ratings":{"imdb":{"votes":807116},"tmdb":{"votes":8998}}},
        {"title":"Dune: Part Three","year":2026,"tmdbId":1170608,"ratings":{"tmdb":{"votes":0}}},
        {"title":"Dune","year":1984,"tmdbId":841,"ratings":{"imdb":{"votes":195061},"tmdb":{"votes":3629}}},
        {"title":"Anatomy of a Fall","year":2023,"tmdbId":915935,"ratings":{"imdb":{"votes":240119},"tmdb":{"votes":3572}}},
        {"title":"Dune","year":2020,"tmdbId":697620,"ratings":{"imdb":{"votes":88},"tmdb":{"votes":37}}},
        {"title":"Dune","year":1989,"tmdbId":627150,"ratings":{"imdb":{"votes":21},"tmdb":{"votes":3}}},
        {"title":"The Dune","year":2014,"tmdbId":271683,"ratings":{"imdb":{"votes":296},"tmdb":{"votes":21}}},
        {"title":"Planet Dune","year":2021,"tmdbId":881460,"ratings":{"imdb":{"votes":1360},"tmdb":{"votes":73}}},
        {"title":"Devil In Dune","year":2021,"tmdbId":911972,"ratings":{"imdb":{"votes":68},"tmdb":{"votes":18}}},
        {"title":"Golden Dune","year":2021,"tmdbId":633787,"ratings":{"tmdb":{"votes":4}}},
        {"title":"Dune Warriors","year":1991,"tmdbId":222339,"ratings":{"imdb":{"votes":666},"tmdb":{"votes":26}}},
        {"title":"The House on the Dune","year":1952,"tmdbId":533365,"ratings":{"imdb":{"votes":17},"tmdb":{"votes":12}}},
        {"title":"The Dune","year":2025,"tmdbId":1274770,"ratings":{"tmdb":{"votes":0}}},
        {"title":"The House on the Dune","year":1934,"tmdbId":539644,"ratings":{"tmdb":{"votes":5}}},
        {"title":"The Sand Dune","year":1955,"tmdbId":285149,"ratings":{"imdb":{"votes":73},"tmdb":{"votes":5}}},
        {"title":"Dune Drifter","year":2020,"tmdbId":744738,"ratings":{"imdb":{"votes":1735},"tmdb":{"votes":57}}},
        {"title":"Destination Dune","year":1983,"tmdbId":919946,"ratings":{"imdb":{"votes":65},"tmdb":{"votes":2}}},
        {"title":"Dune Surfer","year":1988,"tmdbId":354144,"ratings":{"imdb":{"votes":18},"tmdb":{"votes":2}}},
        {"title":"Dune Dreams","year":2021,"tmdbId":818926,"ratings":{"imdb":{"votes":53},"tmdb":{"votes":8}}}
        ]
        """#

    private static let sonarrStarWars = #"""
        [
        {"title":"Star Wars: Maul – Shadow Lord","year":2026,"tvdbId":462715,"ratings":{"votes":32193}},
        {"title":"Star Wars: Visions Presents - The Ninth Jedi","year":2026,"tvdbId":462774,"ratings":{"votes":2234}},
        {"title":"Star Wars: Tales of the Underworld","year":2025,"tvdbId":462199,"ratings":{"votes":11302}},
        {"title":"Star Wars: Skeleton Crew","year":2024,"tvdbId":420600,"ratings":{"votes":47217}},
        {"title":"Star Wars: Fun with Nubs","year":2024,"tvdbId":452828,"ratings":{"votes":69}},
        {"title":"Star Wars: Tales of the Empire","year":2024,"tvdbId":448549,"ratings":{"votes":18909}},
        {"title":"Star Wars: Young Jedi Adventures","year":2023,"tvdbId":420658,"ratings":{"votes":1875}},
        {"title":"Star Wars: Larry","year":2022,"tvdbId":427630,"ratings":{"votes":173}},
        {"title":"Star Wars: Tales of the Jedi","year":2022,"tvdbId":420659,"ratings":{"votes":47036}},
        {"title":"Star Wars: Visions","year":2021,"tvdbId":393190,"ratings":{"votes":28158}},
        {"title":"Star Wars: The Bad Batch","year":2021,"tvdbId":385376,"ratings":{"votes":69459}},
        {"title":"Star Wars: Detours","year":2020,"tvdbId":327185,"ratings":{"votes":243}},
        {"title":"Star Wars: Jedi Temple Challenge","year":2020,"tvdbId":373220,"ratings":{"votes":171}},
        {"title":"Star Wars: Forces of Destiny","year":2017,"tvdbId":330710,"ratings":{"votes":3160}},
        {"title":"Star Wars: The Clone Wars","year":2008,"tvdbId":83268,"ratings":{"votes":149823}},
        {"title":"Star Wars: Clone Wars","year":2003,"tvdbId":72244,"ratings":{"votes":33388}},
        {"title":"Star Wars: Ewoks","year":1985,"tvdbId":73697,"ratings":{"votes":2687}},
        {"title":"Star Wars: Droids","year":1985,"tvdbId":70399,"ratings":{"votes":2696}},
        {"title":"LEGO Star Wars","year":2013,"tvdbId":250498,"ratings":{"votes":0}},
        {"title":"Star Wars Blips","year":2017,"tvdbId":334444,"ratings":{"votes":369}}
        ]
        """#

    private static let sonarrTheOffice = #"""
        [
        {"title":"The Office","year":2001,"tvdbId":78107,"ratings":{"votes":134698}},
        {"title":"The Office (AU)","year":2024,"tvdbId":453455,"ratings":{"votes":5293}},
        {"title":"The Office (SA)","year":2022,"tvdbId":425211,"ratings":{"votes":2659}},
        {"title":"The Office (PL)","year":2021,"tvdbId":410750,"ratings":{"votes":820}},
        {"title":"The Office (IN)","year":2019,"tvdbId":366061,"ratings":{"votes":4197}},
        {"title":"The Office (FI)","year":2017,"tvdbId":324675,"ratings":{"votes":246}},
        {"title":"The Office (CA) (2012)","year":2012,"tvdbId":273261,"ratings":{"votes":17}},
        {"title":"The Office (CA)","year":2006,"tvdbId":252732,"ratings":{"votes":71}},
        {"title":"The Office (US)","year":2005,"tvdbId":73244,"ratings":{"votes":859873}},
        {"title":"The Office (1995)","year":1995,"tvdbId":77470,"ratings":{"votes":0}},
        {"title":"Die Kantoor","year":2026,"tvdbId":473036,"ratings":{"votes":324}},
        {"title":"The Office (MX) La Oficina","year":2026,"tvdbId":469462,"ratings":{"votes":2841}},
        {"title":"The Office Games","year":2023,"tvdbId":440886,"ratings":{"votes":0}},
        {"title":"The Naked Office","year":2010,"tvdbId":103541,"ratings":{"votes":0}},
        {"title":"The 1970s Office","year":2004,"tvdbId":75330,"ratings":{"votes":0}},
        {"title":"The Office Movers","year":2024,"tvdbId":454908,"ratings":{"votes":873}},
        {"title":"The Secret Office","year":2017,"tvdbId":406815,"ratings":{"votes":0}},
        {"title":"The Office Canteen","year":2021,"tvdbId":409693,"ratings":{"votes":55}},
        {"title":"The Queen of Office","year":2013,"tvdbId":268341,"ratings":{"votes":94}},
        {"title":"Box Office","year":2012,"tvdbId":264593,"ratings":{"votes":0}}
        ]
        """#

    private static let radarrLordOfTheRings = #"""
        [
        {"title":"The Lord of the Rings: The Fellowship of the Ring","year":2001,"tmdbId":120,"ratings":{"imdb":{"votes":2253033},"tmdb":{"votes":28891}}},
        {"title":"The Lord of the Rings: The Return of the King","year":2003,"tmdbId":122,"ratings":{"imdb":{"votes":2208508},"tmdb":{"votes":27851}}},
        {"title":"The Lord of the Rings: The Two Towers","year":2002,"tmdbId":121,"ratings":{"imdb":{"votes":1997556},"tmdb":{"votes":25004}}},
        {"title":"The Lord of the Rings","year":1978,"tmdbId":123,"ratings":{"imdb":{"votes":38864},"tmdb":{"votes":1109}}},
        {"title":"The Lord of the Rings: The War of the Rohirrim","year":2024,"tmdbId":839033,"ratings":{"imdb":{"votes":42470},"tmdb":{"votes":978}}},
        {"title":"The Lord of the Rings: The Hunt for Gollum","year":2027,"tmdbId":1090869,"ratings":{"tmdb":{"votes":0}}},
        {"title":"The Lord of the Rings: The Rings of Power Global Fan Screening","year":2022,"tmdbId":1016184,"ratings":{"tmdb":{"votes":62}}},
        {"title":"The Lord of the Rings: Shadow of the Past","year":0,"tmdbId":1657563,"ratings":{"tmdb":{"votes":0}}},
        {"title":"Howard Shore Weekend  - The Lord of the Rings","year":2023,"tmdbId":1428837,"ratings":{"tmdb":{"votes":1}}},
        {"title":"The Lord of The Rings: The Dread Of The Monster","year":2027,"tmdbId":1803787,"ratings":{"tmdb":{"votes":0}}},
        {"title":"Creating the Lord of the Rings Symphony","year":2004,"tmdbId":155586,"ratings":{"imdb":{"votes":206},"tmdb":{"votes":11}}},
        {"title":"Passage to Middle-Earth: The Making of 'The Lord of the Rings'","year":2001,"tmdbId":453779,"ratings":{"imdb":{"votes":587},"tmdb":{"votes":17}}},
        {"title":"The Lord Of The Rings - The Ultimate Critical Review","year":2005,"tmdbId":1724490,"ratings":{"tmdb":{"votes":0}}},
        {"title":"Forging Through the Darkness: The Ralph Bakshi Vision for 'The Lord of the Rings'","year":2010,"tmdbId":1035526,"ratings":{"imdb":{"votes":21},"tmdb":{"votes":1}}},
        {"title":"Tolkien's Lord of the Rings: A Catholic Worldview","year":2011,"tmdbId":1555391,"ratings":{"imdb":{"votes":47},"tmdb":{"votes":0}}},
        {"title":"The Lord of the Rings: The Rings of Power – Forging the One Ring","year":2026,"tmdbId":1828101,"ratings":{"tmdb":{"votes":0}}},
        {"title":"Darla's Book Club: Discussing the Lord of the Rings","year":2021,"tmdbId":945739,"ratings":{"imdb":{"votes":58},"tmdb":{"votes":4}}},
        {"title":"J.R.R. Tolkien and the Birth of \"The Lord of the Rings\" and \"The Hobbit\"","year":2004,"tmdbId":651342,"ratings":{"imdb":{"votes":28},"tmdb":{"votes":13}}},
        {"title":"Master of the Rings: The Unauthorized Story Behind J.R.R. Tolkien's \"Lord of the Rings\"","year":2001,"tmdbId":296260,"ratings":{"imdb":{"votes":198},"tmdb":{"votes":7}}},
        {"title":"The Hobbit","year":1977,"tmdbId":1362,"ratings":{"imdb":{"votes":19248},"tmdb":{"votes":384}}}
        ]
        """#

    private static let sonarrLordOfTheRings = #"""
        [
        {"title":"Lord of the Skies","year":2013,"tvdbId":279123,"ratings":{"votes":1657}},
        {"title":"Lord of the Universe","year":2019,"tvdbId":364321,"ratings":{"votes":0}},
        {"title":"Lord of the Chefs","year":2011,"tvdbId":243101,"ratings":{"votes":17}},
        {"title":"Dark Side of the Ring","year":2019,"tvdbId":361761,"ratings":{"votes":4771}},
        {"title":"Newcomers with Lauren Lapkus and Nicole Byer","year":2020,"tvdbId":392425,"ratings":{"votes":0}},
        {"title":"Lords of the Mafia","year":1999,"tvdbId":223801,"ratings":{"votes":0}},
        {"title":"Queen of the Ring","year":2017,"tvdbId":325407,"ratings":{"votes":721}},
        {"title":"Alles Over De Lord Of The Rings films","year":0,"tvdbId":456904,"ratings":{"votes":0}},
        {"title":"Icons Unearthed","year":2022,"tvdbId":421306,"ratings":{"votes":498}},
        {"title":"Into The Ring","year":2020,"tvdbId":381535,"ratings":{"votes":508}},
        {"title":"Snow Eagle Lord","year":2023,"tvdbId":424986,"ratings":{"votes":199}},
        {"title":"Lord of Lords Ryu Knight","year":1994,"tvdbId":166871,"ratings":{"votes":25}},
        {"title":"The Lord of the Rings: The Rings of Power","year":2022,"tvdbId":367506,"ratings":{"votes":451094}},
        {"title":"Flintoff: From Lords to the Ring","year":2012,"tvdbId":264774,"ratings":{"votes":13}},
        {"title":"Postcode Loterij in the ring","year":2026,"tvdbId":472609,"ratings":{"votes":0}},
        {"title":"Master of Study","year":2010,"tvdbId":135601,"ratings":{"votes":243}},
        {"title":"As the Bell Rings","year":2007,"tvdbId":104091,"ratings":{"votes":965}},
        {"title":"The Ring","year":2024,"tvdbId":451991,"ratings":{"votes":879}},
        {"title":"Five Gold Rings","year":2017,"tvdbId":324792,"ratings":{"votes":29}},
        {"title":"Ring of the Musketeers","year":1992,"tvdbId":182171,"ratings":{"votes":11}}
        ]
        """#


    private static let radarrIt = #"""
        [
        {"title":"It","year":2017,"tmdbId":346364,"ratings":{"imdb":{"votes":716427},"tmdb":{"votes":20885}}},
        {"title":"It Ends","year":2026,"tmdbId":1422011,"ratings":{"imdb":{"votes":10672},"tmdb":{"votes":129}}},
        {"title":"It Follows","year":2015,"tmdbId":270303,"ratings":{"imdb":{"votes":307870},"tmdb":{"votes":7272}}},
        {"title":"It Chapter Two","year":2019,"tmdbId":474350,"ratings":{"imdb":{"votes":366821},"tmdb":{"votes":9985}}},
        {"title":"Wreck-It Ralph","year":2012,"tmdbId":82690,"ratings":{"imdb":{"votes":508082},"tmdb":{"votes":13465}}},
        {"title":"Just Go with It","year":2011,"tmdbId":50546,"ratings":{"imdb":{"votes":296008},"tmdb":{"votes":6320}}},
        {"title":"Some Like It Hot","year":1959,"tmdbId":239,"ratings":{"imdb":{"votes":308907},"tmdb":{"votes":4068}}},
        {"title":"It Ends with Us","year":2024,"tmdbId":1079091,"ratings":{"imdb":{"votes":106422},"tmdb":{"votes":2085}}},
        {"title":"As Good as It Gets","year":1997,"tmdbId":2898,"ratings":{"imdb":{"votes":341654},"tmdb":{"votes":4328}}},
        {"title":"It Boy","year":2013,"tmdbId":173185,"ratings":{"imdb":{"votes":13678},"tmdb":{"votes":1648}}},
        {"title":"Pay It Forward","year":2000,"tmdbId":10647,"ratings":{"imdb":{"votes":128814},"tmdb":{"votes":2151}}},
        {"title":"It's a Wonderful Life","year":1946,"tmdbId":1585,"ratings":{"imdb":{"votes":563542},"tmdb":{"votes":5172}}},
        {"title":"It Takes Two","year":1995,"tmdbId":33689,"ratings":{"imdb":{"votes":29449},"tmdb":{"votes":1016}}},
        {"title":"Whip It","year":2009,"tmdbId":22798,"ratings":{"imdb":{"votes":72793},"tmdb":{"votes":1171}}},
        {"title":"The Conjuring: The Devil Made Me Do It","year":2021,"tmdbId":423108,"ratings":{"imdb":{"votes":175374},"tmdb":{"votes":6791}}},
        {"title":"Bring It On","year":2000,"tmdbId":1588,"ratings":{"imdb":{"votes":116724},"tmdb":{"votes":1938}}},
        {"title":"It Feeds","year":2025,"tmdbId":1145221,"ratings":{"imdb":{"votes":8348},"tmdb":{"votes":265}}},
        {"title":"It!","year":1967,"tmdbId":31232,"ratings":{"imdb":{"votes":1759},"tmdb":{"votes":32}}},
        {"title":"How It Ends","year":2018,"tmdbId":475210,"ratings":{"imdb":{"votes":64499},"tmdb":{"votes":2103}}},
        {"title":"Work It","year":2020,"tmdbId":612706,"ratings":{"imdb":{"votes":18393},"tmdb":{"votes":1234}}}
        ]
        """#
}
