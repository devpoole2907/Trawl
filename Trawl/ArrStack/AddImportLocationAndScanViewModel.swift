import SwiftUI
import SwiftData
import OSLog

struct AddImportLocationSheet: View {
    let service: ArrServiceType
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var path = ""
    @State private var showingBrowser = false

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedPath.isEmpty && isAbsoluteImportPath(trimmedPath)
    }

    var body: some View {
        AppSheetShell(
            title: "Add Location",
            confirmTitle: "Add",
            isConfirmDisabled: !canAdd,
            onConfirm: {
                onAdd(trimmedPath)
                dismiss()
            },
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Form {
                Section {
                    HStack {
                        TextField("Absolute path on server", text: $path)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        if browserSource != nil {
                            Button {
                                showingBrowser = true
                            } label: {
                                Label("Browse", systemImage: "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    if !trimmedPath.isEmpty && !isAbsoluteImportPath(trimmedPath) {
                        Text("Path must be absolute, e.g. /downloads/completed")
                            .foregroundStyle(.red)
                    } else {
                        Text("Example: /downloads/completed. Paths are on the \(service.displayName) server or container.")
                    }
                }

                Section {
                    Text("This location will be saved for \(service.displayName).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showingBrowser) {
                if let source = browserSource {
                    NavigationStack {
                        RemotePathBrowserView(
                            title: "\(service.displayName) Folders",
                            source: source,
                            initialPath: path
                        ) { selectedPath in
                            path = selectedPath
                        }
                    }
                }
            }
        }
    }

    private var browserSource: RemotePathBrowserSource? {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { return nil }
            return Self.source(serviceName: "Sonarr", client: client)
        case .radarr:
            guard let client = serviceManager.radarrClient else { return nil }
            return Self.source(serviceName: "Radarr", client: client)
        case .prowlarr, .bazarr:
            return nil
        }
    }

    private static func source<Client: SharedArrClient>(serviceName: String, client: Client) -> RemotePathBrowserSource {
        RemotePathBrowserSource(
            serviceName: serviceName,
            loadRoots: {
                try await client.getFileSystem(path: "", includeFiles: false).map(\.remotePathEntry)
            },
            loadChildren: { path in
                try await client.getFileSystem(path: path, includeFiles: false).map(\.remotePathEntry)
            }
        )
    }
}

// MARK: - Scan View Model

@Observable
@MainActor
final class ManualImportScanViewModel {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trawl", category: "ArrManualImportView")
    private let progressiveRevealBatchSize = 25
    private let progressiveRevealDelay: Duration = .milliseconds(16)

    let path: String
    let service: ArrServiceType
    let serviceManager: ArrServiceManager
    let libraryItemID: Int?

    var isScanning = false
    var isImporting = false
    var importableFiles: [ManualImportItem] = []
    var blockedFiles: [ManualImportItem] = []
    var groupedImportableFiles: [ManualImportGroup] = []
    var groupedNewImportableFiles: [ManualImportGroup] = []
    var groupedInLibraryFiles: [ManualImportGroup] = []
    var groupedIdentifiedPendingAddFiles: [ManualImportGroup] = []
    var groupedUnidentifiedFiles: [ManualImportGroup] = []
    var groupedBlockedFiles: [ManualImportGroup] = []
    var inLibraryItemIDs: Set<String> = []
    var isLoadingInLibraryStatus = false
    var selectedFiles: Set<String> = []
    var selectedBlockedFiles: Set<String> = []
    var navigationAction: (() -> Void)?
    var seasonFolder: Bool = true
    var hasPerformedInitialScan = false
    var scanStatusMessage = "Preparing scan…"

    // Identify sheet
    var identifyingTarget: ManualImportIdentifyTarget?
    var libraryMovies: [RadarrMovie] = []
    var librarySeries: [SonarrSeries] = []
    var qualityProfiles: [ArrQualityProfile] = []
    var isLoadingLibrary = false
    var catalogMovieResults: [RadarrMovie] = []
    var catalogSeriesResults: [SonarrSeries] = []
    var isSearchingCatalog = false
    var isAddingToLibrary = false
    var autoSuggestionMovies: [RadarrMovie] = []
    var autoSuggestionSeries: [SonarrSeries] = []
    var isLoadingAutoSuggestions = false
    var isAutoIdentifying = false
    var autoIdentifyCurrentFileName: String?
    var autoIdentifyEnabled = true
    var autoIdentifyProcessedCount = 0
    var autoIdentifyLastMatchedTitle: String?
    var autoIdentifyLastOutcomeMessage: String?
    private var lastAutoSuggestionFilename: String?
    @ObservationIgnored private var autoIdentifyTask: Task<Void, Never>?

    init(path: String, service: ArrServiceType, serviceManager: ArrServiceManager, libraryItemID: Int? = nil) {
        self.path = path
        self.service = service
        self.serviceManager = serviceManager
        self.libraryItemID = libraryItemID
    }

    var folderName: String {
        (path as NSString).lastPathComponent
    }

    var isBusy: Bool {
        isScanning || isImporting
    }

    var allSelected: Bool {
        let totalCount = importableFiles.count + blockedFiles.count
        guard totalCount > 0 else { return false }
        return selectedFiles.count + selectedBlockedFiles.count == totalCount
    }

    var hasAnySelection: Bool {
        !selectedFiles.isEmpty || !selectedBlockedFiles.isEmpty
    }

    var selectedBlockedItems: [ManualImportItem] {
        blockedFiles.filter { selectedBlockedFiles.contains($0.id) }
    }

    var selectedReadyGroups: [ManualImportGroup] {
        selectedGroups(from: groupedImportableFiles, selectedIDs: selectedFiles)
    }

    var selectedBlockedGroups: [ManualImportGroup] {
        selectedGroups(from: groupedIdentifiedPendingAddFiles + groupedUnidentifiedFiles + groupedBlockedFiles, selectedIDs: selectedBlockedFiles)
    }

    var unresolvedUnidentifiedCount: Int {
        blockedFiles.count(where: \.isAutoMatchCandidate)
    }

    var blockedWithRejectionCount: Int {
        blockedFiles.count(where: { !$0.isAutoMatchCandidate })
    }

    func toggleSelectAll() {
        if allSelected {
            selectedFiles.removeAll()
            selectedBlockedFiles.removeAll()
        } else {
            selectedFiles = Set(importableFiles.map(\.id))
            selectedBlockedFiles = Set(blockedFiles.map(\.id))
        }
    }

    func toggleFile(_ id: String) {
        if selectedFiles.contains(id) {
            selectedFiles.remove(id)
        } else {
            selectedFiles.insert(id)
        }
    }

    func toggleBlockedFile(_ id: String) {
        if selectedBlockedFiles.contains(id) {
            selectedBlockedFiles.remove(id)
        } else {
            selectedBlockedFiles.insert(id)
        }
    }

    private func selectedGroups(from groups: [ManualImportGroup], selectedIDs: Set<String>) -> [ManualImportGroup] {
        groups.compactMap { group in
            let selectedItems = group.items.filter { selectedIDs.contains($0.id) }
            guard !selectedItems.isEmpty else { return nil }
            return ManualImportGroup(
                kind: group.kind,
                displayTitle: group.displayTitle,
                posterURL: group.posterURL,
                items: selectedItems
            )
        }
    }

    func loadFiles() async {
        isScanning = true
        scanStatusMessage = "Preparing scan…"
        let shouldResumeAutoIdentify = autoIdentifyEnabled
        if autoIdentifyTask != nil {
            stopAutoIdentify()
            autoIdentifyEnabled = shouldResumeAutoIdentify
        }
        defer { isScanning = false }

        do {
            Self.logger.info("Manual import scan starting for \(self.service.displayName, privacy: .public) path \(self.path, privacy: .public) libraryItemID \(self.libraryItemID ?? -1)")
            scanStatusMessage = "Contacting \(service.displayName)…"
            let jsonValues = try await getManualImport(folder: path)
            Self.logger.info("Manual import scan received \(jsonValues.count) raw items from \(self.service.displayName, privacy: .public)")
            scanStatusMessage = "Parsing \(jsonValues.count) items…"
            Self.logManualImportShapeForUnidentifiedItems(jsonValues)
            let scannedFiles = await Task.detached(priority: .userInitiated) {
                Self.parseManualImportItems(from: jsonValues)
            }.value
            hasPerformedInitialScan = true
            Self.logger.info("Manual import scan parsed \(scannedFiles.count) items for \(self.path, privacy: .public)")

            importableFiles = []
            blockedFiles = []
            inLibraryItemIDs = []
            recomputeGroups()
            autoIdentifyProcessedCount = 0
            autoIdentifyLastMatchedTitle = nil
            autoIdentifyLastOutcomeMessage = nil

            var nextImportableBatch: [ManualImportItem] = []
            var nextBlockedBatch: [ManualImportItem] = []
            let dynamicBatchSize = max(progressiveRevealBatchSize, scannedFiles.count / 20)

            for (index, file) in scannedFiles.enumerated() {
                if file.isImportable {
                    nextImportableBatch.append(file)
                } else {
                    nextBlockedBatch.append(file)
                }

                let reachedBatchBoundary = index > 0 && index.isMultiple(of: dynamicBatchSize)
                let isLastItem = index == scannedFiles.indices.last

                if reachedBatchBoundary || isLastItem {
                    let revealedCount = index + 1
                    scanStatusMessage = "Loading \(revealedCount) of \(scannedFiles.count) files…"
                    withAnimation(.snappy) {
                        importableFiles.append(contentsOf: nextImportableBatch)
                        blockedFiles.append(contentsOf: nextBlockedBatch)
                        recomputeGroups()
                    }
                    Self.logger.debug("Manual import scan revealed batch up to item \(revealedCount) of \(scannedFiles.count); importable \(self.importableFiles.count) blocked \(self.blockedFiles.count)")
                    nextImportableBatch.removeAll(keepingCapacity: true)
                    nextBlockedBatch.removeAll(keepingCapacity: true)

                    if !isLastItem {
                        try await Task.sleep(for: progressiveRevealDelay)
                    }
                }
            }

            let availableIDs = Set(importableFiles.map(\.id))
            selectedFiles = selectedFiles.intersection(availableIDs)
            let blockedIDs = Set(blockedFiles.map(\.id))
            selectedBlockedFiles = selectedBlockedFiles.intersection(blockedIDs)
            scanStatusMessage = "Loaded \(scannedFiles.count) files"
            Self.logger.info("Manual import scan finished for \(self.path, privacy: .public); importable \(self.importableFiles.count) blocked \(self.blockedFiles.count)")
            if autoIdentifyEnabled {
                startAutoIdentify()
            }
        } catch is CancellationError {
            Self.logger.info("Manual import scan cancelled for \(self.path, privacy: .public)")
            scanStatusMessage = "Scan cancelled"
            importableFiles = []
            blockedFiles = []
            inLibraryItemIDs = []
            recomputeGroups()
            selectedFiles = []
            selectedBlockedFiles = []
            autoIdentifyCurrentFileName = nil
            autoIdentifyProcessedCount = 0
            autoIdentifyLastMatchedTitle = nil
            autoIdentifyLastOutcomeMessage = nil
        } catch {
            Self.logger.error("Manual import scan failed for \(self.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            scanStatusMessage = "Scan failed: \(error.localizedDescription)"
            InAppNotificationCenter.shared.showError(title: "Scan Failed", message: error.localizedDescription)
            importableFiles = []
            blockedFiles = []
            inLibraryItemIDs = []
            recomputeGroups()
            selectedFiles = []
            selectedBlockedFiles = []
            autoIdentifyCurrentFileName = nil
            autoIdentifyProcessedCount = 0
            autoIdentifyLastMatchedTitle = nil
            autoIdentifyLastOutcomeMessage = nil
        }
    }

    private func autoResolvePendingAddItems() async {
        let pendingAddIDs = selectedBlockedFiles.filter { id in
            blockedFiles.first(where: { $0.id == id })?.isIdentifiedPendingAdd ?? false
        }
        guard !pendingAddIDs.isEmpty else { return }

        let pendingAddItems = blockedFiles.filter { pendingAddIDs.contains($0.id) }

        for group in Dictionary(grouping: pendingAddItems, by: \.catalogID).values {
            let items = Array(group)
            guard !items.isEmpty else { continue }

            let ids = Set(items.map(\.id))

            var resolved = false
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { continue }
                guard let tvdbId = items.first?.catalogID else { continue }
                if let match = librarySeries.first(where: { $0.tvdbId == tvdbId }) {
                    applyIdentification(to: items, mediaID: match.id, title: match.title, posterURL: posterURL(from: match.images))
                    resolved = true
                } else if let candidate = try? await client.lookupSeriesByTvdb(tvdbId: tvdbId) {
                    resolved = await addToLibraryAndIdentify(blockedItems: items, series: candidate, importAfterAdding: false)
                }
            case .radarr:
                guard let client = serviceManager.radarrClient else { continue }
                guard let tmdbId = items.first?.catalogID else { continue }
                if let match = libraryMovies.first(where: { $0.tmdbId == tmdbId }) {
                    applyIdentification(to: items, mediaID: match.id, title: match.title, posterURL: posterURL(from: match.images))
                    resolved = true
                } else if let candidate = try? await client.lookupMovieByTmdb(tmdbId: tmdbId) {
                    resolved = await addToLibraryAndIdentify(blockedItems: items, movie: candidate, importAfterAdding: false)
                }
            case .prowlarr, .bazarr:
                continue
            }

            guard resolved else { continue }
            if importableFiles.contains(where: { ids.contains($0.id) }) {
                selectedFiles.formUnion(ids)
            }
        }
    }

    func performImport() async -> Bool {
        // Auto-resolve any pending-add items (identified but not yet in library)
        // so they are added to the library and imported in one step.
        await autoResolvePendingAddItems()

        let availableIDs = Set(importableFiles.map(\.id))
        selectedFiles = selectedFiles.intersection(availableIDs)
        let remainingBlockedIDs = Set(blockedFiles.map(\.id))
        selectedBlockedFiles = selectedBlockedFiles.intersection(remainingBlockedIDs)

        guard selectedBlockedFiles.isEmpty else {
            InAppNotificationCenter.shared.showError(
                title: "Import Needs Review",
                message: "Some selected files are still blocked or could not be added. Review the identified and unidentified sections, then try again."
            )
            return false
        }

        guard !selectedFiles.isEmpty else { return false }
        isImporting = true
        defer { isImporting = false }

        let importedIDs = selectedFiles
        let savedItems = importableFiles.filter { importedIDs.contains($0.id) }
        let filesToImport = savedItems.map { $0.importJSON(service: service, seasonFolder: seasonFolder) }

        do {
            let count = filesToImport.count
            let navAction = navigationAction
            let tabName = service == .sonarr ? "Series" : "Movies"
            let fileWord = count == 1 ? "file" : "files"
            let notificationCenter = InAppNotificationCenter.shared
            let fileNamesSummary = importedFileNamesSummary(items: savedItems)

            let fileMeta = savedItems.map { "\($0.fileName) mediaID:\($0.mediaID?.description ?? "nil")" }
            Self.logger.info("Sending \(count) \(fileWord) to \(self.service.displayName, privacy: .public): \(fileMeta, privacy: .private)")

            // Optimistically remove from list while command runs
            withAnimation(.snappy) {
                importableFiles.removeAll { importedIDs.contains($0.id) }
                recomputeGroups()
            }
            selectedFiles = []

            // Wait for the manual import command to reach a terminal state.
            let command = try await manualImport(files: filesToImport)
            Self.logger.info("Command finished — id:\(command.id ?? -1) status:\(command.status ?? "nil", privacy: .public) exception:\(command.exception ?? "none", privacy: .private)")

            if !command.isTerminal {
                Self.logger.info("Command \(command.id ?? -1) is still running with status \(command.status ?? "unknown", privacy: .public)")
                notificationCenter.showSuccess(
                    title: "Import Started",
                    message: "\(count) \(fileWord) submitted to \(service.displayName). Import is still running."
                )
                return false
            }

            if command.succeeded {
                // Items were already optimistically removed. Don't reload — rescanning the folder
                // will find the file again (hardlinks/copies leave the source in place) and undo
                // the removal, making it look like the import failed when it didn't.
                notificationCenter.showSuccess(
                    title: "Import Complete",
                    message: "\(count) \(fileWord) imported by \(service.displayName):\n\(fileNamesSummary)",
                    action: navAction.map { InAppBannerAction(label: "View \(tabName)", handler: $0) }
                )
                return true
            } else {
                let reason = manualImportFailureMessage(for: command)
                Self.logger.error("Command failed — \(reason, privacy: .private)")
                notificationCenter.showError(title: "Import Failed", message: reason)
                withAnimation(.snappy) {
                    importableFiles.append(contentsOf: savedItems)
                    recomputeGroups()
                }
                selectedFiles = importedIDs
                return false
            }
        } catch is CancellationError {
            Self.logger.info("Task cancelled")
            return false
        } catch ArrError.commandTimeout(let commandId, let lastKnownCommand) {
            Self.logger.error("Manual import command timed out while waiting — id:\(commandId ?? -1) status:\(lastKnownCommand?.status ?? "unknown", privacy: .public)")
            InAppNotificationCenter.shared.showSuccess(
                title: "Import Started",
                message: "\(savedItems.count) \(savedItems.count == 1 ? "file" : "files") submitted to \(service.displayName). The import is still running; check Activity for progress."
            )
            return false
        } catch {
            Self.logger.error("Threw error — \(error, privacy: .private)")
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
            withAnimation(.snappy) {
                importableFiles.append(contentsOf: savedItems)
                recomputeGroups()
            }
            selectedFiles = importedIDs
            return false
        }
    }


    private func importedFileNamesSummary(items: [ManualImportItem]) -> String {
        let names = items.map { ($0.fileName as NSString).lastPathComponent }
        let maxShown = 4
        if names.count <= maxShown {
            return names.map { "• \($0)" }.joined(separator: "\n")
        }
        let visible = names.prefix(maxShown).map { "• \($0)" }.joined(separator: "\n")
        let remaining = names.count - maxShown
        return "\(visible)\n• …and \(remaining) more"
    }

    private func manualImportFailureMessage(for command: ArrCommand) -> String {
        if let exception = command.exception?.trimmingCharacters(in: .whitespacesAndNewlines),
           !exception.isEmpty {
            return exception
        }

        let status = command.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let status, !status.isEmpty {
            return "\(service.displayName) manual import ended with status '\(status)' and no detailed error message. Check Activity or History for the exact rejection reason."
        }

        return "\(service.displayName) did not return a detailed manual import error. Check Activity or History for the exact rejection reason."
    }

    private func getManualImport(folder: String) async throws -> [JSONValue] {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            Self.logger.info("Requesting Sonarr manual import scan for \(folder, privacy: .private)")
            return try await client.getManualImport(
                folder: folder,
                libraryItemId: libraryItemID,
                libraryItemIDQueryName: "seriesId"
            )
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            Self.logger.info("Requesting Radarr manual import scan for \(folder, privacy: .private)")
            return try await client.getManualImport(
                folder: folder,
                libraryItemId: libraryItemID,
                libraryItemIDQueryName: "movieId"
            )
        case .prowlarr, .bazarr:
            throw ManualImportServiceClientUnavailableError(service: service)
        }
    }

    @discardableResult
    private func manualImport(files: [JSONValue]) async throws -> ArrCommand {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            return try await client.manualImport(files: files)
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            return try await client.manualImport(files: files)
        case .prowlarr, .bazarr:
            throw ManualImportServiceClientUnavailableError(service: service)
        }
    }

    // MARK: - Identify

    func beginIdentifying(_ item: ManualImportItem) {
        resetCatalogSearchState()
        let target = ManualImportIdentifyTarget(
            id: "item-\(item.id)",
            items: [item],
            displayLabel: item.fileName
        )
        identifyingTarget = target
        Task { [weak self] in await self?.loadLibraryIfNeeded() }
        Task { [weak self] in await self?.loadAutoSuggestions(for: item.fileName) }
    }

    func beginIdentifying(group: ManualImportGroup) {
        guard let first = group.items.first else { return }
        resetCatalogSearchState()
        let label: String
        if group.items.count == 1 {
            label = first.fileName
        } else {
            label = "\(group.displayTitle) · \(group.items.count) files"
        }
        let target = ManualImportIdentifyTarget(
            id: group.id,
            items: group.items,
            displayLabel: label
        )
        identifyingTarget = target
        Task { [weak self] in await self?.loadLibraryIfNeeded() }
        Task { [weak self] in await self?.loadAutoSuggestions(for: first.fileName) }
    }

    /// Catalog search results live on the view model so they persist across SwiftUI body
    /// re-evaluations, but that means a previous sheet's hits would otherwise bleed into
    /// the next sheet before the user types anything.
    private func resetCatalogSearchState() {
        catalogMovieResults = []
        catalogSeriesResults = []
        isSearchingCatalog = false
    }

    func loadInLibraryStatus() async {
        guard !importableFiles.isEmpty, !isLoadingInLibraryStatus else { return }
        isLoadingInLibraryStatus = true
        defer { isLoadingInLibraryStatus = false }
        var found: Set<String> = []
        switch service {
        case .radarr:
            for item in importableFiles {
                guard let mid = item.mediaID else { continue }
                if libraryMovies.first(where: { $0.id == mid })?.hasFile == true {
                    found.insert(item.id)
                }
            }
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { break }
            let seriesIDs = Set(importableFiles.compactMap(\.mediaID))
            var episodeKeys: Set<String> = []
            await withTaskGroup(of: [String].self) { group in
                for sid in seriesIDs {
                    group.addTask {
                        (try? await client.getEpisodes(seriesId: sid))?.compactMap { ep in
                            ep.hasFile == true ? "\(sid)-\(ep.seasonNumber)-\(ep.episodeNumber)" : nil
                        } ?? []
                    }
                }
                for await keys in group { episodeKeys.formUnion(keys) }
            }
            for item in importableFiles {
                guard let mid = item.mediaID,
                      let s = item.seasonNumber,
                      let ep = item.episodes.first else { continue }
                if episodeKeys.contains("\(mid)-\(s)-\(ep.number)") { found.insert(item.id) }
            }
        case .prowlarr, .bazarr:
            break
        }
        withAnimation(.snappy) {
            inLibraryItemIDs = found
            recomputeGroups()
        }
    }

    func loadLibraryIfNeeded() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                async let seriesResult = client.getSeries()
                async let profilesResult = client.getQualityProfiles()
                librarySeries = try await seriesResult
                qualityProfiles = try await profilesResult
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                async let moviesResult = client.getMovies()
                async let profilesResult = client.getQualityProfiles()
                libraryMovies = try await moviesResult
                qualityProfiles = try await profilesResult
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            // Silently fail — user will see an empty list in the sheet
        }
    }

    func loadAutoSuggestions(for filename: String) async {
        guard filename != lastAutoSuggestionFilename else { return }
        lastAutoSuggestionFilename = filename
        withAnimation(.snappy) {
            autoSuggestionMovies = []
            autoSuggestionSeries = []
            isLoadingAutoSuggestions = true
        }
        let term = extractTitleFromFilename(filename)
        guard !term.isEmpty else {
            withAnimation(.snappy) { isLoadingAutoSuggestions = false }
            return
        }
        do {
            switch service {
            case .radarr:
                guard let client = serviceManager.radarrClient else {
                    withAnimation(.snappy) { isLoadingAutoSuggestions = false }
                    return
                }
                let results = try await client.lookupMovie(term: term)
                withAnimation(.snappy) {
                    autoSuggestionMovies = results
                    isLoadingAutoSuggestions = false
                }
            case .sonarr:
                guard let client = serviceManager.sonarrClient else {
                    withAnimation(.snappy) { isLoadingAutoSuggestions = false }
                    return
                }
                let results = try await client.lookupSeries(term: term)
                withAnimation(.snappy) {
                    autoSuggestionSeries = results
                    isLoadingAutoSuggestions = false
                }
            case .prowlarr, .bazarr:
                withAnimation(.snappy) { isLoadingAutoSuggestions = false }
            }
        } catch {
            withAnimation(.snappy) { isLoadingAutoSuggestions = false }
        }
    }

    func startAutoIdentify() {
        autoIdentifyEnabled = true
        guard autoIdentifyTask == nil else { return }
        autoIdentifyLastMatchedTitle = nil
        autoIdentifyLastOutcomeMessage = "Preparing auto match…"
        Self.logger.info("Auto-identify requested for \(self.path, privacy: .private); unresolved \(self.unresolvedUnidentifiedCount) blocked-with-rejection \(self.blockedWithRejectionCount)")
        autoIdentifyTask = Task { [weak self] in
            await self?.runAutoIdentifyLoop()
        }
    }

    func stopAutoIdentify() {
        autoIdentifyEnabled = false
        autoIdentifyTask?.cancel()
        autoIdentifyTask = nil
        autoIdentifyCurrentFileName = nil
        autoIdentifyLastOutcomeMessage = "Auto match stopped."
        withAnimation(.snappy) {
            isAutoIdentifying = false
        }
    }

    private func runAutoIdentifyLoop() async {
        await loadLibraryIfNeeded()
        let hasPending = !groupedUnidentifiedFiles.isEmpty
        guard hasPending else {
            if blockedWithRejectionCount > 0 {
                autoIdentifyLastOutcomeMessage = "No files are eligible for auto match. \(blockedWithRejectionCount) blocked files need manual review."
            } else {
                autoIdentifyLastOutcomeMessage = "No unidentified files need auto match."
            }
            Self.logger.info("Auto-identify found no eligible groups for \(self.path, privacy: .public); blocked-with-rejection \(self.blockedWithRejectionCount)")
            autoIdentifyTask = nil
            autoIdentifyCurrentFileName = nil
            return
        }

        autoIdentifyLastOutcomeMessage = "Auto match is running."
        withAnimation(.snappy) { isAutoIdentifying = true }
        defer {
            if !Task.isCancelled {
                autoIdentifyTask = nil
                autoIdentifyCurrentFileName = nil
                withAnimation(.snappy) { isAutoIdentifying = false }
            }
        }

        // Track groups we couldn't match this run so the loop progresses past them
        // instead of repeatedly retrying the same untranslatable filename.
        var skippedGroupIDs: Set<String> = []

        while autoIdentifyEnabled {
            try? Task.checkCancellation()
            guard let group = groupedUnidentifiedFiles.first(where: { !skippedGroupIDs.contains($0.id) }) else {
                return
            }
            guard let representative = group.items.first else {
                skippedGroupIDs.insert(group.id)
                continue
            }
            autoIdentifyCurrentFileName = representative.fileName

            let term: String
            let parsed = extractTitleFromFilename(representative.fileName)
            if !parsed.isEmpty {
                term = parsed
            } else if !group.displayTitle.isEmpty, group.displayTitle != representative.fileName {
                term = group.displayTitle
            } else {
                skippedGroupIDs.insert(group.id)
                autoIdentifyLastOutcomeMessage = "Couldn't infer a title for \(representative.fileName)."
                continue
            }

            let groupID = group.id

            do {
                switch service {
                case .sonarr:
                    guard let client = serviceManager.sonarrClient else { return }
                    let results = try await client.lookupSeries(term: term)
                    // After the network round-trip, re-read the group from the recomputed
                    // unidentified list. The user may have manually identified some/all of
                    // these files in the meantime — only cascade to whatever's still pending.
                    guard let pending = pendingItems(forGroupID: groupID) else { continue }
                    if let match = results
                        .compactMap({ result in librarySeries.first(where: { $0.tvdbId == result.tvdbId }) })
                        .first {
                        autoIdentifyProcessedCount += pending.count
                        autoIdentifyLastMatchedTitle = match.title
                        autoIdentifyLastOutcomeMessage = pending.count == 1
                            ? "Matched \(pending[0].fileName) to \(match.title)."
                            : "Matched \(pending.count) \(group.displayTitle) files to \(match.title)."
                        applyIdentification(to: pending, mediaID: match.id, title: match.title, posterURL: posterURL(from: match.images))
                    } else if let candidate = results.first {
                        autoIdentifyProcessedCount += pending.count
                        autoIdentifyLastMatchedTitle = candidate.title
                        autoIdentifyLastOutcomeMessage = pending.count == 1
                            ? "Identified \(pending[0].fileName) as \(candidate.title). It will be added when you import."
                            : "Identified \(pending.count) \(group.displayTitle) files as \(candidate.title). They will be added when you import."
                        applyPendingAddIdentification(to: pending, title: candidate.title, catalogID: candidate.tvdbId, posterURL: posterURL(from: candidate.images))
                    } else {
                        skippedGroupIDs.insert(groupID)
                        autoIdentifyLastOutcomeMessage = "No library match found for \(group.displayTitle)."
                    }
                case .radarr:
                    guard let client = serviceManager.radarrClient else { return }
                    let results = try await client.lookupMovie(term: term)
                    guard let pending = pendingItems(forGroupID: groupID) else { continue }
                    if let match = results
                        .compactMap({ result in libraryMovies.first(where: { $0.tmdbId == result.tmdbId }) })
                        .first {
                        autoIdentifyProcessedCount += pending.count
                        autoIdentifyLastMatchedTitle = match.title
                        autoIdentifyLastOutcomeMessage = pending.count == 1
                            ? "Matched \(pending[0].fileName) to \(match.title)."
                            : "Matched \(pending.count) \(group.displayTitle) files to \(match.title)."
                        applyIdentification(to: pending, mediaID: match.id, title: match.title, posterURL: posterURL(from: match.images))
                    } else if let candidate = results.first {
                        autoIdentifyProcessedCount += pending.count
                        autoIdentifyLastMatchedTitle = candidate.title
                        autoIdentifyLastOutcomeMessage = pending.count == 1
                            ? "Identified \(pending[0].fileName) as \(candidate.title). It will be added when you import."
                            : "Identified \(pending.count) \(group.displayTitle) files as \(candidate.title). They will be added when you import."
                        applyPendingAddIdentification(to: pending, title: candidate.title, catalogID: candidate.tmdbId, posterURL: posterURL(from: candidate.images))
                    } else {
                        skippedGroupIDs.insert(groupID)
                        autoIdentifyLastOutcomeMessage = "No library match found for \(group.displayTitle)."
                    }
                case .prowlarr, .bazarr:
                    return
                }
                try await Task.sleep(for: .milliseconds(150))
            } catch is CancellationError {
                return
            } catch {
                skippedGroupIDs.insert(groupID)
                autoIdentifyLastOutcomeMessage = "Auto match skipped \(group.displayTitle): \(error.localizedDescription)"
                Self.logger.error("Auto-identify skipped \(group.displayTitle, privacy: .private): \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Returns the items currently pending identification for the given group, or nil if the
    /// group has been fully resolved (e.g. by a manual identification that ran while we were
    /// awaiting the catalog lookup).
    private func pendingItems(forGroupID groupID: String) -> [ManualImportItem]? {
        guard let current = groupedUnidentifiedFiles.first(where: { $0.id == groupID }),
              !current.items.isEmpty else { return nil }
        return current.items
    }

    func searchCatalog(term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            catalogMovieResults = []
            catalogSeriesResults = []
            return
        }
        isSearchingCatalog = true
        defer { isSearchingCatalog = false }
        do {
            switch service {
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                catalogMovieResults = try await client.lookupMovie(term: trimmed)
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                catalogSeriesResults = try await client.lookupSeries(term: trimmed)
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            // Leave existing results, user can retry
        }
    }

    func applyIdentification(to item: ManualImportItem, mediaID: Int, title: String, posterURL: URL?) {
        applyIdentification(to: [item], mediaID: mediaID, title: title, posterURL: posterURL)
    }

    func applyIdentification(to items: [ManualImportItem], mediaID: Int, title: String, posterURL: URL?) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        let identified = items.map { $0.withIdentification(mediaID: mediaID, title: title, posterURL: posterURL) }
        let identifiedIDs = Set(identified.map(\.id))

        withAnimation(.snappy) {
            blockedFiles.removeAll { ids.contains($0.id) }
            selectedBlockedFiles.subtract(ids)
            importableFiles.removeAll { ids.contains($0.id) }
            selectedFiles.subtract(ids)
            importableFiles.append(contentsOf: identified)
            recomputeGroups()
            selectedFiles.formUnion(identifiedIDs)
        }
        if identifyingTarget.map({ !ids.isDisjoint(with: Set($0.items.map(\.id))) }) ?? false {
            identifyingTarget = nil
        }
        if autoIdentifyEnabled, autoIdentifyTask == nil, unresolvedUnidentifiedCount > 0 {
            startAutoIdentify()
        }
        Task { [weak self] in await self?.loadInLibraryStatus() }
    }

    func applyPendingAddIdentification(to items: [ManualImportItem], title: String, catalogID: Int?, posterURL: URL?) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        let identified = items.map { $0.withPendingAddIdentification(title: title, catalogID: catalogID, posterURL: posterURL) }

        withAnimation(.snappy) {
            blockedFiles.removeAll { ids.contains($0.id) }
            selectedBlockedFiles.subtract(ids)
            importableFiles.removeAll { ids.contains($0.id) }
            selectedFiles.subtract(ids)
            blockedFiles.append(contentsOf: identified)
            recomputeGroups()
        }
        if identifyingTarget.map({ !ids.isDisjoint(with: Set($0.items.map(\.id))) }) ?? false {
            identifyingTarget = nil
        }
        if autoIdentifyEnabled, autoIdentifyTask == nil, unresolvedUnidentifiedCount > 0 {
            startAutoIdentify()
        }
    }

    @discardableResult
    func addToLibraryAndIdentify(blockedItems: [ManualImportItem], movie: RadarrMovie, importAfterAdding: Bool = true) async -> Bool {
        guard !blockedItems.isEmpty,
              let client = serviceManager.radarrClient,
              let tmdbId = movie.tmdbId,
              let rootFolder = serviceManager.radarrRootFolders.first?.path,
              let qualityProfileId = qualityProfiles.first?.id else { return false }

        isAddingToLibrary = true

        let resolvedMovie: RadarrMovie
        do {
            let body = RadarrAddMovieBody(
                title: movie.title,
                tmdbId: tmdbId,
                qualityProfileId: qualityProfileId,
                rootFolderPath: rootFolder,
                monitored: true,
                minimumAvailability: "released",
                addOptions: RadarrAddOptions(searchForMovie: false, monitor: nil),
                tags: nil
            )
            let added = try await client.addMovie(body)
            storeLibraryMovie(added)
            resolvedMovie = added
        } catch {
            if let existing = await existingLibraryMovieMatch(for: movie, after: error) {
                resolvedMovie = existing
            } else {
                isAddingToLibrary = false
                InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: error.localizedDescription)
                return false
            }
        }

        applyIdentification(to: blockedItems, mediaID: resolvedMovie.id, title: resolvedMovie.title, posterURL: posterURL(from: resolvedMovie.images))
        // Release the "Adding to library…" state before the (potentially long) import wait so
        // other identify sheets aren't blocked by a flag that no longer reflects what's happening.
        isAddingToLibrary = false

        if importAfterAdding {
            await importIdentifiedCascade(originalIDs: Set(blockedItems.map(\.id)))
        }
        return true
    }

    @discardableResult
    func addToLibraryAndIdentify(blockedItems: [ManualImportItem], series: SonarrSeries, importAfterAdding: Bool = true) async -> Bool {
        guard !blockedItems.isEmpty,
              let client = serviceManager.sonarrClient,
              let tvdbId = series.tvdbId,
              let titleSlug = series.titleSlug,
              let rootFolder = serviceManager.sonarrRootFolders.first?.path,
              let qualityProfileId = qualityProfiles.first?.id else { return false }

        isAddingToLibrary = true

        let resolvedSeries: SonarrSeries
        do {
            let seasons = (series.seasons ?? []).map {
                SonarrAddSeason(seasonNumber: $0.seasonNumber, monitored: importAfterAdding)
            }
            let body = SonarrAddSeriesBody(
                tvdbId: tvdbId,
                title: series.title,
                qualityProfileId: qualityProfileId,
                languageProfileId: nil,
                titleSlug: titleSlug,
                images: series.images ?? [],
                seasons: seasons,
                rootFolderPath: rootFolder,
                monitored: true,
                seasonFolder: true,
                seriesType: "standard",
                addOptions: SonarrAddOptions(
                    monitor: importAfterAdding ? "all" : "none",
                    searchForMissingEpisodes: importAfterAdding,
                    searchForCutoffUnmetEpisodes: false
                ),
                tags: nil
            )
            let added = try await client.addSeries(body)
            storeLibrarySeries(added)
            resolvedSeries = added
        } catch {
            if let existing = await existingLibrarySeriesMatch(for: series, after: error) {
                resolvedSeries = existing
            } else {
                isAddingToLibrary = false
                InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: error.localizedDescription)
                return false
            }
        }

        applyIdentification(to: blockedItems, mediaID: resolvedSeries.id, title: resolvedSeries.title, posterURL: posterURL(from: resolvedSeries.images))
        isAddingToLibrary = false

        if importAfterAdding {
            await importIdentifiedCascade(originalIDs: Set(blockedItems.map(\.id)))
        }
        return true
    }

    /// Imports only the files that were just identified by a catalog "Add & Import" flow,
    /// not whatever else is sitting in `selectedFiles`. `importableFiles` carries the post-identify
    /// versions keyed by their original `id`.
    private func importIdentifiedCascade(originalIDs: Set<String>) async {
        let toImport = importableFiles.filter { originalIDs.contains($0.id) }
        guard !toImport.isEmpty else { return }
        await importItems(toImport)
    }

    private func storeLibraryMovie(_ movie: RadarrMovie) {
        if let index = libraryMovies.firstIndex(where: { $0.id == movie.id || $0.tmdbId == movie.tmdbId }) {
            libraryMovies[index] = movie
        } else {
            libraryMovies.append(movie)
        }
    }

    private func storeLibrarySeries(_ series: SonarrSeries) {
        if let index = librarySeries.firstIndex(where: { $0.id == series.id || $0.tvdbId == series.tvdbId }) {
            librarySeries[index] = series
        } else {
            librarySeries.append(series)
        }
    }

    private func existingLibraryMovieMatch(for movie: RadarrMovie, after error: Error) async -> RadarrMovie? {
        if let existing = libraryMovies.first(where: { $0.id == movie.id || $0.tmdbId == movie.tmdbId }) {
            return existing
        }
        guard isAlreadyAddedError(error) else { return nil }
        await refreshLibraryCatalog()
        return libraryMovies.first(where: { $0.id == movie.id || $0.tmdbId == movie.tmdbId })
    }

    private func existingLibrarySeriesMatch(for series: SonarrSeries, after error: Error) async -> SonarrSeries? {
        if let existing = librarySeries.first(where: { $0.id == series.id || $0.tvdbId == series.tvdbId }) {
            return existing
        }
        guard isAlreadyAddedError(error) else { return nil }
        await refreshLibraryCatalog()
        return librarySeries.first(where: { $0.id == series.id || $0.tvdbId == series.tvdbId })
    }

    private func refreshLibraryCatalog() async {
        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                librarySeries = try await client.getSeries()
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                libraryMovies = try await client.getMovies()
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            Self.logger.error("Library refresh after add failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isAlreadyAddedError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("already been added")
            || message.contains("seriesexistsvalidator")
            || message.contains("movieexistsvalidator")
    }

    // MARK: - Group helpers

    func toggleGroup(itemIDs: [String]) {
        let allSelected = itemIDs.allSatisfy { selectedFiles.contains($0) }
        if allSelected {
            itemIDs.forEach { selectedFiles.remove($0) }
        } else {
            itemIDs.forEach { selectedFiles.insert($0) }
        }
    }

    func toggleBlockedGroup(itemIDs: [String]) {
        let allSelected = itemIDs.allSatisfy { selectedBlockedFiles.contains($0) }
        if allSelected {
            itemIDs.forEach { selectedBlockedFiles.remove($0) }
        } else {
            itemIDs.forEach { selectedBlockedFiles.insert($0) }
        }
    }

    @discardableResult
    func importItems(_ items: [ManualImportItem]) async -> Bool {
        let filesToImport = items.filter { $0.isImportable }
        guard !filesToImport.isEmpty else { return false }
        isImporting = true
        defer { isImporting = false }

        let count = filesToImport.count
        let fileWord = count == 1 ? "file" : "files"
        let tabName = service == .sonarr ? "Series" : "Movies"
        let ids = Set(filesToImport.map(\.id))

        withAnimation(.snappy) {
            importableFiles.removeAll { ids.contains($0.id) }
            recomputeGroups()
            selectedFiles.subtract(ids)
        }

        do {
            let fileJSONs = filesToImport.map { $0.importJSON(service: service, seasonFolder: seasonFolder) }
            let command = try await manualImport(files: fileJSONs)
            if command.succeeded {
                let fileNamesSummary = importedFileNamesSummary(items: filesToImport)
                InAppNotificationCenter.shared.showSuccess(
                    title: "Imported",
                    message: "\(count) \(fileWord) imported by \(service.displayName):\n\(fileNamesSummary)",
                    action: navigationAction.map { InAppBannerAction(label: "View \(tabName)", handler: $0) }
                )
                return true
            } else {
                let reason = manualImportFailureMessage(for: command)
                Self.logger.error("importItems failed — \(reason, privacy: .private)")
                InAppNotificationCenter.shared.showError(title: "Import Failed", message: reason)
                withAnimation(.snappy) {
                    importableFiles.append(contentsOf: filesToImport)
                    recomputeGroups()
                }
                return false
            }
        } catch is CancellationError {
            return false
        } catch ArrError.commandTimeout(let commandId, let lastKnownCommand) {
            Self.logger.error("Grouped import command timed out while waiting — id:\(commandId ?? -1) status:\(lastKnownCommand?.status ?? "unknown", privacy: .public)")
            InAppNotificationCenter.shared.showSuccess(
                title: "Import In Progress",
                message: "\(count) \(fileWord) submitted to \(service.displayName). The import is still running; check Activity for progress."
            )
            return false
        } catch {
            Self.logger.error("importItems threw — \(error, privacy: .private)")
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
            withAnimation(.snappy) {
                importableFiles.append(contentsOf: filesToImport)
                recomputeGroups()
            }
            return false
        }
    }

    nonisolated private static func parseManualImportItems(from jsonValues: [JSONValue]) -> [ManualImportItem] {
        jsonValues.compactMap { ManualImportItem(json: $0) }
    }

    private static func logManualImportShapeForUnidentifiedItems(_ jsonValues: [JSONValue]) {
        let samples = jsonValues.compactMap { value -> String? in
            guard case .object(let dict) = value else { return nil }
            let hasMediaObject: Bool
            if case .object = dict["series"] {
                hasMediaObject = true
            } else if case .object = dict["movie"] {
                hasMediaObject = true
            } else {
                hasMediaObject = false
            }
            guard !hasMediaObject else { return nil }
            let keys = dict.keys.sorted().joined(separator: ",")
            let flatSeriesID = ManualImportItem.intValue(from: dict["seriesId"]) ?? 0
            let flatMovieID = ManualImportItem.intValue(from: dict["movieId"]) ?? 0
            return "keys:[\(keys)] seriesId:\(flatSeriesID) movieId:\(flatMovieID)"
        }
        .prefix(5)

        guard !samples.isEmpty else { return }
        logger.debug("Manual import unidentified raw shape samples: \(Array(samples).joined(separator: " | "), privacy: .private)")
    }

    func recomputeGroups() {
        let inLibrary = importableFiles.filter { inLibraryItemIDs.contains($0.id) }
        let newImportable = importableFiles.filter { !inLibraryItemIDs.contains($0.id) }
        groupedImportableFiles = Self.makeImportableGroups(from: importableFiles)
        groupedNewImportableFiles = Self.makeImportableGroups(from: newImportable)
        groupedInLibraryFiles = Self.makeImportableGroups(from: inLibrary)
        let pendingAdd = blockedFiles.filter(\.isIdentifiedPendingAdd)
        let unidentified = blockedFiles.filter { $0.isAutoMatchCandidate && !$0.isIdentifiedPendingAdd }
        let blocked = blockedFiles.filter { !$0.isAutoMatchCandidate }
        groupedIdentifiedPendingAddFiles = Self.makeIdentifiedPendingAddGroups(from: pendingAdd)
        groupedUnidentifiedFiles = Self.makeUnidentifiedGroups(from: unidentified)
        groupedBlockedFiles = Self.makeBlockedGroups(from: blocked)
    }

    nonisolated private static func makeImportableGroups(from items: [ManualImportItem]) -> [ManualImportGroup] {
        let grouped = Dictionary(grouping: items) { $0.mediaID ?? 0 }
        return grouped.map { (mediaID, items) in
            let sorted = sortItems(items)
            return ManualImportGroup(
                kind: .identified(mediaID: mediaID),
                displayTitle: sorted[0].mediaTitle ?? sorted[0].fileName,
                posterURL: sorted[0].posterURL,
                items: sorted
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func makeUnidentifiedGroups(from items: [ManualImportItem]) -> [ManualImportGroup] {
        let grouped = Dictionary(grouping: items) { item -> String in
            let key = inferredGroupKey(for: item.fileName)
            // Fallback to filename so files with no parseable title still appear
            return key.isEmpty ? item.fileName.lowercased() : key
        }
        return grouped.map { (key, items) in
            let sorted = sortItems(items)
            let title = displayTitleForUnidentified(items: sorted, key: key)
            return ManualImportGroup(
                kind: .unidentified(inferredKey: key),
                displayTitle: title,
                posterURL: nil,
                items: sorted
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func makeIdentifiedPendingAddGroups(from items: [ManualImportItem]) -> [ManualImportGroup] {
        let grouped = Dictionary(grouping: items) { item -> String in
            item.mediaTitle?.lowercased() ?? inferredGroupKey(for: item.fileName)
        }
        return grouped.map { (key, items) in
            let sorted = sortItems(items)
            return ManualImportGroup(
                kind: .pendingAdd(inferredKey: key),
                displayTitle: sorted[0].mediaTitle ?? displayTitleForUnidentified(items: sorted, key: key),
                posterURL: sorted[0].posterURL,
                items: sorted
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func makeBlockedGroups(from items: [ManualImportItem]) -> [ManualImportGroup] {
        var byMediaID: [Int: [ManualImportItem]] = [:]
        var byInferred: [String: [ManualImportItem]] = [:]
        for item in items {
            if let id = item.mediaID, id > 0 {
                byMediaID[id, default: []].append(item)
            } else {
                let key = inferredGroupKey(for: item.fileName)
                let bucketKey = key.isEmpty ? item.fileName.lowercased() : key
                byInferred[bucketKey, default: []].append(item)
            }
        }

        var groups: [ManualImportGroup] = []

        for (mediaID, bucket) in byMediaID {
            let sorted = sortItems(bucket)
            groups.append(ManualImportGroup(
                kind: .identified(mediaID: mediaID),
                displayTitle: sorted[0].mediaTitle ?? sorted[0].fileName,
                posterURL: sorted[0].posterURL,
                items: sorted
            ))
        }

        for (key, bucket) in byInferred {
            let sorted = sortItems(bucket)
            let title = displayTitleForUnidentified(items: sorted, key: key)
            groups.append(ManualImportGroup(
                kind: .unidentified(inferredKey: key),
                displayTitle: title,
                posterURL: nil,
                items: sorted
            ))
        }

        return groups.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func sortItems(_ items: [ManualImportItem]) -> [ManualImportItem] {
        items.sorted { a, b in
            let sA = a.seasonNumber ?? 0
            let sB = b.seasonNumber ?? 0
            if sA != sB { return sA < sB }
            let eA = a.episodes.first?.number ?? 0
            let eB = b.episodes.first?.number ?? 0
            if eA != eB { return eA < eB }
            return a.fileName.localizedCaseInsensitiveCompare(b.fileName) == .orderedAscending
        }
    }

    nonisolated private static func displayTitleForUnidentified(items: [ManualImportItem], key: String) -> String {
        let parsed = extractTitleFromFilename(items[0].fileName)
        if !parsed.isEmpty { return parsed }
        if !key.isEmpty { return key.capitalized }
        return items[0].fileName
    }
}

private struct ManualImportServiceClientUnavailableError: LocalizedError {
    let service: ArrServiceType

    var errorDescription: String? {
        "\(service.displayName) client is not available."
    }
}

func posterURL(from images: [ArrImage]?) -> URL? {
    images?.first(where: { $0.coverType == "poster" })
        .flatMap { $0.remoteUrl ?? $0.url }
        .flatMap { URL(string: $0) }
}

nonisolated private func extractTitleFromFilename(_ filename: String) -> String {
    // Strip file extension
    var name = filename
    let knownExts = ["mkv", "mp4", "avi", "mov", "m4v", "wmv", "ts", "flac", "m2ts"]
    if let dot = name.range(of: ".", options: .backwards) {
        let ext = String(name[dot.upperBound...]).lowercased()
        if knownExts.contains(ext) { name = String(name[..<dot.lowerBound]) }
    }

    // Strip bracketed metadata groups, e.g. [BluRay-1080p], (2022)
    name = name.replacing(/\[.*?\]|\(.*?\)/, with: " ")

    // Split on dots, spaces, underscores, hyphens, and bracket characters
    let tokens = name.components(separatedBy: CharacterSet(charactersIn: ". _-[]()"))


    let stopTokens: Set<String> = [
        "1080p", "720p", "480p", "2160p", "4k", "uhd",
        "bluray", "bdrip", "blu", "ray",
        "web", "webdl", "webrip", "hdrip", "hdtv", "dvdrip",
        "x264", "x265", "h264", "h265", "avc", "hevc", "xvid",
        "aac", "ac3", "dts", "dd5", "atmos", "truehd", "eac3",
        "extended", "theatrical", "remastered", "proper", "repack",
        "hdr", "dv", "dolby", "vision", "remux"
    ]

    var titleTokens: [String] = []
    for token in tokens {
        guard !token.isEmpty else { continue }
        let lower = token.lowercased()
        // Stop at SxxExx
        if token.contains(/^[Ss]\d{1,2}/) { break }
        // Stop at known quality/codec token
        if stopTokens.contains(lower) { break }
        titleTokens.append(token)
    }

    while let last = titleTokens.last,
          last.count == 4,
          let year = Int(last),
          (1900...2099).contains(year) {
        titleTokens.removeLast()
    }

    return titleTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

/// Stable key used to group unidentified files by their inferred series/movie title.
/// Lowercased and whitespace-collapsed so "Andor.S01E01" and "Andor S01E02" land in the same bucket.
nonisolated private func inferredGroupKey(for filename: String) -> String {
    let title = extractTitleFromFilename(filename)
    let collapsed = title
        .lowercased()
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return collapsed
}

func isAbsoluteImportPath(_ path: String) -> Bool {
    path.hasPrefix("/") || path.hasPrefix("\\\\") || isWindowsDrivePath(path)
}

private func isWindowsDrivePath(_ path: String) -> Bool {
    guard path.count >= 3 else { return false }
    let characters = Array(path.prefix(3))
    let drive = characters[0]
    let separator = characters[2]

    return drive.isASCII && drive.isLetter && characters[1] == ":" && (separator == "\\" || separator == "/")
}

// MARK: - Scan View
