import SwiftUI
import OSLog

// MARK: - Display models

/// A proposed library match for an unmapped folder.
struct ArrImportCandidate: Identifiable, Hashable, Sendable {
    let id: Int        // tvdbId (Sonarr) or tmdbId (Radarr)
    let title: String
    let year: Int?
    let posterURL: URL?
}

/// A catalog result the user can pick to override an auto-match.
enum ArrImportPick: Sendable {
    case series(SonarrSeries)
    case movie(RadarrMovie)
}

// MARK: - View Model

@Observable
@MainActor
final class ArrLibraryImportViewModel {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trawl", category: "ArrLibraryImport")

    enum MatchState: Equatable {
        case matching
        case matched(ArrImportCandidate)
        case noMatch
        case failed(String)
    }

    struct Folder: Identifiable {
        let id: String       // absolute path (unique within a root)
        let name: String
        let path: String
        var matchState: MatchState
        var include: Bool

        var isMatched: Bool {
            if case .matched = matchState { return true }
            return false
        }
    }

    let service: ArrServiceType
    let serviceManager: ArrServiceManager

    var selectedRootFolderPath: String?
    var folders: [Folder] = []
    var isLoadingFolders = false
    var loadError: String?
    var hasLoadedFolders = false
    var isImporting = false

    // Add options shared across the batch.
    var selectedQualityProfileId: Int?
    var monitorOption: String
    /// Library Import adopts files that already exist on disk, so a search-on-add
    /// would only chase upgrades — default it off to match Sonarr/Radarr's own flow.
    var searchOnImport = false

    // Full lookup objects, keyed by candidate id, needed to build import bodies.
    private var seriesByID: [Int: SonarrSeries] = [:]
    private var moviesByID: [Int: RadarrMovie] = [:]

    init(service: ArrServiceType, serviceManager: ArrServiceManager) {
        self.service = service
        self.serviceManager = serviceManager
        self.monitorOption = service == .sonarr ? "all" : "movieOnly"
    }

    var rootFolders: [ArrRootFolder] {
        service == .sonarr ? serviceManager.sonarrRootFolders : serviceManager.radarrRootFolders
    }

    var qualityProfiles: [ArrQualityProfile] {
        service == .sonarr ? serviceManager.sonarrQualityProfiles : serviceManager.radarrQualityProfiles
    }

    var includedMatchedCount: Int {
        folders.count(where: { $0.include && $0.isMatched })
    }

    var canImport: Bool {
        !isImporting && selectedQualityProfileId != nil && selectedRootFolderPath != nil && includedMatchedCount > 0
    }

    func prepareDefaults() {
        if selectedRootFolderPath == nil { selectedRootFolderPath = rootFolders.first?.path }
        if selectedQualityProfileId == nil { selectedQualityProfileId = qualityProfiles.first?.id }
    }

    // MARK: - Loading & matching

