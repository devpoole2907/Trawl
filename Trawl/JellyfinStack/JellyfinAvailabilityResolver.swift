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

    private struct Entry {
        var state: State
        var timestamp: Date
    }

    private static let ttl: TimeInterval = 300
    private static let maxEntries = 64

    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var inFlight: [Key: Task<Void, Never>] = [:]

    func state(for key: Key) -> State {
        guard let entry = entries[key] else { return .idle }
        if case .resolved = entry.state, Date().timeIntervalSince(entry.timestamp) > Self.ttl {
            return .idle
        }
        return entry.state
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
    }

    private func performLookup(key: Key, media: JellyfinMediaAvailabilityCard.Media, client: JellyfinAPIClient) async {
        do {
            let pairs = media.providerIdPairs
            let items: [JellyfinLibraryItem]

            if !pairs.isEmpty {
                let candidates = try await client.findItems(
                    includeItemTypes: media.itemTypes,
                    anyProviderIdEquals: pairs
                )
                // Apply local matching as a safety net — some Jellyfin versions
                // ignore AnyProviderIdEquals on /Items and return all library items.
                items = candidates.filter { localMatches($0, media: media) }
            } else {
                let candidates = try await client.searchItems(
                    term: media.title,
                    includeItemTypes: media.itemTypes
                )
                items = candidates.filter { localMatches($0, media: media) }
            }

            guard !Task.isCancelled else { return }
            setEntry(key: key, state: .resolved(items.sorted { ($0.name ?? "") < ($1.name ?? "") }))
        } catch {
            guard !Task.isCancelled else { return }
            setEntry(key: key, state: .failed(error.localizedDescription))
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
        entries[key] = Entry(state: state, timestamp: Date())
    }

    private func localMatches(_ item: JellyfinLibraryItem, media: JellyfinMediaAvailabilityCard.Media) -> Bool {
        switch media {
        case .movie(let title, let year, let tmdbId, let imdbId):
            if matchesNumericProvider(item, keys: ["Tmdb", "TMDb"], id: tmdbId) { return true }
            if matchesStringProvider(item, keys: ["Imdb", "IMDb", "IMDB"], id: imdbId) { return true }
            return titleYearFallbackMatches(item, title: title, year: year)
        case .series(let title, let year, let tvdbId, let tmdbId, let imdbId):
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
        guard normalizedTitle(item.name) == normalizedTitle(title) else { return false }
        guard let year else { return true }
        return item.productionYear == nil || item.productionYear == year
    }

    private func normalizedTitle(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}
