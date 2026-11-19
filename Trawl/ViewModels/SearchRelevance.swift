import Foundation

/// Orders Search results by how well they answer the query.
///
/// Search used to sort results alphabetically, which threw away the services'
/// own ranking: "star wars" put "LEGO Star Wars…" and "Rogue One…" above
/// Star Wars (1977). Radarr already returns that film first, but Sonarr's
/// lookup comes back newest-first rather than by relevance ("the office"
/// returns The Office (US) ninth), and a mixed movie + series list has no
/// shared order at all. So Trawl ranks every result itself:
///
/// 1. how the title matches the query - exact, contains every word of it, or
///    anything else the service matched (alternate titles etc.). For a
///    one-word query, titles that start with the word sit between exact and
///    all-words: "it" should list It Chapter Two above Wreck-It Ralph. Longer
///    queries get no such tier - it would put "Star Wars: Larry" (173 votes)
///    above "Rogue One: A Star Wars Story";
/// 2. an exact match with under 10% of the votes of the best title containing
///    every query word drops a tier (to starts-with for one-word queries). Otherwise the 1978
///    animated "The Lord of the Rings" (39k votes) sits above The Fellowship
///    of the Ring (2.2M), and "Batman (1966)" above Batman Begins. An exact
///    match nothing else rivals - an unreleased "Dune: Part Three" with no
///    votes yet - still comes first;
/// 3. within a match tier, the most-voted title first. Movies use IMDb votes
///    (TMDb votes when IMDb has none) and series use Sonarr's vote count, which
///    sit on the same scale, so a mixed list compares like with like;
/// 4. ties keep the order the results arrived in.
///
/// Title comparison ignores case, accents, punctuation, a leading article and
/// a trailing qualifier such as "(US)" or "(2012)", so "the office" is an
/// exact match for "The Office (US)".
nonisolated enum SearchRelevance {

    enum MatchTier: Int, Comparable {
        case exact = 0
        /// One-word queries only: the title (less any leading article) starts with the word.
        case leadingWord = 1
        case allWords = 2
        case other = 3

        static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Candidate {
        let title: String
        let votes: Int
    }

    /// Returns `items` ordered most relevant first. An empty query keeps the
    /// original order.
    static func ranked<Item>(_ items: [Item], query: String, candidate: (Item) -> Candidate) -> [Item] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return items }

        var scored = items.enumerated().map { offset, item -> (item: Item, tier: MatchTier, votes: Int, offset: Int) in
            let info = candidate(item)
            return (item, matchTier(title: info.title, normalizedQuery: normalizedQuery), info.votes, offset)
        }
        let bestWholeWordVotes = scored.filter { $0.tier <= .allWords }.map(\.votes).max() ?? 0
        let demotedTier: MatchTier = isSingleWord(normalizedQuery) ? .leadingWord : .allWords
        for index in scored.indices where scored[index].tier == .exact
            && scored[index].votes * 10 < bestWholeWordVotes {
            scored[index].tier = demotedTier
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
                return lhs.offset < rhs.offset
            }
            .map(\.item)
    }

    static func matchTier(title: String, query: String) -> MatchTier {
        matchTier(title: title, normalizedQuery: normalize(query))
    }

    private static func matchTier(title: String, normalizedQuery query: String) -> MatchTier {
        let queryVariants = Set([query, dropLeadingArticle(query)])
        let fullTitle = normalize(title)
        let titleVariants = Set([
            fullTitle,
            dropLeadingArticle(fullTitle),
            normalize(dropTrailingQualifier(title)),
            dropLeadingArticle(normalize(dropTrailingQualifier(title)))
        ]).filter { !$0.isEmpty }

        if !titleVariants.isDisjoint(with: queryVariants) {
            return .exact
        }
        let titleWords = Set(fullTitle.split(separator: " "))
        let queryWords = dropLeadingArticle(query).split(separator: " ")
        if !queryWords.isEmpty, queryWords.allSatisfy(titleWords.contains) {
            if queryWords.count == 1,
               dropLeadingArticle(fullTitle).split(separator: " ").first == queryWords[0] {
                return .leadingWord
            }
            return .allWords
        }
        return .other
    }

    private static func isSingleWord(_ normalizedQuery: String) -> Bool {
        dropLeadingArticle(normalizedQuery).split(separator: " ").count == 1
    }

    /// Lower-cases, folds accents and compatibility forms ("Alien³" → "alien3"),
    /// spells out "&", and reduces every run of punctuation or whitespace to a
    /// single space.
    static func normalize(_ text: String) -> String {
        let folded = text
            .decomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue // "Schindler's" → "schindlers", not "schindler s"
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    private static func dropLeadingArticle(_ normalized: String) -> String {
        for article in ["the ", "a ", "an "] where normalized.hasPrefix(article) {
            return String(normalized.dropFirst(article.count))
        }
        return normalized
    }

    /// "The Office (US)" → "The Office"; "The Office (CA) (2012)" → "The Office".
    private static func dropTrailingQualifier(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix(")"), let open = result.lastIndex(of: "("), open > result.startIndex {
            result = String(result[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

nonisolated extension RadarrMovie {
    var searchRelevanceCandidate: SearchRelevance.Candidate {
        SearchRelevance.Candidate(
            title: title,
            votes: ratings?.imdb?.votes ?? ratings?.tmdb?.votes ?? 0
        )
    }
}

nonisolated extension SonarrSeries {
    var searchRelevanceCandidate: SearchRelevance.Candidate {
        SearchRelevance.Candidate(title: title, votes: ratings?.votes ?? 0)
    }
}