    func loadFolders() async {
        guard let rootPath = selectedRootFolderPath else {
            folders = []
            return
        }
        isLoadingFolders = true
        loadError = nil
        defer {
            isLoadingFolders = false
            hasLoadedFolders = true
        }
        do {
            seriesByID.removeAll()
            moviesByID.removeAll()
            let roots = try await fetchRootFolders()
            // Bail if the user switched roots while we were fetching.
            guard selectedRootFolderPath == rootPath else { return }
            let unmapped = (roots.first { $0.path == rootPath }?.unmappedFolders ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            folders = unmapped.map {
                Folder(id: $0.path, name: $0.name, path: $0.path, matchState: .matching, include: true)
            }
            await autoMatchAll(rootPath: rootPath)
        } catch {
            loadError = error.localizedDescription
            folders = []
            Self.logger.error("Library import folder load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func autoMatchAll(rootPath: String) async {
        // Match folders one at a time so each row resolves visibly and we never
        // hammer the indexer. Bail the moment the user switches roots.
        for folder in folders {
            guard selectedRootFolderPath == rootPath else { return }
            await matchFolder(id: folder.id, name: folder.name)
        }
    }

    private func matchFolder(id: String, name: String) async {
        let term = searchTerm(for: name)
        guard !term.isEmpty else {
            updateMatch(id: id, state: .noMatch, include: false)
            return
        }
        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                let results = try await client.lookupSeries(term: term)
                if let best = bestSeriesMatch(results), let tvdbId = best.tvdbId {
                    seriesByID[tvdbId] = best
                    updateMatch(id: id, state: .matched(candidate(tvdbId, best.title, best.year, best.posterURL)), include: true)
                } else {
                    updateMatch(id: id, state: .noMatch, include: false)
                }
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                let results = try await client.lookupMovie(term: term)
                if let best = (results.first { $0.tmdbId != nil } ?? results.first), let tmdbId = best.tmdbId {
                    moviesByID[tmdbId] = best
                    updateMatch(id: id, state: .matched(candidate(tmdbId, best.title, best.year, best.posterURL)), include: true)
                } else {
                    updateMatch(id: id, state: .noMatch, include: false)
                }
            case .prowlarr, .bazarr:
                return
            }
        } catch {
            updateMatch(id: id, state: .failed(error.localizedDescription), include: false)
        }
    }

    private func bestSeriesMatch(_ results: [SonarrSeries]) -> SonarrSeries? {
        results.first { $0.tvdbId != nil } ?? results.first
    }

    private func candidate(_ id: Int, _ title: String, _ year: Int?, _ posterURL: URL?) -> ArrImportCandidate {
        ArrImportCandidate(id: id, title: title, year: year, posterURL: posterURL)
    }

    private func updateMatch(id: String, state: MatchState, include: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) {
            folders[index].matchState = state
            folders[index].include = include
        }
    }

