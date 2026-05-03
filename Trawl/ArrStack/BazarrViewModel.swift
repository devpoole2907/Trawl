import Foundation
import Observation
import SwiftUI

enum BazarrSubtitleStatus {
    case allPresent
    case partial
    case none
    case unknown
}

@MainActor
@Observable
final class BazarrViewModel {
    let serviceManager: ArrServiceManager

    private(set) var series: [BazarrSeries] = []
    private(set) var movies: [BazarrMovie] = []
    private(set) var episodes: [Int: [BazarrEpisode]] = [:] // seriesId -> episodes
    private(set) var isLoadingSeries = false
    private(set) var isLoadingMovies = false
    private(set) var isLoadingEpisodes = false
    private(set) var seriesError: String?
    private(set) var moviesError: String?
    private(set) var episodesError: String?

    var searchText = "" {
        didSet { Task { @MainActor in await applyFilters() } }
    }
    var showMonitoredOnly = false {
        didSet { Task { @MainActor in await applyFilters() } }
    }
    var showMissingOnly = false {
        didSet { Task { @MainActor in await applyFilters() } }
    }
    var sortNewestFirst = true {
        didSet { Task { @MainActor in await applyFilters() } }
    }

    private(set) var filteredSeries: [BazarrSeries] = []
    private(set) var filteredMovies: [BazarrMovie] = []

    var selectedTab: BazarrBrowserTab = .series

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    private var client: BazarrAPIClient? {
        serviceManager.activeBazarrEntry?.client
    }

    var isConnected: Bool {
        guard let entry = serviceManager.activeBazarrEntry, let client = entry.client else {
            return false
        }
        return client.isConnected
    }

    var isConnecting: Bool {
        serviceManager.activeBazarrEntry?.isConnecting ?? false
    }

    var connectionError: String? {
        serviceManager.bazarrConnectionError
    }

    // MARK: - Subtitle Status

    static func subtitleStatus(for series: BazarrSeries) -> BazarrSubtitleStatus {
        if series.episodeFileCount == 0 { return .unknown }
        if series.episodeMissingCount == 0 { return .allPresent }
        if series.episodeMissingCount == series.episodeFileCount { return .none }
        return .partial
    }

    static func subtitleStatus(for movie: BazarrMovie) -> BazarrSubtitleStatus {
        if movie.missingSubtitles.isEmpty { return .allPresent }
        return movie.subtitles.isEmpty ? .none : .partial
    }

    static func subtitleStatus(for episode: BazarrEpisode) -> BazarrSubtitleStatus {
        if episode.missingSubtitles.isEmpty { return .allPresent }
        return episode.subtitles.isEmpty ? .none : .partial
    }

    // MARK: - Load Data

    func loadSeries() async {
        guard let client else {
            seriesError = "No connected Bazarr instance"
            series = []
            await applyFilters()
            return
        }
        isLoadingSeries = true
        seriesError = nil
        do {
            let page = try await client.getSeries(start: 0, length: -1)
            series = page.data
            await applyFilters()
        } catch {
            seriesError = error.localizedDescription
            series = []
            await applyFilters()
        }
        isLoadingSeries = false
    }

    func loadMovies() async {
        guard let client else {
            moviesError = "No connected Bazarr instance"
            movies = []
            await applyFilters()
            return
        }
        isLoadingMovies = true
        moviesError = nil
        do {
            let page = try await client.getMovies(start: 0, length: -1)
            movies = page.data
            await applyFilters()
        } catch {
            moviesError = error.localizedDescription
            movies = []
            await applyFilters()
        }
        isLoadingMovies = false
    }

    func loadEpisodes(for seriesId: Int) async {
        guard let client else {
            episodesError = "No connected Bazarr instance"
            episodes[seriesId] = []
            return
        }
        isLoadingEpisodes = true
        episodesError = nil
        do {
            let eps = try await client.getEpisodes(seriesIds: [seriesId])
            episodes[seriesId] = eps
        } catch {
            episodesError = error.localizedDescription
            episodes[seriesId] = []
        }
        isLoadingEpisodes = false
    }

    // MARK: - Actions

