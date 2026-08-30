import SwiftUI
import SwiftData
import OSLog

struct AddImportLocationSheet: View {
    let service: ArrServiceType
    let instanceID: UUID?
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
                            initialPath: path,
                            onClose: { showingBrowser = false }
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
            guard let client = sonarrClient else { return nil }
            return Self.source(serviceName: "Sonarr", client: client)
        case .radarr:
            guard let client = radarrClient else { return nil }
            return Self.source(serviceName: "Radarr", client: client)
        case .prowlarr, .bazarr:
            return nil
        }
    }

    private var sonarrClient: SonarrAPIClient? {
        instanceID.flatMap { serviceManager.sonarrClient(for: $0) } ?? serviceManager.sonarrClient
    }

    private var radarrClient: RadarrAPIClient? {
        instanceID.flatMap { serviceManager.radarrClient(for: $0) } ?? serviceManager.radarrClient
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
final class LibraryImportScanViewModel {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trawl", category: "ArrLibraryImportView")
    private static let manualImportScanRequestTimeout: TimeInterval = 180
    private let progressiveRevealBatchSize = 25
    private let progressiveRevealDelay: Duration = .milliseconds(16)

    let path: String
    let service: ArrServiceType
    let serviceManager: ArrServiceManager
    let libraryItemID: Int?
    let importKind: ArrImportKind
    /// Move (default) or Copy, sent as the manual-import command's importMode.
    /// Only surfaced in the UI for Manual Import; Library Import keeps the default.
    var importMode: ArrImportMode = .move

    var isScanning = false
    var isImporting = false
    private var activeImportJobCount = 0
    var importableFiles: [LibraryImportItem] = []
    var blockedFiles: [LibraryImportItem] = []
    var groupedImportableFiles: [LibraryImportGroup] = []
    var groupedNewImportableFiles: [LibraryImportGroup] = []
    var groupedInLibraryFiles: [LibraryImportGroup] = []
    var groupedIdentifiedPendingAddFiles: [LibraryImportGroup] = []
    var groupedUnidentifiedFiles: [LibraryImportGroup] = []
    var groupedBlockedFiles: [LibraryImportGroup] = []
    var inLibraryItemIDs: Set<String> = []
    var ownedTitlesInFolder: [OwnedLibraryTitle] = []
    var isLoadingInLibraryStatus = false
    var selectedFiles: Set<String> = []
    var selectedBlockedFiles: Set<String> = []
    var navigationAction: (() -> Void)?
    var seasonFolder: Bool = true
    var hasPerformedInitialScan = false
    var scanStatusMessage = "Preparing scan…"
    var scanError: String?
    /// True when the scan failed only because the target folder doesn't exist on disk yet
    /// (Sonarr/Radarr returns 500 "Could not find a part of the path"). Lets the UI explain
    /// it instead of surfacing a raw server error.
    var scanFolderMissing = false
    var isScanTakingLong = false

    // Identify sheet
    var identifyingTarget: LibraryImportIdentifyTarget?
    var libraryMovies: [RadarrMovie] = []
    var librarySeries: [SonarrSeries] = []
    var qualityProfiles: [ArrQualityProfile] = []
    var isLoadingLibrary = false
    var catalogMovieResults: [RadarrMovie] = []
    var catalogSeriesResults: [SonarrSeries] = []
    var isSearchingCatalog = false
    /// The items currently being added to the library.
    ///
    /// This was a single `Bool`, and the identify sheet both renders "Adding to
    /// library..." and disables its Add buttons from it. One add anywhere therefore
    /// blanked *every* identify sheet and disabled its buttons, and because the flag
    /// was cleared on each return path rather than by `defer`, any path that did not
    /// reach one left it stuck true - a sheet showing a spinner where its Add button
    /// belongs, forever, with multi-select import still working because
    /// `performImport()` never consults it. Tracking which items are being added lets
    /// each sheet answer for itself, and the set is emptied by `defer`.
    private(set) var addingToLibraryItemIDs: Set<String> = []
    var autoSuggestionMovies: [RadarrMovie] = []
    var autoSuggestionSeries: [SonarrSeries] = []
    var isLoadingAutoSuggestions = false
    var isAutoIdentifying = false
    var autoIdentifyCurrentFileName: String?
    var autoIdentifyEnabled = true
    var userPausedAutoIdentify = false
    var autoIdentifyProcessedCount = 0
    var autoIdentifyLastMatchedTitle: String?
    var autoIdentifyLastOutcomeMessage: String?
    private var lastAutoSuggestionFilename: String?
    @ObservationIgnored private var autoIdentifyTask: Task<Void, Never>?

    /// The server this scan imports into. An import writes files into one
    /// server's library, so with an HD/4K pair configured the destination has to
    /// be chosen rather than inferred from whichever instance is active.
    private let instanceID: UUID?

    init(
        path: String,
        service: ArrServiceType,
        serviceManager: ArrServiceManager,
        instanceID: UUID? = nil,
        libraryItemID: Int? = nil,
        kind: ArrImportKind = .library
    ) {
        self.path = path
        self.service = service
        self.serviceManager = serviceManager
        self.instanceID = instanceID
        self.libraryItemID = libraryItemID
        self.importKind = kind
    }

    /// Every call in this view model goes through these rather than through the
    /// manager's active client, so a scan started against the 4K server imports
    /// there. They fall back to the active client only when no server was named -
    /// a single-instance setup, or a caller that predates the pair.
    private var sonarrClient: SonarrAPIClient? {
        instanceID.flatMap { serviceManager.sonarrClient(for: $0) } ?? serviceManager.sonarrClient
    }

    private var radarrClient: RadarrAPIClient? {
        instanceID.flatMap { serviceManager.radarrClient(for: $0) } ?? serviceManager.radarrClient
    }

    private var rootFolders: [ArrRootFolder] {
        guard let instanceID else {
            switch service {
            case .sonarr: return serviceManager.sonarrRootFolders
            case .radarr: return serviceManager.radarrRootFolders
            case .prowlarr, .bazarr: return []
            }
        }
        return serviceManager.rootFolders(for: instanceID)
    }

    var folderName: String {
        (path as NSString).lastPathComponent
    }

    var isBusy: Bool {
        isScanning || isImporting
    }

    /// True while any add is in flight. Kept for callers that genuinely mean "any".
    var isAddingToLibrary: Bool { !addingToLibraryItemIDs.isEmpty }

    /// True only while *these* items are being added, which is what a sheet showing
    /// one file should be asking.
    func isAddingToLibrary(itemIDs: some Collection<String>) -> Bool {
        !addingToLibraryItemIDs.isDisjoint(with: itemIDs)
    }

    /// Marks these items as being added for the duration of `work`.
    ///
    /// `defer`, so no early return, thrown error or cancellation can leave the
    /// identify sheets disabled behind a spinner.
    private func whileAddingToLibrary<T>(_ itemIDs: [String], _ work: () async -> T) async -> T {
        addingToLibraryItemIDs.formUnion(itemIDs)
        defer { addingToLibraryItemIDs.subtract(itemIDs) }
        return await work()
    }

    /// The root folder to add into.
    ///
    /// Fetched on demand when the cached list is empty. The Add button used to depend
    /// on the server's configuration already being loaded, and both loaders swallow
    /// their errors, so a slow or failed load left this empty and every Add silently
    /// did nothing.
    private func resolvedRootFolderPath() async -> String? {
        if let cached = rootFolders.first?.path { return cached }
        switch service {
        case .radarr:
            guard let fetched = try? await radarrClient?.getRootFolders() else { return nil }
            return fetched.first?.path
        case .sonarr:
            guard let fetched = try? await sonarrClient?.getRootFolders() else { return nil }
            return fetched.first?.path
        case .prowlarr, .bazarr:
            return nil
        }
    }

    /// The quality profile to add with, fetched on demand for the same reason.
    private func resolvedQualityProfileID() async -> Int? {
        if let cached = qualityProfiles.first?.id { return cached }
        switch service {
        case .radarr:
            guard let fetched = try? await radarrClient?.getQualityProfiles() else { return nil }
            qualityProfiles = fetched
            return fetched.first?.id
        case .sonarr:
            guard let fetched = try? await sonarrClient?.getQualityProfiles() else { return nil }
            qualityProfiles = fetched
            return fetched.first?.id
        case .prowlarr, .bazarr:
            return nil
        }
    }

    /// Names what stopped an add, rather than returning false in silence.
    ///
    /// Every branch here was one arm of a single five-condition `guard` that returned
    /// `false` with no message and no logging: the user tapped Add and Import and the
    /// sheet simply sat there.
    private func reportAddPrecondition(_ reason: String) {
        Self.logger.error("Add to library refused: \(reason, privacy: .public) [service \(self.service.displayName, privacy: .public)]")
        InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: reason)
    }

    private func beginImportActivity() {
        activeImportJobCount += 1
        isImporting = activeImportJobCount > 0
    }

    private func endImportActivity() {
        activeImportJobCount = max(0, activeImportJobCount - 1)
        isImporting = activeImportJobCount > 0
    }

    var allSelected: Bool {
        let totalCount = importableFiles.count + blockedFiles.count
        guard totalCount > 0 else { return false }
        return selectedFiles.count + selectedBlockedFiles.count == totalCount
    }

    var hasAnySelection: Bool {
        !selectedFiles.isEmpty || !selectedBlockedFiles.isEmpty
    }

    var selectedBlockedItems: [LibraryImportItem] {
        blockedFiles.filter { selectedBlockedFiles.contains($0.id) }
    }

    var selectedReadyGroups: [LibraryImportGroup] {
        selectedGroups(from: groupedImportableFiles, selectedIDs: selectedFiles)
    }

    var selectedBlockedGroups: [LibraryImportGroup] {
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

    // MARK: Native list selection

    /// Which file-ID set a row belongs to. The scan view's rows are *groups*, while
    /// selection is tracked per file across two sets, so `List(selection:)` selects
    /// tagged groups and these two methods are the adapter between the two.
    enum SelectionBucket: String, Sendable {
        case ready, blocked
    }

    /// A group ID is only unique within its bucket - an identified group can appear
    /// both as ready and as blocked with the same media ID - so the tag carries the
    /// bucket too.
    static func selectionTag(_ bucket: SelectionBucket, _ group: LibraryImportGroup) -> String {
        "\(bucket.rawValue)|\(group.id)"
    }

    /// The tags for every passed group holding at least one selected file. A group
    /// only *partly* selected still reads as selected: the List has no third state,
    /// and reporting it unselected would let the next write-back clear it.
    func selectionTags(ready: [LibraryImportGroup], blocked: [LibraryImportGroup]) -> Set<String> {
        var tags: Set<String> = []
        for group in ready where group.items.contains(where: { selectedFiles.contains($0.id) }) {
            tags.insert(Self.selectionTag(.ready, group))
        }
        for group in blocked where group.items.contains(where: { selectedBlockedFiles.contains($0.id) }) {
            tags.insert(Self.selectionTag(.blocked, group))
        }
        return tags
    }

    /// Writes a `List` selection back onto the per-file sets.
    ///
    /// Only the groups passed in are reconciled - the ones on screen - so a selection
    /// whose group is filtered out by the search field, or has moved between groups
    /// after auto-identification, is left alone rather than silently dropped.
    func applySelectionTags(_ tags: Set<String>, ready: [LibraryImportGroup], blocked: [LibraryImportGroup]) {
        for group in ready {
            let ids = group.items.map(\.id)
            if tags.contains(Self.selectionTag(.ready, group)) {
                // A group already partly selected stays partly selected: only a
                // newly ticked group takes all of its files.
                if !ids.contains(where: { selectedFiles.contains($0) }) {
                    selectedFiles.formUnion(ids)
                }
            } else {
                selectedFiles.subtract(ids)
            }
        }
        for group in blocked {
            let ids = group.items.map(\.id)
            if tags.contains(Self.selectionTag(.blocked, group)) {
                if !ids.contains(where: { selectedBlockedFiles.contains($0) }) {
                    selectedBlockedFiles.formUnion(ids)
                }
            } else {
                selectedBlockedFiles.subtract(ids)
            }
        }
    }

    private func selectedGroups(from groups: [LibraryImportGroup], selectedIDs: Set<String>) -> [LibraryImportGroup] {
        groups.compactMap { group in
            let selectedItems = group.items.filter { selectedIDs.contains($0.id) }
            guard !selectedItems.isEmpty else { return nil }
            return LibraryImportGroup(
                kind: group.kind,
                displayTitle: group.displayTitle,
                posterURL: group.posterURL,
                items: selectedItems
            )
        }
    }

    func loadFiles() async {
        isScanning = true
        scanError = nil
        scanFolderMissing = false
        isScanTakingLong = false
        scanStatusMessage = "Preparing scan…"
        let shouldResumeAutoIdentify = autoIdentifyEnabled
        if autoIdentifyTask != nil {
            stopAutoIdentify()
            autoIdentifyEnabled = shouldResumeAutoIdentify
        }
        let slowTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.isScanTakingLong = true
        }
        defer {
            isScanning = false
            isScanTakingLong = false
            slowTimer.cancel()
        }

        do {
            Self.logger.info("Manual import scan starting for \(self.service.displayName, privacy: .public) path \(self.path, privacy: .public) libraryItemID \(self.libraryItemID ?? -1)")
            scanStatusMessage = "Contacting \(service.displayName)…"
            let jsonValues = try await getManualImport(folder: path)
            Self.logger.info("Manual import scan received \(jsonValues.count) raw items from \(self.service.displayName, privacy: .public)")
            scanStatusMessage = "Parsing \(jsonValues.count) items…"
            Self.logLibraryImportShapeForUnidentifiedItems(jsonValues)
            let scannedFiles = await Task.detached(priority: .userInitiated) {
                Self.parseLibraryImportItems(from: jsonValues)
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

            var nextImportableBatch: [LibraryImportItem] = []
            var nextBlockedBatch: [LibraryImportItem] = []
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
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("could not find a part of the path")
                || description.localizedCaseInsensitiveContains("directory not found") {
                // Expected when the title has no files yet - its folder doesn't exist on
                // disk. Explain it rather than alarming with a raw 500 (the Sonarr/Radarr
                // web UI shows the same error here).
                scanFolderMissing = true
                scanError = "\(service.displayName) couldn't find this folder on disk:\n\(path)\n\nManual import scans an existing folder for files. A title with no files yet usually has no folder on disk."
                scanStatusMessage = "Folder not found"
            } else {
                scanError = description
                scanStatusMessage = "Scan failed"
                InAppNotificationCenter.shared.showError(title: "Scan Failed", message: description)
            }
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
                guard let client = sonarrClient else { continue }
                guard let tvdbId = items.first?.catalogID else { continue }
                if let match = librarySeries.first(where: { $0.tvdbId == tvdbId }) {
                    applyIdentification(to: items, mediaID: match.id, title: match.title, posterURL: posterURL(from: match.images))
                    resolved = true
                } else if let candidate = try? await client.lookupSeriesByTvdb(tvdbId: tvdbId) {
                    resolved = await addToLibraryAndIdentify(blockedItems: items, series: candidate, importAfterAdding: false)
                }
            case .radarr:
                guard let client = radarrClient else { continue }
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
        beginImportActivity()
        defer { endImportActivity() }

        let importedIDs = selectedFiles
        let savedItems = importableFiles.filter { importedIDs.contains($0.id) }
        let filesToImport = savedItems.map { $0.importJSON(service: service, seasonFolder: seasonFolder) }

        let count = filesToImport.count
        let jobID = registerImportJob(items: savedItems)

        do {
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
            let command = try await manualImport(files: filesToImport, onProgress: importProgressHandler(jobID: jobID))
            Self.logger.info("Command finished - id:\(command.id ?? -1) status:\(command.status ?? "nil", privacy: .public) exception:\(command.exception ?? "none", privacy: .private)")

            if !command.isTerminal {
                Self.logger.info("Command \(command.id ?? -1) is still running with status \(command.status ?? "unknown", privacy: .public)")
                notificationCenter.completeImportJob(id: jobID, succeeded: true)
                notificationCenter.showSuccess(
                    title: "Import Started",
                    message: "\(count) \(fileWord) submitted to \(service.displayName). Import is still running."
                )
                return false
            }

            if command.succeeded {
                // Items were already optimistically removed. Don't reload - rescanning the folder
                // will find the file again (hardlinks/copies leave the source in place) and undo
                // the removal, making it look like the import failed when it didn't.
                serviceManager.lastLibraryImportTimestamp = Date()
                notificationCenter.completeImportJob(id: jobID, succeeded: true)
                notificationCenter.showSuccess(
                    title: "Import Complete",
                    message: "\(count) \(fileWord) imported by \(service.displayName):\n\(fileNamesSummary)",
                    action: navAction.map { InAppBannerAction(label: "View \(tabName)", handler: $0) }
                )
                return true
            } else {
                let reason = manualImportFailureMessage(for: command)
                Self.logger.error("Command failed - \(reason, privacy: .private)")
                notificationCenter.completeImportJob(id: jobID, succeeded: false, errorMessage: reason)
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
            InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: false, errorMessage: "Cancelled")
            return false
        } catch ArrError.commandTimeout(let commandId, let lastKnownCommand) {
            Self.logger.error("Manual import command timed out while waiting - id:\(commandId ?? -1) status:\(lastKnownCommand?.status ?? "unknown", privacy: .public)")
            InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: true)
            InAppNotificationCenter.shared.showSuccess(
                title: "Import Started",
                message: "\(savedItems.count) \(savedItems.count == 1 ? "file" : "files") submitted to \(service.displayName). The import is still running; check Activity for progress."
            )
            return false
        } catch {
            Self.logger.error("Threw error - \(error, privacy: .private)")
            InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: false, errorMessage: error.localizedDescription)
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
            withAnimation(.snappy) {
                importableFiles.append(contentsOf: savedItems)
                recomputeGroups()
            }
            selectedFiles = importedIDs
            return false
        }
    }

    private func registerImportJob(items: [LibraryImportItem]) -> UUID {
        let tint: ImportJobTint
        switch service {
        case .sonarr: tint = .sonarr
        case .radarr: tint = .radarr
        case .prowlarr, .bazarr: tint = .generic
        }
        let primaryItem = items.first
        let trimmedTitle = primaryItem?.mediaTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let primaryName: String
        if !trimmedTitle.isEmpty {
            primaryName = trimmedTitle
        } else if let fileName = primaryItem?.fileName, !fileName.isEmpty {
            primaryName = fileName
        } else {
            primaryName = folderName
        }
        let fileNames = items.map { ($0.fileName as NSString).lastPathComponent }
        return InAppNotificationCenter.shared.startImportJob(
            serviceTitle: service.displayName,
            serviceSystemImage: service.serviceIdentity.systemImage,
            serviceTint: tint,
            folderName: folderName,
            primaryName: primaryName,
            fileCount: items.count,
            fileNames: fileNames
        )
    }


    private func importedFileNamesSummary(items: [LibraryImportItem]) -> String {
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
            guard let client = sonarrClient else {
                throw LibraryImportServiceClientUnavailableError(service: service)
            }
            Self.logger.info("Requesting Sonarr manual import scan for \(folder, privacy: .private)")
            return try await client.getManualImport(
                folder: folder,
                libraryItemId: libraryItemID,
                libraryItemIDQueryName: "seriesId",
                requestTimeout: Self.manualImportScanRequestTimeout
            )
        case .radarr:
            guard let client = radarrClient else {
                throw LibraryImportServiceClientUnavailableError(service: service)
            }
            Self.logger.info("Requesting Radarr manual import scan for \(folder, privacy: .private)")
            return try await client.getManualImport(
                folder: folder,
                libraryItemId: libraryItemID,
                libraryItemIDQueryName: "movieId",
                requestTimeout: Self.manualImportScanRequestTimeout
            )
        case .prowlarr, .bazarr:
            throw LibraryImportServiceClientUnavailableError(service: service)
        }
    }

    @discardableResult
    private func manualImport(
        files: [JSONValue],
        onProgress: (@Sendable (ArrCommand) -> Void)? = nil
    ) async throws -> ArrCommand {
        switch service {
        case .sonarr:
            guard let client = sonarrClient else {
                throw LibraryImportServiceClientUnavailableError(service: service)
            }
            return try await client.manualImport(files: files, importMode: importMode.apiValue, onProgress: onProgress)
        case .radarr:
            guard let client = radarrClient else {
                throw LibraryImportServiceClientUnavailableError(service: service)
            }
            return try await client.manualImport(files: files, importMode: importMode.apiValue, onProgress: onProgress)
        case .prowlarr, .bazarr:
            throw LibraryImportServiceClientUnavailableError(service: service)
        }
    }

    /// Builds an `onProgress` closure that forwards the server's live per-file
    /// progress (e.g. "Processing file 3 of 4") to the in-app import job.
    private func importProgressHandler(jobID: UUID) -> (@Sendable (ArrCommand) -> Void) {
        return { command in
            guard let progress = command.itemProgress else { return }
            Task { @MainActor in
                InAppNotificationCenter.shared.updateImportJobProgress(
                    id: jobID,
                    currentIndex: progress.current,
                    total: progress.total
                )
            }
        }
    }

    // MARK: - Identify

    func beginIdentifying(_ item: LibraryImportItem) {
        resetCatalogSearchState()
        let target = LibraryImportIdentifyTarget(
            id: "item-\(item.id)",
            items: [item],
            displayLabel: item.fileName
        )
        identifyingTarget = target
        Task { [weak self] in await self?.loadLibraryIfNeeded() }
        Task { [weak self] in await self?.loadAutoSuggestions(for: item.fileName) }
    }

    func beginIdentifying(group: LibraryImportGroup) {
        guard let first = group.items.first else { return }
        resetCatalogSearchState()
        let label: String
        if group.items.count == 1 {
            label = first.fileName
        } else {
            label = "\(group.displayTitle) · \(group.items.count) files"
        }
        let target = LibraryImportIdentifyTarget(
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
        lastAutoSuggestionFilename = nil
    }

    func loadInLibraryStatus() async {
        guard !importableFiles.isEmpty, !isLoadingInLibraryStatus else { return }
        isLoadingInLibraryStatus = true
        defer { isLoadingInLibraryStatus = false }
        var found: Set<String> = []
        switch service {
        case .radarr:
            // Fetch the movie list live so in-library status reflects the current
            // library - relying on the cached `libraryMovies` left this stale (e.g.
            // unchanged after pull-to-refresh, which doesn't reload the library).
            let movies = (try? await radarrClient?.getMovies()) ?? libraryMovies
            if !movies.isEmpty { libraryMovies = movies }
            let moviesWithFile = Set(
                movies
                    .filter { $0.hasFile == true || $0.movieFile != nil }
                    .map(\.id)
            )
            for item in importableFiles {
                guard let mid = item.mediaID else { continue }
                if moviesWithFile.contains(mid) { found.insert(item.id) }
            }
        case .sonarr:
            guard let client = sonarrClient else { break }
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

    /// Radarr/Sonarr's manual-import response often matches a file to a movie/series by
    /// parsing but returns it with no library id (id 0) - so the file looks like a title
    /// that still needs adding, even when it's already in the library. We hold the full
    /// library list, so re-link those files to their real library entry by TMDb/TVDb id
    /// and move them from "Identified / needs add" into the importable set.
    func relinkIdentifiedItemsToLibrary() {
        guard !blockedFiles.isEmpty else { return }
        var promoted: [LibraryImportItem] = []
        var remaining: [LibraryImportItem] = []
        for item in blockedFiles {
            guard item.rejectionReasons.isEmpty, item.mediaID == nil, let catalog = item.catalogID else {
                remaining.append(item)
                continue
            }
            switch service {
            case .radarr:
                if let movie = libraryMovies.first(where: { $0.tmdbId == catalog }) {
                    promoted.append(item.withIdentification(mediaID: movie.id, title: movie.title, posterURL: item.posterURL))
                    continue
                }
            case .sonarr:
                if let series = librarySeries.first(where: { $0.tvdbId == catalog }) {
                    promoted.append(item.withIdentification(mediaID: series.id, title: series.title, posterURL: item.posterURL))
                    continue
                }
            case .prowlarr, .bazarr:
                break
            }
            remaining.append(item)
        }
        guard !promoted.isEmpty else { return }
        Self.logger.info("Re-linked \(promoted.count) scanned files to existing library entries by catalog id")
        withAnimation(.snappy) {
            blockedFiles = remaining
            importableFiles.append(contentsOf: promoted)
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
                guard let client = sonarrClient else { return }
                async let seriesResult = client.getSeries()
                async let profilesResult = client.getQualityProfiles()
                librarySeries = try await seriesResult
                qualityProfiles = try await profilesResult
            case .radarr:
                guard let client = radarrClient else { return }
                async let moviesResult = client.getMovies()
                async let profilesResult = client.getQualityProfiles()
                libraryMovies = try await moviesResult
                qualityProfiles = try await profilesResult
            case .prowlarr, .bazarr:
                break
            }
            computeOwnedTitlesInFolder()
        } catch {
            // Silently fail - user will see an empty list in the sheet
        }
    }

    /// Library titles whose folder lives under the scanned path - i.e. what's *already
    /// imported* from this folder (hidden from the scan by `filterExistingFiles`). Shown
    /// read-only under the Owned tab so the folder's contents aren't a mystery.
    func computeOwnedTitlesInFolder() {
        let root = Self.normalizedFolderPath(path)
        let titles: [OwnedLibraryTitle]
        switch service {
        case .radarr:
            titles = libraryMovies.compactMap { movie in
                guard movie.hasFile == true, let p = movie.path, Self.path(p, isUnder: root) else { return nil }
                return OwnedLibraryTitle(id: movie.id, title: movie.title, year: movie.year, posterURL: movie.posterURL)
            }
        case .sonarr:
            titles = librarySeries.compactMap { series in
                guard let p = series.path, Self.path(p, isUnder: root) else { return nil }
                return OwnedLibraryTitle(id: series.id, title: series.title, year: series.year, posterURL: series.posterURL)
            }
        case .prowlarr, .bazarr:
            titles = []
        }
        ownedTitlesInFolder = titles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    nonisolated static func normalizedFolderPath(_ p: String) -> String {
        p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// True when `candidate` is the root itself or nested inside it (path-segment aware,
    /// so `/data/Movies` does not match `/data/Movies2`).
    nonisolated static func path(_ candidate: String, isUnder root: String) -> Bool {
        let c = normalizedFolderPath(candidate)
        return c == root || c.hasPrefix(root + "/")
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
            lastAutoSuggestionFilename = nil
            withAnimation(.snappy) { isLoadingAutoSuggestions = false }
            return
        }
        do {
            switch service {
            case .radarr:
                guard let client = radarrClient else {
                    lastAutoSuggestionFilename = nil
                    withAnimation(.snappy) { isLoadingAutoSuggestions = false }
                    return
                }
                let results = try await client.lookupMovie(term: term)
                withAnimation(.snappy) {
                    autoSuggestionMovies = results
                    isLoadingAutoSuggestions = false
                }
            case .sonarr:
                guard let client = sonarrClient else {
                    lastAutoSuggestionFilename = nil
                    withAnimation(.snappy) { isLoadingAutoSuggestions = false }
                    return
                }
                let results = try await client.lookupSeries(term: term)
                withAnimation(.snappy) {
                    autoSuggestionSeries = results
                    isLoadingAutoSuggestions = false
                }
            case .prowlarr, .bazarr:
                lastAutoSuggestionFilename = nil
                withAnimation(.snappy) { isLoadingAutoSuggestions = false }
            }
        } catch {
            lastAutoSuggestionFilename = nil
            withAnimation(.snappy) { isLoadingAutoSuggestions = false }
        }
    }

    func startAutoIdentify() {
        userPausedAutoIdentify = false
        autoIdentifyEnabled = true
        guard autoIdentifyTask == nil else { return }
        autoIdentifyLastMatchedTitle = nil
        autoIdentifyLastOutcomeMessage = "Preparing auto match…"
        Self.logger.info("Auto-identify requested for \(self.path, privacy: .private); unresolved \(self.unresolvedUnidentifiedCount) blocked-with-rejection \(self.blockedWithRejectionCount)")
        autoIdentifyTask = Task { [weak self] in
            await self?.runAutoIdentifyLoop()
        }
    }

    func stopAutoIdentify(userInitiated: Bool = false) {
        if userInitiated { userPausedAutoIdentify = true }
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
                    guard let client = sonarrClient else { return }
                    let results = try await client.lookupSeries(term: term)
                    // After the network round-trip, re-read the group from the recomputed
                    // unidentified list. The user may have manually identified some/all of
                    // these files in the meantime - only cascade to whatever's still pending.
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
                    } else if importKind == .library, let candidate = results.first {
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
                    guard let client = radarrClient else { return }
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
                    } else if importKind == .library, let candidate = results.first {
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
    private func pendingItems(forGroupID groupID: String) -> [LibraryImportItem]? {
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
                guard let client = radarrClient else { return }
                catalogMovieResults = try await client.lookupMovie(term: trimmed)
            case .sonarr:
                guard let client = sonarrClient else { return }
                catalogSeriesResults = try await client.lookupSeries(term: trimmed)
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            // Leave existing results, user can retry
        }
    }

    func applyIdentification(to item: LibraryImportItem, mediaID: Int, title: String, posterURL: URL?) {
        applyIdentification(to: [item], mediaID: mediaID, title: title, posterURL: posterURL)
    }

    func applyIdentification(to items: [LibraryImportItem], mediaID: Int, title: String, posterURL: URL?) {
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

    func applyPendingAddIdentification(to items: [LibraryImportItem], title: String, catalogID: Int?, posterURL: URL?) {
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
    func addToLibraryAndIdentify(blockedItems: [LibraryImportItem], movie: RadarrMovie, importAfterAdding: Bool = true) async -> Bool {
        guard !blockedItems.isEmpty else { return false }
        guard let client = radarrClient else {
            reportAddPrecondition("Radarr isn't connected, so \(movie.title) can't be added.")
            return false
        }
        guard let tmdbId = movie.tmdbId else {
            reportAddPrecondition("\(movie.title) has no TMDb id, so Radarr can't add it. Search for it again and pick a result from Discover.")
            return false
        }
        guard let rootFolder = await resolvedRootFolderPath() else {
            reportAddPrecondition("\(service.displayName) has no root folder to add \(movie.title) into. Add one in Library Management, then try again.")
            return false
        }
        guard let qualityProfileId = await resolvedQualityProfileID() else {
            reportAddPrecondition("Couldn't read \(service.displayName)'s quality profiles, so \(movie.title) can't be added. Check the server is reachable and try again.")
            return false
        }

        return await whileAddingToLibrary(blockedItems.map(\.id)) {
            await addMovieAndIdentify(
                blockedItems: blockedItems,
                movie: movie,
                client: client,
                tmdbId: tmdbId,
                rootFolder: rootFolder,
                qualityProfileId: qualityProfileId,
                importAfterAdding: importAfterAdding
            )
        }
    }

    private func addMovieAndIdentify(
        blockedItems: [LibraryImportItem],
        movie: RadarrMovie,
        client: RadarrAPIClient,
        tmdbId: Int,
        rootFolder: String,
        qualityProfileId: Int,
        importAfterAdding: Bool
    ) async -> Bool {
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
                InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: error.localizedDescription)
                return false
            }
        }

        applyIdentification(to: blockedItems, mediaID: resolvedMovie.id, title: resolvedMovie.title, posterURL: posterURL(from: resolvedMovie.images))

        if importAfterAdding {
            await importIdentifiedItems(originalIDs: Set(blockedItems.map(\.id)))
        }
        return true
    }

    @discardableResult
    func addToLibraryAndIdentify(blockedItems: [LibraryImportItem], series: SonarrSeries, importAfterAdding: Bool = true) async -> Bool {
        guard !blockedItems.isEmpty else { return false }
        guard let client = sonarrClient else {
            reportAddPrecondition("Sonarr isn't connected, so \(series.title) can't be added.")
            return false
        }
        guard let tvdbId = series.tvdbId, let titleSlug = series.titleSlug else {
            reportAddPrecondition("\(series.title) is missing the TVDb details Sonarr needs to add it. Search for it again and pick a result from Discover.")
            return false
        }
        guard let rootFolder = await resolvedRootFolderPath() else {
            reportAddPrecondition("\(service.displayName) has no root folder to add \(series.title) into. Add one in Library Management, then try again.")
            return false
        }
        guard let qualityProfileId = await resolvedQualityProfileID() else {
            reportAddPrecondition("Couldn't read \(service.displayName)'s quality profiles, so \(series.title) can't be added. Check the server is reachable and try again.")
            return false
        }

        return await whileAddingToLibrary(blockedItems.map(\.id)) {
            await addSeriesAndIdentify(
                blockedItems: blockedItems,
                series: series,
                client: client,
                tvdbId: tvdbId,
                titleSlug: titleSlug,
                rootFolder: rootFolder,
                qualityProfileId: qualityProfileId,
                importAfterAdding: importAfterAdding
            )
        }
    }

    private func addSeriesAndIdentify(
        blockedItems: [LibraryImportItem],
        series: SonarrSeries,
        client: SonarrAPIClient,
        tvdbId: Int,
        titleSlug: String,
        rootFolder: String,
        qualityProfileId: Int,
        importAfterAdding: Bool
    ) async -> Bool {
        let resolvedSeries: SonarrSeries
        do {
            let seasons = (series.seasons ?? []).map {
                SonarrAddSeason(seasonNumber: $0.seasonNumber, monitored: false)
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
                    monitor: "none",
                    searchForMissingEpisodes: false,
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
                InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: error.localizedDescription)
                return false
            }
        }

        applyIdentification(to: blockedItems, mediaID: resolvedSeries.id, title: resolvedSeries.title, posterURL: posterURL(from: resolvedSeries.images))

        if importAfterAdding {
            let didImport = await importIdentifiedItems(originalIDs: Set(blockedItems.map(\.id)))
            if didImport {
                await monitorImportedEpisodes(seriesID: resolvedSeries.id, from: blockedItems)
            }
        }
        return true
    }

    private func monitorImportedEpisodes(seriesID: Int, from items: [LibraryImportItem]) async {
        guard service == .sonarr,
              let client = sonarrClient else { return }

        let importedKeys = Self.importedEpisodeKeys(from: items)
        guard !importedKeys.isEmpty else { return }

        do {
            let episodes = try await client.getEpisodes(seriesId: seriesID)
            let episodeIDs = episodes.compactMap { episode -> Int? in
                let key = LibraryImportEpisodeKey(seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
                return importedKeys.contains(key) ? episode.id : nil
            }
            guard !episodeIDs.isEmpty else { return }
            _ = try await client.setEpisodeMonitored(episodeIds: episodeIDs, monitored: true)
        } catch {
            Self.logger.error("Failed to monitor imported episodes for series \(seriesID): \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func importedEpisodeKeys(from items: [LibraryImportItem]) -> Set<LibraryImportEpisodeKey> {
        var keys: Set<LibraryImportEpisodeKey> = []
        for item in items {
            guard let seasonNumber = item.seasonNumber else { continue }
            for episode in item.episodes {
                keys.insert(LibraryImportEpisodeKey(seasonNumber: seasonNumber, episodeNumber: episode.number))
            }
        }
        return keys
    }

    /// Imports only the files that were just identified by an identify-sheet action,
    /// not whatever else is sitting in `selectedFiles`. `importableFiles` carries the post-identify
    /// versions keyed by their original `id`.
    @discardableResult
    func importIdentifiedItems(originalIDs: Set<String>) async -> Bool {
        let toImport = importableFiles.filter { originalIDs.contains($0.id) }
        guard !toImport.isEmpty else {
            // Reached when the identification did not land the files in the importable
            // set - previously a silent `false`, which the sheet showed as nothing at all.
            Self.logger.error("Import requested for \(originalIDs.count) files but none were importable")
            InAppNotificationCenter.shared.showError(
                title: "Nothing to Import",
                message: "Those files are no longer ready to import. Pull to refresh the scan and try again."
            )
            return false
        }
        return await importItems(toImport)
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
                guard let client = sonarrClient else { return }
                librarySeries = try await client.getSeries()
            case .radarr:
                guard let client = radarrClient else { return }
                libraryMovies = try await client.getMovies()
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            Self.logger.error("Library refresh after add failed - \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isAlreadyAddedError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("already been added")
            || message.contains("seriesexistsvalidator")
            || message.contains("movieexistsvalidator")
    }

    @discardableResult
    func importItems(_ items: [LibraryImportItem]) async -> Bool {
        let filesToImport = items.filter { $0.isImportable }
        guard !filesToImport.isEmpty else { return false }
        beginImportActivity()
        defer { endImportActivity() }

        let count = filesToImport.count
        let fileWord = count == 1 ? "file" : "files"
        let tabName = service == .sonarr ? "Series" : "Movies"
        let ids = Set(filesToImport.map(\.id))
        let jobID = registerImportJob(items: filesToImport)

        withAnimation(.snappy) {
            importableFiles.removeAll { ids.contains($0.id) }
            recomputeGroups()
            selectedFiles.subtract(ids)
        }

        do {
            let fileJSONs = filesToImport.map { $0.importJSON(service: service, seasonFolder: seasonFolder) }
            let command = try await manualImport(files: fileJSONs, onProgress: importProgressHandler(jobID: jobID))
            if command.succeeded {
                // Nudge the series/movie lists to reload once (they observe this
                // timestamp), so a freshly added+imported title's counts refresh
                // without an app restart. Mirrors performImport().
                serviceManager.lastLibraryImportTimestamp = Date()
                let fileNamesSummary = importedFileNamesSummary(items: filesToImport)
                InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: true)
                InAppNotificationCenter.shared.showSuccess(
                    title: "Imported",
                    message: "\(count) \(fileWord) imported by \(service.displayName):\n\(fileNamesSummary)",
                    action: navigationAction.map { InAppBannerAction(label: "View \(tabName)", handler: $0) }
                )
                return true
            } else {
                let reason = manualImportFailureMessage(for: command)
                Self.logger.error("importItems failed - \(reason, privacy: .private)")
                InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: false, errorMessage: reason)
                InAppNotificationCenter.shared.showError(title: "Import Failed", message: reason)
                withAnimation(.snappy) {
                    importableFiles.append(contentsOf: filesToImport)
                    recomputeGroups()
                }
                return false
            }
        } catch is CancellationError {
            InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: false, errorMessage: "Cancelled")
            return false
        } catch ArrError.commandTimeout(let commandId, let lastKnownCommand) {
            Self.logger.error("Grouped import command timed out while waiting - id:\(commandId ?? -1) status:\(lastKnownCommand?.status ?? "unknown", privacy: .public)")
            InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: true)
            InAppNotificationCenter.shared.showSuccess(
                title: "Import In Progress",
                message: "\(count) \(fileWord) submitted to \(service.displayName). The import is still running; check Activity for progress."
            )
            return false
        } catch {
            Self.logger.error("importItems threw - \(error, privacy: .private)")
            InAppNotificationCenter.shared.completeImportJob(id: jobID, succeeded: false, errorMessage: error.localizedDescription)
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
            withAnimation(.snappy) {
                importableFiles.append(contentsOf: filesToImport)
                recomputeGroups()
            }
            return false
        }
    }

    nonisolated private static func parseLibraryImportItems(from jsonValues: [JSONValue]) -> [LibraryImportItem] {
        jsonValues.compactMap { LibraryImportItem(json: $0) }
    }

    private static func logLibraryImportShapeForUnidentifiedItems(_ jsonValues: [JSONValue]) {
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
            let flatSeriesID = LibraryImportItem.intValue(from: dict["seriesId"]) ?? 0
            let flatMovieID = LibraryImportItem.intValue(from: dict["movieId"]) ?? 0
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

    nonisolated private static func makeImportableGroups(from items: [LibraryImportItem]) -> [LibraryImportGroup] {
        let grouped = Dictionary(grouping: items) { $0.mediaID ?? 0 }
        return grouped.map { (mediaID, items) in
            let sorted = sortItems(items)
            return LibraryImportGroup(
                kind: .identified(mediaID: mediaID),
                displayTitle: sorted[0].mediaTitle ?? sorted[0].fileName,
                posterURL: sorted[0].posterURL,
                items: sorted
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func makeUnidentifiedGroups(from items: [LibraryImportItem]) -> [LibraryImportGroup] {
        let grouped = Dictionary(grouping: items) { item -> String in
            let key = inferredGroupKey(for: item.fileName)
            // Fallback to filename so files with no parseable title still appear
            return key.isEmpty ? item.fileName.lowercased() : key
        }
        return grouped.map { (key, items) in
            let sorted = sortItems(items)
            let title = displayTitleForUnidentified(items: sorted, key: key)
            return LibraryImportGroup(
                kind: .unidentified(inferredKey: key),
                displayTitle: title,
                posterURL: nil,
                items: sorted
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func makeIdentifiedPendingAddGroups(from items: [LibraryImportItem]) -> [LibraryImportGroup] {
        let grouped = Dictionary(grouping: items) { item -> String in
            item.mediaTitle?.lowercased() ?? inferredGroupKey(for: item.fileName)
        }
        return grouped.map { (key, items) in
            let sorted = sortItems(items)
            return LibraryImportGroup(
                kind: .pendingAdd(inferredKey: key),
                displayTitle: sorted[0].mediaTitle ?? displayTitleForUnidentified(items: sorted, key: key),
                posterURL: sorted[0].posterURL,
                items: sorted
            )
        }
        .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func makeBlockedGroups(from items: [LibraryImportItem]) -> [LibraryImportGroup] {
        var byMediaID: [Int: [LibraryImportItem]] = [:]
        var byInferred: [String: [LibraryImportItem]] = [:]
        for item in items {
            if let id = item.mediaID, id > 0 {
                byMediaID[id, default: []].append(item)
            } else {
                let key = inferredGroupKey(for: item.fileName)
                let bucketKey = key.isEmpty ? item.fileName.lowercased() : key
                byInferred[bucketKey, default: []].append(item)
            }
        }

        var groups: [LibraryImportGroup] = []

        for (mediaID, bucket) in byMediaID {
            let sorted = sortItems(bucket)
            groups.append(LibraryImportGroup(
                kind: .identified(mediaID: mediaID),
                displayTitle: sorted[0].mediaTitle ?? sorted[0].fileName,
                posterURL: sorted[0].posterURL,
                items: sorted
            ))
        }

        for (key, bucket) in byInferred {
            let sorted = sortItems(bucket)
            let title = displayTitleForUnidentified(items: sorted, key: key)
            groups.append(LibraryImportGroup(
                kind: .unidentified(inferredKey: key),
                displayTitle: title,
                posterURL: nil,
                items: sorted
            ))
        }

        return groups.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated private static func sortItems(_ items: [LibraryImportItem]) -> [LibraryImportItem] {
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

    nonisolated private static func displayTitleForUnidentified(items: [LibraryImportItem], key: String) -> String {
        let parsed = extractTitleFromFilename(items[0].fileName)
        if !parsed.isEmpty { return parsed }
        if !key.isEmpty { return key.capitalized }
        return items[0].fileName
    }
}

private struct LibraryImportServiceClientUnavailableError: LocalizedError {
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