    func toggleInclude(_ id: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].isMatched else { return }
        folders[index].include.toggle()
    }

    func applyManualMatch(folderID: String, pick: ArrImportPick) {
        switch pick {
        case .series(let series):
            guard let tvdbId = series.tvdbId else { return }
            seriesByID[tvdbId] = series
            updateMatch(id: folderID, state: .matched(candidate(tvdbId, series.title, series.year, series.posterURL)), include: true)
        case .movie(let movie):
            guard let tmdbId = movie.tmdbId else { return }
            moviesByID[tmdbId] = movie
            updateMatch(id: folderID, state: .matched(candidate(tmdbId, movie.title, movie.year, movie.posterURL)), include: true)
        }
    }

    /// Catalog search used by the manual-match sheet to override an auto-match.
    func searchCatalog(term: String) async -> [ArrImportPick] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return [] }
                return try await client.lookupSeries(term: trimmed).map(ArrImportPick.series)
            case .radarr:
                guard let client = serviceManager.radarrClient else { return [] }
                return try await client.lookupMovie(term: trimmed).map(ArrImportPick.movie)
            case .prowlarr, .bazarr:
                return []
            }
        } catch {
            return []
        }
    }

    // MARK: - Import

    func performImport() async -> Bool {
        guard canImport,
              let qualityProfileId = selectedQualityProfileId,
              let rootPath = selectedRootFolderPath else { return false }
        let targets = folders.filter { $0.include && $0.isMatched }
        guard !targets.isEmpty else { return false }
        isImporting = true
        defer { isImporting = false }

        do {
            let importedTitles: [String]
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return false }
                let bodies = targets.compactMap { sonarrImportBody(for: $0, qualityProfileId: qualityProfileId, rootPath: rootPath) }
                guard !bodies.isEmpty else { return false }
                importedTitles = try await client.importSeries(bodies).map(\.title)
            case .radarr:
                guard let client = serviceManager.radarrClient else { return false }
                let bodies = targets.compactMap { radarrImportBody(for: $0, qualityProfileId: qualityProfileId, rootPath: rootPath) }
                guard !bodies.isEmpty else { return false }
                importedTitles = try await client.importMovies(bodies).map(\.title)
            case .prowlarr, .bazarr:
                return false
            }

            let importedIDs = Set(targets.map(\.id))
            withAnimation(.snappy) {
                folders.removeAll { importedIDs.contains($0.id) }
            }
            serviceManager.lastManualImportTimestamp = Date()
            InAppNotificationCenter.shared.showSuccess(
                title: "Library Import Started",
                message: importSummary(count: importedTitles.count, titles: importedTitles)
            )
            return true
        } catch {
            Self.logger.error("Library import failed: \(error.localizedDescription, privacy: .public)")
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
            return false
        }
    }

    private func sonarrImportBody(for folder: Folder, qualityProfileId: Int, rootPath: String) -> SonarrSeriesImportBody? {
        guard case .matched(let candidate) = folder.matchState,
              let series = seriesByID[candidate.id],
              let tvdbId = series.tvdbId,
              let titleSlug = series.titleSlug else { return nil }
        let seasons = (series.seasons ?? []).map { SonarrAddSeason(seasonNumber: $0.seasonNumber, monitored: true) }
        return SonarrSeriesImportBody(
            tvdbId: tvdbId,
            title: series.title,
            qualityProfileId: qualityProfileId,
            languageProfileId: nil,
            titleSlug: titleSlug,
            images: series.images ?? [],
            seasons: seasons,
            path: folder.path,
            rootFolderPath: rootPath,
            monitored: true,
            seasonFolder: true,
            seriesType: series.seriesType ?? "standard",
            addOptions: SonarrAddOptions(
                monitor: monitorOption,
                searchForMissingEpisodes: searchOnImport,
                searchForCutoffUnmetEpisodes: false
            ),
            tags: nil
        )
    }

    private func radarrImportBody(for folder: Folder, qualityProfileId: Int, rootPath: String) -> RadarrMovieImportBody? {
        guard case .matched(let candidate) = folder.matchState,
              let movie = moviesByID[candidate.id],
              let tmdbId = movie.tmdbId else { return nil }
        return RadarrMovieImportBody(
            title: movie.title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            path: folder.path,
            rootFolderPath: rootPath,
            monitored: true,
            minimumAvailability: movie.minimumAvailability ?? "released",
            addOptions: RadarrAddOptions(searchForMovie: searchOnImport, monitor: monitorOption),
            tags: nil
        )
    }

    private func importSummary(count: Int, titles: [String]) -> String {
        let noun = service == .sonarr
            ? (count == 1 ? "series" : "series")
            : (count == 1 ? "movie" : "movies")
        let maxShown = 4
        let shown = titles.prefix(maxShown).map { "• \($0)" }.joined(separator: "\n")
        let header = "\(count) \(noun) added from your library:"
        if titles.count > maxShown {
            return "\(header)\n\(shown)\n• …and \(titles.count - maxShown) more"
        }
        return "\(header)\n\(shown)"
    }

    // MARK: - Helpers

    private func fetchRootFolders() async throws -> [ArrRootFolder] {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { throw ArrLibraryImportError.clientUnavailable(service) }
            return try await client.getRootFolders()
        case .radarr:
            guard let client = serviceManager.radarrClient else { throw ArrLibraryImportError.clientUnavailable(service) }
            return try await client.getRootFolders()
        case .prowlarr, .bazarr:
            throw ArrLibraryImportError.clientUnavailable(service)
        }
    }

    /// Strips a trailing `(YYYY)` so an organized folder name like "Andor (2022)" or
    /// "Avatar - The Last Airbender (2005)" searches the catalog by its bare title.
    private func searchTerm(for folderName: String) -> String {
        folderName
            .replacingOccurrences(of: #"\s*\((?:19|20)\d{2}\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ArrLibraryImportError: LocalizedError {
    case clientUnavailable(ArrServiceType)

    var errorDescription: String? {
        switch self {
        case .clientUnavailable(let service):
            return "\(service.displayName) client is not available."
        }
    }
}

// MARK: - Screen

struct ArrLibraryImportView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var selectedService: ArrServiceType = .sonarr

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                emptyState
            } else if !hasConnectedService {
                ArrServicesConnectionStatusView(
                    services: availableServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else {
                ArrLibraryImportContent(service: selectedService, serviceManager: serviceManager)
                    .id(selectedService)
                    .safeAreaInset(edge: .top) {
                        if availableServices.count > 1 {
                            TrawlSegmentBar("Service", selection: Binding(
                                get: { selectedService },
                                set: { newService in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        selectedService = newService
                                    }
                                }
                            ), items: availableServices.map(\.segmentBarItem), alignment: .center)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
            }
        }
        .navigationTitle("Library Import")
        .moreDestinationBackground(.manualImport)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Services Configured", systemImage: "square.and.arrow.down.on.square")
        } description: {
            Text("Add a Sonarr or Radarr server in Settings to import an existing library.")
        } actions: {
            MoreSettingsNavigationLink()
        }
        .scrollableUnavailableState()
    }
}