    func runSeriesAction(_ action: BazarrSeriesAction, seriesId: Int) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.runSeriesAction(seriesId: seriesId, action: action)
    }

    func runMovieAction(_ action: BazarrSeriesAction, radarrId: Int) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.runMovieAction(radarrId: radarrId, action: action)
    }

    func setSeriesProfile(seriesId: Int, profileId: Int?) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.updateSeriesProfile(seriesIds: [seriesId], profileIds: [profileId.map(String.init) ?? "none"])
    }

    func setMovieProfile(radarrId: Int, profileId: Int?) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.updateMovieProfile(radarrIds: [radarrId], profileIds: [profileId.map(String.init) ?? "none"])
    }

    func downloadEpisodeSubtitles(seriesId: Int, episodeId: Int, language: String, forced: Bool, hi: Bool) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.downloadEpisodeSubtitles(seriesId: seriesId, episodeId: episodeId, language: language, forced: forced, hi: hi)
    }

    func deleteEpisodeSubtitles(seriesId: Int, episodeId: Int, language: String, forced: Bool, hi: Bool, path: String) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.deleteEpisodeSubtitles(seriesId: seriesId, episodeId: episodeId, language: language, forced: forced, hi: hi, path: path)
    }

    func downloadMovieSubtitles(radarrId: Int, language: String, forced: Bool, hi: Bool) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.downloadMovieSubtitles(radarrId: radarrId, language: language, forced: forced, hi: hi)
    }

    func deleteMovieSubtitles(radarrId: Int, language: String, forced: Bool, hi: Bool, path: String) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.deleteMovieSubtitles(radarrId: radarrId, language: language, forced: forced, hi: hi, path: path)
    }

    func interactiveSearchEpisode(episodeId: Int, language: String, hi: Bool, forced: Bool) async throws -> [BazarrInteractiveSearchResult] {
        guard let client else { throw ArrError.noServiceConfigured }
        return try await client.interactiveSearchEpisode(episodeId: episodeId, language: language, hi: hi, forced: forced)
    }

    func downloadInteractiveEpisodeSubtitle(episodeId: Int, seriesId: Int, provider: String, subtitle: String, language: String, hi: Bool, forced: Bool) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.downloadInteractiveEpisodeSubtitle(episodeId: episodeId, seriesId: seriesId, provider: provider, subtitle: subtitle, language: language, hi: hi, forced: forced)
    }

    func interactiveSearchMovie(radarrId: Int, language: String, hi: Bool, forced: Bool) async throws -> [BazarrInteractiveSearchResult] {
        guard let client else { throw ArrError.noServiceConfigured }
        return try await client.interactiveSearchMovie(radarrId: radarrId, language: language, hi: hi, forced: forced)
    }

    func downloadInteractiveMovieSubtitle(radarrId: Int, provider: String, subtitle: String, language: String, hi: Bool, forced: Bool) async throws {
        guard let client else { throw ArrError.noServiceConfigured }
        try await client.downloadInteractiveMovieSubtitle(radarrId: radarrId, provider: provider, subtitle: subtitle, language: language, hi: hi, forced: forced)
    }

    // MARK: - Filtering

    private func applyFilters() async {
        let result: [BazarrSeries]
        if searchText.isEmpty && !showMonitoredOnly && !showMissingOnly {
            result = series
        } else {
            result = series.filter { s in
                if !searchText.isEmpty {
                    if !s.title.localizedCaseInsensitiveContains(searchText) { return false }
                }
                if showMonitoredOnly && !s.monitored { return false }
                if showMissingOnly && s.episodeMissingCount == 0 { return false }
                return true
            }
        }
        filteredSeries = sortNewestFirst ? result.reversed() : result

        let movieResult: [BazarrMovie]
        if searchText.isEmpty && !showMonitoredOnly && !showMissingOnly {
            movieResult = movies
        } else {
            movieResult = movies.filter { m in
                if !searchText.isEmpty {
                    if !m.title.localizedCaseInsensitiveContains(searchText) { return false }
                }
                if showMonitoredOnly && !m.monitored { return false }
                if showMissingOnly && m.missingSubtitles.isEmpty { return false }
                return true
            }
        }
        filteredMovies = sortNewestFirst ? movieResult.reversed() : movieResult
    }

    // MARK: - Helpers

    func statusColor(for status: BazarrSubtitleStatus) -> Color {
        switch status {
        case .allPresent: .green
        case .partial: .orange
        case .none: .red
        case .unknown: .gray
        }
    }

    func statusIcon(for status: BazarrSubtitleStatus) -> String {
        switch status {
        case .allPresent: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .none: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

enum BazarrBrowserTab: String, CaseIterable {
    case series = "Series"
    case movies = "Movies"
}
