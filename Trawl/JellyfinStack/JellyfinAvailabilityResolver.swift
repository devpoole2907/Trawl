import Foundation
import Observation

@MainActor
@Observable
final class JellyfinAvailabilityResolver {
    enum State {
        case idle
        case loading
        case resolved([JellyfinLibraryItem])
        case failed(String)
    }

    struct Key: Hashable {
        let profileID: UUID
        let mediaTaskKey: String
    }

    struct EpisodesKey: Hashable {
        let profileID: UUID
        let seriesItemID: String
    }

    private struct Entry {
        var state: State
        var timestamp: Date
    }

    /// `.loading` never expires — an in-flight task owns that entry and will
    /// overwrite it. `.idle` is never stored.
    private func expired(_ entry: Entry) -> Bool {
        let age = now().timeIntervalSince(entry.timestamp)
        switch entry.state {
        case .resolved: return age > Self.ttl
        case .failed: return age > Self.failureTTL
        case .loading, .idle: return false
        }
    }

    private static let ttl: TimeInterval = 300
    /// Failures expire far sooner than successes. A resolved answer stays valid
    /// for as long as the library is unlikely to have changed, but a failure is
    /// usually transient — a dropped connection or a server restart — and must
    /// not pin the card in an error state for the life of the resolver.
    private static let failureTTL: TimeInterval = 60
    private static let maxEntries = 64
    private static let maxEpisodeEntries = 32

    /// Injectable clock. Production uses the real one; tests drive expiry
    /// directly rather than waiting out a 60- or 300-second TTL.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var inFlight: [Key: Task<Void, Never>] = [:]

    private var episodeEntries: [EpisodesKey: Entry] = [:]
    private var episodeInsertionOrder: [EpisodesKey] = []
    private var episodeInFlight: [EpisodesKey: Task<Void, Never>] = [:]

    func state(for key: Key) -> State {
        guard let entry = entries[key] else { return .idle }
        return expired(entry) ? .idle : entry.state
    }