// MARK: - Content

private struct ArrLibraryImportContent: View {
    @State private var model: ArrLibraryImportViewModel
    @State private var matchTarget: MatchTarget?

    init(service: ArrServiceType, serviceManager: ArrServiceManager) {
        _model = State(initialValue: ArrLibraryImportViewModel(service: service, serviceManager: serviceManager))
    }

    private struct MatchTarget: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        @Bindable var model = model

        List {
            Section {
                ArrRootFolderPicker(
                    selection: $model.selectedRootFolderPath,
                    folders: model.rootFolders
                )
            } header: {
                Text("Library Root")
            } footer: {
                Text("Trawl scans this root for folders that aren't in \(model.service.displayName) yet and adopts each one in place — no files are moved or renamed.")
            }

            if model.selectedRootFolderPath != nil {
                foldersSection
                if model.includedMatchedCount > 0 {
                    optionsSection
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .task { model.prepareDefaults() }
        .onChange(of: model.selectedRootFolderPath) {
            Task { await model.loadFolders() }
        }
        .sheet(item: $matchTarget) { target in
            ArrLibraryImportMatchSheet(model: model, folderID: target.id, folderName: target.name)
        }
        .safeAreaInset(edge: .bottom) {
            importBar
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        Section {
            if model.isLoadingFolders && model.folders.isEmpty {
                loadingRow("Scanning \(model.service.displayName) root…")
            } else if let error = model.loadError, model.folders.isEmpty {
                errorRow(error)
            } else if model.folders.isEmpty {
                Text("No unmapped folders — everything in this root is already in \(model.service.displayName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.folders) { folder in
                    folderRow(folder)
                }
            }
        } header: {
            Text(model.folders.isEmpty ? "Folders" : "Unmapped Folders")
        } footer: {
            if !model.folders.isEmpty {
                Text("Tap a row to correct its match. Unmatched folders are skipped.")
            }
        }
    }

    private func folderRow(_ folder: ArrLibraryImportViewModel.Folder) -> some View {
        HStack(spacing: 12) {
            includeControl(folder)

            ArrArtworkView(url: matchedPosterURL(folder)) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: model.service == .sonarr ? "tv" : "film")
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                matchSubtitle(folder)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            matchTarget = .init(id: folder.id, name: folder.name)
        }
    }

    @ViewBuilder
    private func includeControl(_ folder: ArrLibraryImportViewModel.Folder) -> some View {
        switch folder.matchState {
        case .matching:
            ProgressView().controlSize(.small).frame(width: 24)
        case .matched:
            Button {
                model.toggleInclude(folder.id)
            } label: {
                Image(systemName: folder.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(folder.include ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24)
        case .noMatch, .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 24)
        }
    }

    @ViewBuilder
    private func matchSubtitle(_ folder: ArrLibraryImportViewModel.Folder) -> some View {
        switch folder.matchState {
        case .matching:
            Text("Matching…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .matched(let candidate):
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(candidate.year.map { "\(candidate.title) (\($0))" } ?? candidate.title)
                    .font(.caption)
                    .foregroundStyle(folder.include ? .primary : .secondary)
                    .lineLimit(1)
            }
        case .noMatch:
            Text("No match found — tap to search")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private func matchedPosterURL(_ folder: ArrLibraryImportViewModel.Folder) -> URL? {
        if case .matched(let candidate) = folder.matchState { return candidate.posterURL }
        return nil
    }

    @ViewBuilder
    private var optionsSection: some View {
        @Bindable var model = model

        Section {
            ArrQualityProfilePicker(
                selection: $model.selectedQualityProfileId,
                profiles: model.qualityProfiles,
                showInfoButton: false
            )

            Picker("Monitor", selection: $model.monitorOption) {
                ForEach(monitorOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Toggle("Search on Import", isOn: $model.searchOnImport)
        } header: {
            Text("Options")
        } footer: {
            Text("Applied to every imported \(model.service == .sonarr ? "series" : "movie"). **Search on Import** looks for upgrades to the files you already have, so it's usually left off.")
        }
    }

    private var monitorOptions: [(value: String, label: String)] {
        switch model.service {
        case .sonarr:
            return [
                ("all", "All Episodes"),
                ("future", "Future Episodes"),
                ("missing", "Missing Episodes"),
                ("firstSeason", "First Season"),
                ("latestSeason", "Latest Season"),
                ("none", "None")
            ]
        case .radarr:
            return [
                ("movieOnly", "Movie Only"),
                ("movieAndCollection", "Movie and Collection"),
                ("none", "None")
            ]
        case .prowlarr, .bazarr:
            return []
        }
    }

    private var importBar: some View {
        let count = model.includedMatchedCount
        let noun = model.service == .sonarr ? "Series" : (count == 1 ? "Movie" : "Movies")
        return Group {
            if model.selectedRootFolderPath != nil, !model.folders.isEmpty {
                Button {
                    Task { await model.performImport() }
                } label: {
                    HStack {
                        if model.isImporting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(model.isImporting ? "Importing…" : "Import \(count) \(noun)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canImport)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Retry") {
                Task { await model.loadFolders() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Manual match sheet

private struct ArrLibraryImportMatchSheet: View {
    let model: ArrLibraryImportViewModel
    let folderID: String
    let folderName: String

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [ArrImportPick] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    init(model: ArrLibraryImportViewModel, folderID: String, folderName: String) {
        self.model = model
        self.folderID = folderID
        self.folderName = folderName
        // Seed the field with the folder name so the first search is one tap away.
        _query = State(initialValue: folderName)
    }

    var body: some View {
        ArrSheetShell(
            title: "Match Folder",
            subtitle: folderName,
            showsCancel: true
        ) {
            List {
                Section {
                    ArrAddItemSearchBar(
                        text: $query,
                        placeholder: model.service == .sonarr ? "Search TV shows…" : "Search movies…"
                    ) {
                        Task { await search() }
                    }
                }

                if isSearching {
                    Section {
                        HStack { Spacer(); ProgressView("Searching…"); Spacer() }
                    }
                } else if hasSearched && results.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: query)
                    }
                } else if !results.isEmpty {
                    Section("Results") {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, pick in
                            resultRow(pick)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .task {
                if !hasSearched { await search() }
            }
        }
    }

    private func resultRow(_ pick: ArrImportPick) -> some View {
        Button {
            model.applyManualMatch(folderID: folderID, pick: pick)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ArrArtworkView(url: pickPosterURL(pick)) {
                    Rectangle().fill(.quaternary)
                        .overlay(
                            Image(systemName: model.service == .sonarr ? "tv" : "film")
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(pickTitle(pick))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let subtitle = pickSubtitle(pick) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let overview = pickOverview(pick) {
                        Text(overview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false; hasSearched = true }
        results = await model.searchCatalog(term: query)
    }

    private func pickTitle(_ pick: ArrImportPick) -> String {
        switch pick {
        case .series(let s): return s.title
        case .movie(let m): return m.title
        }
    }

    private func pickPosterURL(_ pick: ArrImportPick) -> URL? {
        switch pick {
        case .series(let s): return s.posterURL
        case .movie(let m): return m.posterURL
        }
    }

    private func pickSubtitle(_ pick: ArrImportPick) -> String? {
        switch pick {
        case .series(let s):
            var parts: [String] = []
            if let year = s.year { parts.append(String(year)) }
            if let network = s.network { parts.append(network) }
            if let status = s.status { parts.append(status.capitalized) }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        case .movie(let m):
            var parts: [String] = []
            if let year = m.year { parts.append(String(year)) }
            if let status = m.status { parts.append(status.capitalized) }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }
    }

    private func pickOverview(_ pick: ArrImportPick) -> String? {
        switch pick {
        case .series(let s): return s.overview
        case .movie(let m): return m.overview
        }
    }
}