    func ensureLoaded(_ key: Key, media: JellyfinMediaAvailabilityCard.Media, client: JellyfinAPIClient) {
        switch state(for: key) {
        case .resolved, .loading, .failed: return
        case .idle: break
        }

        setEntry(key: key, state: .loading)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLookup(key: key, media: media, client: client)
        }
        inFlight[key] = task
    }

    func invalidate(_ key: Key) {
        inFlight[key]?.cancel()
        inFlight.removeValue(forKey: key)
        entries.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    func invalidateAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        entries.removeAll()
        insertionOrder.removeAll()

        for task in episodeInFlight.values { task.cancel() }
        episodeInFlight.removeAll()
        episodeEntries.removeAll()
        episodeInsertionOrder.removeAll()
    }

    // MARK: - Episodes

    func episodesState(for key: EpisodesKey) -> State {
        guard let entry = episodeEntries[key] else { return .idle }
        return expired(entry) ? .idle : entry.state
    }

    func ensureEpisodesLoaded(_ key: EpisodesKey, client: JellyfinAPIClient) {
        switch episodesState(for: key) {
        case .resolved, .loading, .failed: return
        case .idle: break
        }

        setEpisodeEntry(key: key, state: .loading)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEpisodeLookup(key: key, client: client)
        }
        episodeInFlight[key] = task
    }

    func invalidateEpisodes(_ key: EpisodesKey) {
        episodeInFlight[key]?.cancel()
        episodeInFlight.removeValue(forKey: key)
        episodeEntries.removeValue(forKey: key)
        episodeInsertionOrder.removeAll { $0 == key }
    }

    private func performLookup(key: Key, media: JellyfinMediaAvailabilityCard.Media, client: JellyfinAPIClient) async {
        do {
            let pairs = media.providerIdPairs
            var items: [JellyfinLibraryItem] = []

            if !pairs.isEmpty {
                let candidates = try await client.findItems(
                    includeItemTypes: media.itemTypes,
                    anyProviderIdEquals: pairs
                )
                // Apply local matching as a safety net — some Jellyfin versions
                // ignore AnyProviderIdEquals on /Items and return all library items.
                items = candidates.filter { localMatches($0, media: media) }
            }

            // Fall back to a title search when the provider-ID lookup finds
            // nothing. Jellyfin's SearchTerm is a case-insensitive *substring*
            // match on the item name, so several things defeat the primary path:
            // the server may ignore AnyProviderIdEquals entirely (returning a
            // capped, arbitrary slice the local filter discards), the item may
            // lack the provider IDs we queried, or the title may differ by
            // punctuation (Sonarr's en-dash vs Jellyfin's hyphen) or a "(year)"
            // suffix. Dash-normalising keeps the title a substring of the name.
            if items.isEmpty {
                items = try await searchAndFilter(term: dashNormalized(media.title), media: media, client: client)
            }

            // Last resort: search by the single most distinctive word, which is
            // still a substring of the Jellyfin name even when the full title
            // drifts. localMatches keeps the result strict.
            if items.isEmpty, let word = mostDistinctiveWord(in: media.title) {
                items = try await searchAndFilter(term: word, media: media, client: client)
            }

            guard !Task.isCancelled else { return }
            setEntry(key: key, state: .resolved(items.sorted { ($0.name ?? "") < ($1.name ?? "") }))
        } catch {
            guard !Task.isCancelled else { return }
            setEntry(key: key, state: .failed(error.localizedDescription))
        }
    }

    private func searchAndFilter(
        term: String,
        media: JellyfinMediaAvailabilityCard.Media,
        client: JellyfinAPIClient
    ) async throws -> [JellyfinLibraryItem] {
        guard !term.isEmpty else { return [] }
        let candidates = try await client.searchItems(term: term, includeItemTypes: media.itemTypes)
        return candidates.filter { localMatches($0, media: media) }
    }

    private func performEpisodeLookup(key: EpisodesKey, client: JellyfinAPIClient) async {
        do {
            let items = try await client.getSeriesEpisodes(seriesId: key.seriesItemID)
            guard !Task.isCancelled else { return }
            setEpisodeEntry(key: key, state: .resolved(items))
        } catch {
            guard !Task.isCancelled else { return }
            setEpisodeEntry(key: key, state: .failed(error.localizedDescription))
        }
    }

    private func setEntry(key: Key, state: State) {
        if entries[key] == nil {
            insertionOrder.append(key)
            while insertionOrder.count > Self.maxEntries {
                let oldest = insertionOrder.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = Entry(state: state, timestamp: now())
    }

    private func setEpisodeEntry(key: EpisodesKey, state: State) {
        if episodeEntries[key] == nil {
            episodeInsertionOrder.append(key)
            while episodeInsertionOrder.count > Self.maxEpisodeEntries {
                let oldest = episodeInsertionOrder.removeFirst()
                episodeEntries.removeValue(forKey: oldest)
            }
        }
        episodeEntries[key] = Entry(state: state, timestamp: now())
    }

    private func localMatches(_ item: JellyfinLibraryItem, media: JellyfinMediaAvailabilityCard.Media) -> Bool {
        switch media {
        case .movie(let title, let year, let tmdbId, let imdbId):
            if matchesNumericProvider(item, keys: ["Tmdb", "TMDb"], id: tmdbId) { return true }
            if matchesStringProvider(item, keys: ["Imdb", "IMDb", "IMDB"], id: imdbId) { return true }
            return titleYearFallbackMatches(item, title: title, year: year)
        case .series(let title, let year, let tvdbId, let tmdbId, let imdbId, _):
            if matchesNumericProvider(item, keys: ["Tvdb", "TVDB"], id: tvdbId) { return true }
            if matchesNumericProvider(item, keys: ["Tmdb", "TMDb"], id: tmdbId) { return true }
            if matchesStringProvider(item, keys: ["Imdb", "IMDb", "IMDB"], id: imdbId) { return true }
            return titleYearFallbackMatches(item, title: title, year: year)
        }
    }

    private func matchesNumericProvider(_ item: JellyfinLibraryItem, keys: [String], id: Int?) -> Bool {
        guard let id, let value = item.providerID(for: keys) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == String(id)
    }

    private func matchesStringProvider(_ item: JellyfinLibraryItem, keys: [String], id: String?) -> Bool {
        guard let id, !id.isEmpty, let value = item.providerID(for: keys) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(id) == .orderedSame
    }

    private func titleYearFallbackMatches(_ item: JellyfinLibraryItem, title: String, year: Int?) -> Bool {
        guard normalizedTitle(strippingTrailingYear(item.name)) == normalizedTitle(title) else { return false }
        guard let year, let productionYear = item.productionYear else { return true }
        // Allow a one-year tolerance — Sonarr/Radarr and Jellyfin's metadata
        // sources routinely disagree by a year on first-air/release dates,
        // especially for unreleased titles.
        return abs(productionYear - year) <= 1
    }

    /// Jellyfin appends a disambiguation `(YYYY)` suffix to library item names
    /// when several entries share a title (e.g. "A Knight of the Seven Kingdoms
    /// (2025)"). Sonarr/Radarr titles carry no such suffix, so strip it before
    /// comparing — otherwise the trailing year defeats the normalized match.
    private func strippingTrailingYear(_ value: String?) -> String {
        guard let value else { return "" }
        return value.replacingOccurrences(
            of: #"\s*\((?:19|20)\d{2}\)\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Replaces Unicode dash variants (en-dash, em-dash, etc.) with an ASCII
    /// hyphen. Jellyfin's SearchTerm is a literal substring match, so a Sonarr
    /// title carrying an en-dash won't match a hyphenated Jellyfin name unless
    /// the two are aligned first.
    private func dashNormalized(_ value: String) -> String {
        var result = value
        for dash in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"] {
            result = result.replacingOccurrences(of: dash, with: "-")
        }
        return result
    }

    /// The longest alphanumeric word in the title — distinctive enough to narrow
    /// a substring search while still appearing verbatim in the Jellyfin name.
    private func mostDistinctiveWord(in title: String) -> String? {
        title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .max { $0.count < $1.count }
    }

    private func normalizedTitle(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}
