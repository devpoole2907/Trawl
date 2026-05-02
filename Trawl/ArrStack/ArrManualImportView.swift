import SwiftUI
import SwiftData
import OSLog

// MARK: - Location Browser

struct ArrManualImportView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var showAddLocation = false

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var rootFolders: [ArrRootFolder] {
        selectedService == .sonarr ? serviceManager.sonarrRootFolders : serviceManager.radarrRootFolders
    }

    private var currentProfile: ArrServiceProfile? {
        let activeProfileID: UUID?
        switch selectedService {
        case .sonarr:
            activeProfileID = serviceManager.activeSonarrProfileID
        case .radarr:
            activeProfileID = serviceManager.activeRadarrProfileID
        case .prowlarr:
            activeProfileID = nil
        }

        if let activeProfileID, let profile = allProfiles.first(where: { $0.id == activeProfileID }) {
            return profile
        }
        return allProfiles.first { $0.resolvedServiceType == selectedService }
    }

    private var customFolders: [String] {
        currentProfile?.importFolders ?? []
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                emptyState
            } else if !hasConnectedService {
                ContentUnavailableView(
                    "Services Unreachable",
                    systemImage: "network.slash",
                    description: Text("Unable to reach your configured Sonarr or Radarr servers.")
                )
            } else {
                listContent
            }
        }
        .navigationTitle("Manual Import")
        .moreDestinationBackground(.manualImport)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Services Configured", systemImage: "tray.and.arrow.down")
        } description: {
            Text("Add a Sonarr or Radarr server in Settings to use Manual Import.")
        }
    }

    private var listContent: some View {
        List {
            if !rootFolders.isEmpty {
                Section {
                    ForEach(rootFolders) { folder in
                        NavigationLink(value: MoreDestination.manualImportScan(path: folder.path, service: selectedService)) {
                            locationRow(
                                icon: "internaldrive",
                                title: folder.path,
                                subtitle: "Library Root",
                                tint: .secondary
                            )
                        }
                    }
                } header: {
                    Text("Library Roots")
                }
            }

            Section {
                if customFolders.isEmpty {
                    Text("No saved locations")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customFolders, id: \.self) { path in
                        NavigationLink(value: MoreDestination.manualImportScan(path: path, service: selectedService)) {
                            locationRow(
                                icon: "folder",
                                title: path,
                                subtitle: "Custom",
                                tint: .blue
                            )
                        }
                    }
                    .onDelete(perform: removeBookmarks)
                }
            } header: {
                Text("Your Locations")
            } footer: {
                if customFolders.isEmpty {
                    Text("Save the paths to your download directories so you can quickly scan them for unmapped files.")
                }
            }

            Section {
                Button {
                    showAddLocation = true
                } label: {
                    Label("Add Custom Path", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedService)
        .safeAreaInset(edge: .top) {
            if availableServices.count > 1 {
                Picker("Service", selection: $selectedService.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                    ForEach(availableServices) { service in
                        Text(service.displayName).tag(service)
                    }
                }
                .pickerStyle(.segmented)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.horizontal, 48)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showAddLocation) {
            AddImportLocationSheet(service: selectedService) { path in
                addBookmark(path: path)
            }
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    private func locationRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func addBookmark(path: String) {
        guard let profile = currentProfile else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profile.importFolders.contains(trimmed) else { return }

        guard isAbsoluteImportPath(trimmed) else { return }

        withAnimation {
            profile.importFolders.append(trimmed)
        }
    }

    private func removeBookmarks(at offsets: IndexSet) {
        guard let profile = currentProfile else { return }
        withAnimation {
            profile.importFolders.remove(atOffsets: offsets)
        }
    }
}

// MARK: - Add Location Sheet

struct AddImportLocationSheet: View {
    let service: ArrServiceType
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Absolute path on server", text: $path)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("Example: /downloads/completed")
                }

                Section {
                    Text("This location will be saved for \(service.displayName).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Location")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }

                        guard isAbsoluteImportPath(trimmed) else { return }

                        onAdd(trimmed)
                        dismiss()
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Scan View Model

@Observable
@MainActor
private final class ManualImportScanViewModel {
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
    var groupedUnidentifiedFiles: [ManualImportGroup] = []
    var groupedBlockedFiles: [ManualImportGroup] = []
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
            let scannedFiles = await Task.detached(priority: .userInitiated) {
                Self.parseManualImportItems(from: jsonValues)
            }.value
            hasPerformedInitialScan = true
            Self.logger.info("Manual import scan parsed \(scannedFiles.count) items for \(self.path, privacy: .public)")

            importableFiles = []
            blockedFiles = []
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
            recomputeGroups()
            selectedFiles = []
            selectedBlockedFiles = []
            autoIdentifyCurrentFileName = nil
            autoIdentifyProcessedCount = 0
            autoIdentifyLastMatchedTitle = nil
            autoIdentifyLastOutcomeMessage = nil
        }
    }

    @discardableResult
    func performImport() async -> Bool {
        let availableIDs = Set(importableFiles.map(\.id))
        selectedFiles = selectedFiles.intersection(availableIDs)

        guard !selectedFiles.isEmpty else { return false }
        isImporting = true
        defer { isImporting = false }

        let importedIDs = selectedFiles
        let savedItems = importableFiles.filter { importedIDs.contains($0.id) }
        let filesToImport = savedItems.map { $0.importJSON(service: service, seasonFolder: seasonFolder) }
        let importNotificationKey = manualImportNotificationKey()

        do {
            let count = filesToImport.count
            let navAction = navigationAction
            let tabName = service == .sonarr ? "Series" : "Movies"
            let fileWord = count == 1 ? "file" : "files"
            let notificationCenter = InAppNotificationCenter.shared
            let fileNamesSummary = importedFileNamesSummary(items: savedItems)

            let fileMeta = savedItems.map { "\($0.fileName) mediaID:\($0.mediaID?.description ?? "nil")" }
            Self.logger.info("Sending \(count) \(fileWord) to \(self.service.displayName, privacy: .public): \(fileMeta, privacy: .private)")
            notificationCenter.showProgress(
                title: "Importing…",
                message: "Sending \(count) \(fileWord) to \(service.displayName):\n\(fileNamesSummary)",
                key: importNotificationKey
            )

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
                notificationCenter.replaceProgressWithSuccess(
                    key: importNotificationKey,
                    title: "Import Started",
                    message: "\(count) \(fileWord) submitted to \(service.displayName). Import is still running."
                )
                return false
            }

            if command.succeeded {
                // Items were already optimistically removed. Don't reload — rescanning the folder
                // will find the file again (hardlinks/copies leave the source in place) and undo
                // the removal, making it look like the import failed when it didn't.
                notificationCenter.replaceProgressWithSuccess(
                    key: importNotificationKey,
                    title: "Import Complete",
                    message: "\(count) \(fileWord) imported by \(service.displayName):\n\(fileNamesSummary)",
                    action: navAction.map { InAppBannerAction(label: "View \(tabName)", handler: $0) }
                )
                return true
            } else {
                let reason = manualImportFailureMessage(for: command)
                Self.logger.error("Command failed — \(reason, privacy: .private)")
                notificationCenter.replaceProgressWithError(
                    key: importNotificationKey,
                    title: "Import Failed",
                    message: reason
                )
                withAnimation(.snappy) {
                    importableFiles.append(contentsOf: savedItems)
                    recomputeGroups()
                }
                selectedFiles = importedIDs
                return false
            }
        } catch is CancellationError {
            Self.logger.info("Task cancelled")
            InAppNotificationCenter.shared.dismissBanner(matching: importNotificationKey)
            return false
        } catch ArrError.commandTimeout(let commandId, let lastKnownCommand) {
            Self.logger.error("Manual import command timed out while waiting — id:\(commandId ?? -1) status:\(lastKnownCommand?.status ?? "unknown", privacy: .public)")
            InAppNotificationCenter.shared.replaceProgressWithSuccess(
                key: importNotificationKey,
                title: "Import Started",
                message: "\(savedItems.count) \(savedItems.count == 1 ? "file" : "files") submitted to \(service.displayName). The import is still running; check Activity for progress."
            )
            return false
        } catch {
            Self.logger.error("Threw error — \(error, privacy: .private)")
            InAppNotificationCenter.shared.replaceProgressWithError(
                key: importNotificationKey,
                title: "Import Failed",
                message: error.localizedDescription
            )
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

    private func manualImportNotificationKey() -> String {
        "manual-import-\(service.displayName.lowercased())-\(UUID().uuidString)"
    }

    private func getManualImport(folder: String) async throws -> [JSONValue] {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            Self.logger.info("Requesting Sonarr manual import scan for \(folder, privacy: .public)")
            return try await client.getManualImport(folder: folder, seriesId: libraryItemID)
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            Self.logger.info("Requesting Radarr manual import scan for \(folder, privacy: .public)")
            return try await client.getManualImport(folder: folder, movieId: libraryItemID)
        case .prowlarr:
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
        case .prowlarr:
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
            case .prowlarr:
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
            case .prowlarr:
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
        Self.logger.info("Auto-identify requested for \(self.path, privacy: .public); unresolved \(self.unresolvedUnidentifiedCount) blocked-with-rejection \(self.blockedWithRejectionCount)")
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
                    } else {
                        skippedGroupIDs.insert(groupID)
                        autoIdentifyLastOutcomeMessage = "No library match found for \(group.displayTitle)."
                    }
                case .prowlarr:
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
            case .prowlarr:
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
        identifyingTarget = nil
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
            case .prowlarr:
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

    func recomputeGroups() {
        groupedImportableFiles = Self.makeImportableGroups(from: importableFiles)
        let unidentified = blockedFiles.filter(\.isAutoMatchCandidate)
        let blocked = blockedFiles.filter { !$0.isAutoMatchCandidate }
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

private func posterURL(from images: [ArrImage]?) -> URL? {
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

private func isAbsoluteImportPath(_ path: String) -> Bool {
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

struct ManualImportScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateToSeriesTab) private var navigateToSeriesTab
    @Environment(\.navigateToMoviesTab) private var navigateToMoviesTab
    @State private var viewModel: ManualImportScanViewModel
    @State private var showBlockedSelectionReview = false
    @State private var isSelectingMode = false
    @State private var reviewingGroup: ManualImportGroup?
    @State private var reviewingBlockedGroup: ManualImportGroup?
    let showsCloseButton: Bool

    private var unidentifiedFiles: [ManualImportItem] {
        viewModel.blockedFiles.filter(\.isAutoMatchCandidate)
    }
    private var actuallyBlockedFiles: [ManualImportItem] {
        viewModel.blockedFiles.filter { !$0.isAutoMatchCandidate }
    }
    private var hasAnyFiles: Bool {
        !viewModel.importableFiles.isEmpty || !viewModel.blockedFiles.isEmpty
    }

    private func blockedGroupSelectionState(_ group: ManualImportGroup) -> GroupSelectionState {
        let selectedCount = group.items.filter { viewModel.selectedBlockedFiles.contains($0.id) }.count
        if selectedCount == 0 { return .none }
        if selectedCount == group.items.count { return .all }
        return .partial
    }

    private var autoIdentifyStatusText: String {
        if let current = viewModel.autoIdentifyCurrentFileName, viewModel.isAutoIdentifying {
            return "Matching \(current)"
        }
        if let outcome = viewModel.autoIdentifyLastOutcomeMessage {
            return outcome
        }
        if let lastMatchedTitle = viewModel.autoIdentifyLastMatchedTitle {
            return "Last match: \(lastMatchedTitle)"
        }
        let count = viewModel.unresolvedUnidentifiedCount
        return count == 1 ? "1 file waiting for automatic matching." : "\(count) files waiting for automatic matching."
    }

    private var autoIdentifyProgressText: String {
        let processed = viewModel.autoIdentifyProcessedCount
        if viewModel.isAutoIdentifying {
            return processed == 0 ? "Running" : "Matched \(processed)"
        }
        if processed > 0 {
            return "Matched \(processed)"
        }
        return "Idle"
    }

    private var shouldShowAutoIdentifySection: Bool {
        !viewModel.blockedFiles.isEmpty
    }

    private func groupSelectionState(_ group: ManualImportGroup) -> GroupSelectionState {
        let selectedCount = group.items.filter { viewModel.selectedFiles.contains($0.id) }.count
        if selectedCount == 0 { return .none }
        if selectedCount == group.items.count { return .all }
        return .partial
    }

    init(
        path: String,
        service: ArrServiceType,
        serviceManager: ArrServiceManager,
        libraryItemID: Int? = nil,
        showsCloseButton: Bool = false
    ) {
        _viewModel = State(wrappedValue: ManualImportScanViewModel(path: path, service: service, serviceManager: serviceManager, libraryItemID: libraryItemID))
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        List {
            if viewModel.isScanning && viewModel.importableFiles.isEmpty && viewModel.blockedFiles.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        ProgressView("Scanning for files…")
                        Text(viewModel.scanStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else if viewModel.importableFiles.isEmpty && viewModel.blockedFiles.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Importable Files",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("No unmapped files found in this directory.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                if viewModel.service == .sonarr && !viewModel.importableFiles.isEmpty {
                    Section {
                        Toggle(isOn: Binding(
                            get: { viewModel.seasonFolder },
                            set: { viewModel.seasonFolder = $0 }
                        )) {
                            Label("Season Folder", systemImage: "folder.badge.plus")
                        }
                    } footer: {
                        Text("Place imported files in the season subfolder rather than the series root.")
                    }
                }

                if !viewModel.groupedImportableFiles.isEmpty {
                    Section {
                        ForEach(viewModel.groupedImportableFiles) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: .ready,
                                selectionState: groupSelectionState(group),
                                isSelectingMode: isSelectingMode,
                                onToggle: {
                                    if isSelectingMode {
                                        withAnimation(.snappy) {
                                            viewModel.toggleGroup(itemIDs: group.items.map(\.id))
                                        }
                                    } else {
                                        reviewingGroup = group
                                    }
                                }
                            )
                            .contextMenu {
                                Button("Review", systemImage: "list.bullet.rectangle") {
                                    reviewingGroup = group
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    reviewingGroup = group
                                } label: {
                                    Label("Review", systemImage: "list.bullet.rectangle")
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Ready to Import")
                    }
                }

                if shouldShowAutoIdentifySection {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                if viewModel.isAutoIdentifying {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: viewModel.unresolvedUnidentifiedCount == 0 ? "checkmark.circle.fill" : "sparkle.magnifyingglass")
                                        .foregroundStyle(viewModel.unresolvedUnidentifiedCount == 0 ? .green : .secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(autoIdentifyProgressText)
                                        .font(.subheadline.weight(.semibold))
                                    Text(autoIdentifyStatusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)

                                Button(viewModel.isAutoIdentifying ? "Stop" : "Auto Match") {
                                    if viewModel.isAutoIdentifying {
                                        viewModel.stopAutoIdentify()
                                    } else {
                                        viewModel.startAutoIdentify()
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .disabled(viewModel.groupedUnidentifiedFiles.isEmpty && !viewModel.isAutoIdentifying)
                            }
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("Identification Status")
                    }
                }

                if !viewModel.groupedUnidentifiedFiles.isEmpty {
                    Section {
                        ForEach(viewModel.groupedUnidentifiedFiles) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: .unidentified,
                                selectionState: blockedGroupSelectionState(group),
                                isSelectingMode: isSelectingMode,
                                onToggle: {
                                    if isSelectingMode {
                                        withAnimation(.snappy) {
                                            viewModel.toggleBlockedGroup(itemIDs: group.items.map(\.id))
                                        }
                                    } else {
                                        viewModel.beginIdentifying(group: group)
                                    }
                                }
                            )
                            .contextMenu {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    viewModel.beginIdentifying(group: group)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    viewModel.beginIdentifying(group: group)
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Needs Identification")
                    }
                }

                if !viewModel.groupedBlockedFiles.isEmpty {
                    Section {
                        ForEach(viewModel.groupedBlockedFiles) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: .blocked,
                                selectionState: blockedGroupSelectionState(group),
                                isSelectingMode: isSelectingMode,
                                onToggle: {
                                    if isSelectingMode {
                                        withAnimation(.snappy) {
                                            viewModel.toggleBlockedGroup(itemIDs: group.items.map(\.id))
                                        }
                                    } else {
                                        reviewingBlockedGroup = group
                                    }
                                }
                            )
                            .contextMenu {
                                Button("Review", systemImage: "list.bullet.rectangle") {
                                    reviewingBlockedGroup = group
                                }
                                if !group.isIdentified {
                                    Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                        viewModel.beginIdentifying(group: group)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    reviewingBlockedGroup = group
                                } label: {
                                    Label("Review", systemImage: "list.bullet.rectangle")
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Blocked")
                    } footer: {
                        Text("Files rejected by \(viewModel.service.displayName) due to quality, format, or other issues can't be imported until the underlying problem is resolved.")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle(viewModel.folderName)
        .navigationSubtitle(navigationSubtitleText)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable {
            await viewModel.loadFiles()
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }

            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                if isSelectingMode {
                    Button(viewModel.allSelected ? "Deselect All" : "Select All") {
                        withAnimation(.snappy) {
                            viewModel.toggleSelectAll()
                        }
                    }
                    .font(.subheadline)

                    Button {
                        if !viewModel.selectedBlockedFiles.isEmpty {
                            showBlockedSelectionReview = true
                        } else {
                            if showsCloseButton {
                                dismiss()
                            }
                            Task {
                                await viewModel.performImport()
                            }
                        }
                    } label: {
                        if viewModel.isImporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Import")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isBusy || !viewModel.hasAnySelection)
                }

                if hasAnyFiles {
                    Button(isSelectingMode ? "Done" : "Select") {
                        withAnimation(.snappy) {
                            isSelectingMode.toggle()
                            if !isSelectingMode {
                                viewModel.selectedFiles.removeAll()
                                viewModel.selectedBlockedFiles.removeAll()
                            }
                        }
                    }
                    .fontWeight(isSelectingMode ? .semibold : .regular)
                }
            }
        }
        .sheet(item: $viewModel.identifyingTarget) { target in
            ManualImportIdentifySheet(
                target: target,
                viewModel: viewModel,
                importAfterAdding: true,
                showsCancelButton: true,
                wrapInNavigationStack: true
            )
        }
        .sheet(isPresented: $showBlockedSelectionReview) {
            ManualImportBlockedSelectionSheet(viewModel: viewModel)
        }
        .sheet(item: $reviewingGroup) { group in
            ManualImportGroupSheet(initialGroup: group, viewModel: viewModel)
        }
        .sheet(item: $reviewingBlockedGroup) { group in
            ManualImportBlockedGroupSheet(group: group, viewModel: viewModel)
        }
        .task {
            if !showsCloseButton {
                switch viewModel.service {
                case .sonarr: viewModel.navigationAction = navigateToSeriesTab
                case .radarr: viewModel.navigationAction = navigateToMoviesTab
                case .prowlarr: break
                }
            }
            if !viewModel.hasPerformedInitialScan {
                await viewModel.loadFiles()
            }
            Task { await viewModel.loadLibraryIfNeeded() }
            viewModel.startAutoIdentify()
        }
        .onDisappear {
            viewModel.stopAutoIdentify()
        }
    }

    private var navigationSubtitleText: String {
        if isSelectingMode && viewModel.hasAnySelection {
            let count = viewModel.selectedFiles.count + viewModel.selectedBlockedFiles.count
            return "\(count) file\(count == 1 ? "" : "s") selected"
        }
        var parts: [String] = []
        if !viewModel.groupedImportableFiles.isEmpty {
            let titles = viewModel.groupedImportableFiles.count
            let files = viewModel.importableFiles.count
            parts.append("\(files) ready · \(titles) title\(titles == 1 ? "" : "s")")
        }
        if !viewModel.groupedUnidentifiedFiles.isEmpty {
            parts.append("\(viewModel.groupedUnidentifiedFiles.count) unidentified")
        }
        if !viewModel.groupedBlockedFiles.isEmpty {
            parts.append("\(viewModel.groupedBlockedFiles.count) blocked")
        }
        return parts.isEmpty ? viewModel.path : parts.joined(separator: " · ")
    }
}

struct ArrQueueImportIssueResolutionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ManualImportScanViewModel

    let resolution: ArrQueueImportIssueResolution
    let onImportCompleted: () async -> Void

    private var readyItems: [ManualImportItem] {
        viewModel.importableFiles
    }

    private var hasScannedFiles: Bool {
        !viewModel.importableFiles.isEmpty || !viewModel.blockedFiles.isEmpty
    }

    init(
        resolution: ArrQueueImportIssueResolution,
        serviceManager: ArrServiceManager,
        onImportCompleted: @escaping () async -> Void
    ) {
        self.resolution = resolution
        self.onImportCompleted = onImportCompleted
        _viewModel = State(wrappedValue: ManualImportScanViewModel(
            path: resolution.path,
            service: resolution.service,
            serviceManager: serviceManager,
            libraryItemID: resolution.libraryItemID
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(resolution.status, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text(resolution.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(resolution.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        LabeledContent("Import Path") {
                            Text(resolution.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let rootFolder = resolution.rootFolder, !rootFolder.isEmpty {
                            LabeledContent("Library Root") {
                                Text(rootFolder)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Queue Issue")
                }

                if viewModel.isScanning && !hasScannedFiles {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(viewModel.scanStatusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !hasScannedFiles {
                    Section {
                        ContentUnavailableView(
                            "No Files Found",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("No manual-import candidates were found at this queue item's import path.")
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                if !readyItems.isEmpty {
                    Section {
                        ForEach(readyItems) { item in
                            NavigationLink {
                                ManualImportIdentifySheet(
                                    target: identifyTarget(for: item),
                                    viewModel: viewModel,
                                    importAfterAdding: false,
                                    showsCancelButton: false,
                                    wrapInNavigationStack: false
                                )
                            } label: {
                                ManualImportRow(
                                    item: item,
                                    isSelected: false,
                                    isSelectingMode: false,
                                    onToggle: {}
                                )
                            }
                        }
                    } header: {
                        Text("Ready to Import")
                    } footer: {
                        Text("Tap a file to change its match, or import the ready files from this sheet.")
                    }
                }

                if !viewModel.groupedUnidentifiedFiles.isEmpty {
                    Section {
                        ForEach(viewModel.groupedUnidentifiedFiles) { group in
                            NavigationLink {
                                ManualImportIdentifySheet(
                                    target: identifyTarget(for: group),
                                    viewModel: viewModel,
                                    importAfterAdding: false,
                                    showsCancelButton: false,
                                    wrapInNavigationStack: false
                                )
                            } label: {
                                ManualImportGroupRow(
                                    group: group,
                                    style: .unidentified,
                                    selectionState: .none,
                                    isSelectingMode: false,
                                    onToggle: {}
                                )
                            }
                        }
                    } header: {
                        Text("Needs Identification")
                    } footer: {
                        Text("Choose the correct \(resolution.service == .radarr ? "movie" : "series") match. The file will move into Ready to Import in this same sheet.")
                    }
                }

                if !viewModel.groupedBlockedFiles.isEmpty {
                    Section {
                        ForEach(viewModel.groupedBlockedFiles) { group in
                            NavigationLink {
                                ManualImportBlockedGroupInlineView(group: group, viewModel: viewModel)
                            } label: {
                                ManualImportGroupRow(
                                    group: group,
                                    style: .blocked,
                                    selectionState: .none,
                                    isSelectingMode: false,
                                    onToggle: {}
                                )
                            }
                        }
                    } header: {
                        Text("Still Blocked")
                    } footer: {
                        Text("These files need another server-side fix before they can be imported.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("Resolve Import Issue")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(readyItems.count == 1 ? "Import" : "Import \(readyItems.count)") {
                            let items = readyItems
                            Task {
                                let succeeded = await viewModel.importItems(items)
                                if succeeded {
                                    await onImportCompleted()
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(readyItems.isEmpty || viewModel.isBusy)
                    }
                }
            }
            .refreshable {
                await viewModel.loadFiles()
            }
            .task {
                if !viewModel.hasPerformedInitialScan {
                    await viewModel.loadFiles()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func identifyTarget(for item: ManualImportItem) -> ManualImportIdentifyTarget {
        ManualImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
    }

    private func identifyTarget(for group: ManualImportGroup) -> ManualImportIdentifyTarget {
        let label = group.items.count == 1
            ? (group.items.first?.fileName ?? group.displayTitle)
            : "\(group.displayTitle) · \(group.items.count) files"
        return ManualImportIdentifyTarget(id: group.id, items: group.items, displayLabel: label)
    }
}

private struct ManualImportBlockedGroupInlineView: View {
    let group: ManualImportGroup
    let viewModel: ManualImportScanViewModel

    private var currentItems: [ManualImportItem] {
        let ids = Set(group.items.map(\.id))
        return viewModel.blockedFiles.filter { ids.contains($0.id) }
    }

    var body: some View {
        List {
            if !group.rejectionReasons.isEmpty {
                Section {
                    ForEach(group.rejectionReasons, id: \.self) { reason in
                        Label(reason, systemImage: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Rejections")
                }
            }

            Section {
                ForEach(currentItems) { item in
                    ManualImportBlockedRow(
                        item: item,
                        isSelected: false,
                        isSelectingMode: false,
                        onToggle: {}
                    )
                }
            } header: {
                Text(currentItems.count == 1 ? "File" : "\(currentItems.count) Files")
            } footer: {
                Text("Resolve these rejection reasons in \(viewModel.service.displayName), then refresh the resolver.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle(group.displayTitle)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Models

private struct ManualImportEpisode: Sendable {
    let number: Int
    let title: String
}

private struct ManualImportItem: Identifiable, Sendable {
    let id: String
    let path: String
    let fileName: String
    let size: Int64
    let rejectionReasons: [String]
    let warningMessages: [String]
    let originalJSON: JSONValue

    // Identified media
    let mediaTitle: String?
    let mediaID: Int?
    let posterURL: URL?
    let seasonNumber: Int?
    let episodes: [ManualImportEpisode]
    let qualityName: String?

    /// A file is only importable if it has no rejections AND is matched to a real library item (non-zero ID).
    /// Files with id == 0 or no media match would cause "Movie/Series with id 0 does not exist" on import.
    var isImportable: Bool {
        rejectionReasons.isEmpty && (mediaID ?? 0) > 0
    }

    /// Files that only fail because the show/movie is unknown should still be treated as
    /// candidates for automatic matching rather than hard-blocked items.
    var isAutoMatchCandidate: Bool {
        guard !isImportable else { return false }
        guard !rejectionReasons.isEmpty else { return true }
        return rejectionReasons.allSatisfy(Self.isResolvableIdentificationReason(_:))
    }

    /// The JSON to send in the ManualImport command.
    /// Always sets the flat `movieId`/`seriesId` field based on the service type, since
    /// Radarr/Sonarr's command handler reads the flat field and scan results often have it as 0.
    /// Also injects a minimal `movie`/`series` object when one is absent (user-identified files).
    func importJSON(service: ArrServiceType, seasonFolder: Bool = true) -> JSONValue {
        guard let id = mediaID, id > 0,
              case .object(var dict) = originalJSON else { return originalJSON }
        switch service {
        case .radarr:
            dict["movieId"] = .number(Double(id))
            if dict["movie"] == nil {
                dict["movie"] = .object(["id": .number(Double(id))])
            }
        case .sonarr:
            dict["seriesId"] = .number(Double(id))
            dict["seasonFolder"] = .bool(seasonFolder)
            // episodeIds must be a non-null array — Sonarr throws ArgumentNullException if absent
            if case .array(_) = dict["episodeIds"] {
                // already present, keep it
            } else if case .array(let eps) = dict["episodes"] {
                let ids: [JSONValue] = eps.compactMap { ep -> JSONValue? in
                    guard case .object(let d) = ep, case .number(let n) = d["id"] else { return nil }
                    return .number(n)
                }
                dict["episodeIds"] = .array(ids)
            } else {
                dict["episodeIds"] = .array([])
            }
            if dict["series"] == nil {
                dict["series"] = .object(["id": .number(Double(id))])
            }
        case .prowlarr:
            break
        }
        return .object(dict)
    }

    /// Returns a copy of this item identified as the given library entry.
    func withIdentification(mediaID: Int, title: String, posterURL: URL?) -> ManualImportItem {
        ManualImportItem(
            id: self.id,
            path: self.path,
            fileName: self.fileName,
            size: self.size,
            rejectionReasons: [],
            warningMessages: self.warningMessages,
            originalJSON: self.originalJSON,
            mediaTitle: title,
            mediaID: mediaID,
            posterURL: posterURL,
            seasonNumber: self.seasonNumber,
            episodes: self.episodes,
            qualityName: self.qualityName
        )
    }

    private init(
        id: String, path: String, fileName: String, size: Int64,
        rejectionReasons: [String], warningMessages: [String], originalJSON: JSONValue,
        mediaTitle: String?, mediaID: Int?, posterURL: URL?,
        seasonNumber: Int?, episodes: [ManualImportEpisode], qualityName: String?
    ) {
        self.id = id; self.path = path; self.fileName = fileName; self.size = size
        self.rejectionReasons = rejectionReasons; self.warningMessages = warningMessages
        self.originalJSON = originalJSON; self.mediaTitle = mediaTitle; self.mediaID = mediaID
        self.posterURL = posterURL; self.seasonNumber = seasonNumber; self.episodes = episodes
        self.qualityName = qualityName
    }

    nonisolated init?(json: JSONValue) {
        guard case .object(let dict) = json else { return nil }

        if case .string(let p) = dict["path"] {
            self.path = p
            self.id = p
        } else {
            return nil
        }

        if case .string(let n) = dict["name"] {
            self.fileName = (n as NSString).lastPathComponent
        } else if case .string(let fn) = dict["fileName"] {
            self.fileName = (fn as NSString).lastPathComponent
        } else {
            self.fileName = (path as NSString).lastPathComponent
        }

        if case .number(let s) = dict["size"] {
            self.size = Int64(s)
        } else {
            self.size = 0
        }

        let parsedRejections = ManualImportItem.extractMessages(from: dict["rejections"])
        self.warningMessages = ManualImportItem.extractMessages(from: dict["warnings"])
        self.originalJSON = json

        // Extract identified media from series or movie object
        let mediaDict: [String: JSONValue]?
        if case .object(let s) = dict["series"] { mediaDict = s }
        else if case .object(let m) = dict["movie"] { mediaDict = m }
        else { mediaDict = nil }

        if let mediaDict {
            if case .string(let t) = mediaDict["title"] { self.mediaTitle = t } else { self.mediaTitle = nil }
            if case .number(let i) = mediaDict["id"] { self.mediaID = Int(i) } else { self.mediaID = nil }
            self.posterURL = ManualImportItem.extractPosterURL(from: mediaDict["images"])
        } else {
            self.mediaTitle = nil
            self.mediaID = nil
            self.posterURL = nil
        }

        self.rejectionReasons = parsedRejections

        if case .number(let sn) = dict["seasonNumber"] { self.seasonNumber = Int(sn) } else { self.seasonNumber = nil }

        if case .array(let eps) = dict["episodes"] {
            self.episodes = eps.compactMap { ep -> ManualImportEpisode? in
                guard case .object(let epDict) = ep,
                      case .number(let num) = epDict["episodeNumber"] else { return nil }
                let title: String
                if case .string(let t) = epDict["title"] { title = t } else { title = "" }
                return ManualImportEpisode(number: Int(num), title: title)
            }
        } else {
            self.episodes = []
        }

        if case .object(let q) = dict["quality"],
           case .object(let qi) = q["quality"],
           case .string(let qn) = qi["name"] {
            self.qualityName = qn
        } else {
            self.qualityName = nil
        }
    }

    nonisolated private static func extractPosterURL(from value: JSONValue?) -> URL? {
        guard case .array(let images) = value else { return nil }
        for imageValue in images {
            guard case .object(let img) = imageValue,
                  case .string(let coverType) = img["coverType"],
                  coverType == "poster" else { continue }
            let urlString: String?
            if case .string(let s) = img["remoteUrl"] { urlString = s }
            else if case .string(let s) = img["url"] { urlString = s }
            else { urlString = nil }
            if let urlString, let url = URL(string: urlString) { return url }
        }
        return nil
    }

    nonisolated private static func extractMessages(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let values):
            return values.flatMap(extractMessages(from:))
        case .object(let object):
            if case .string(let reason) = object["reason"] {
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return [trimmed] }
            }
            if case .string(let message) = object["message"] {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return [trimmed] }
            }
            if case .string(let title) = object["title"] {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return [trimmed] }
            }
            return object.keys.sorted().flatMap { key in
                extractMessages(from: object[key])
            }
        default:
            return []
        }
    }

    nonisolated private static func isResolvableIdentificationReason(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return true }

        let resolvablePhrases = [
            "unknown show",
            "unknown series",
            "unknown movie",
            "unable to find series",
            "unable to find show",
            "unable to find movie",
            "no matching series",
            "no matching show",
            "no matching movie",
            "series is unknown",
            "movie is unknown",
            "could not be parsed",
            "unable to parse"
        ]

        return resolvablePhrases.contains { normalized.contains($0) }
    }
}

private enum GroupSelectionState { case none, partial, all }

struct ArrQueueImportIssueResolution: Identifiable, Equatable {
    let id: Int
    let path: String
    let service: ArrServiceType
    let libraryItemID: Int?
    let title: String
    let status: String
    let message: String
    let rootFolder: String?
}

/// What the identify sheet is operating on. Wraps either a single file (re-identify)
/// or every file in an inferred-title group (cascade identify).
private struct ManualImportIdentifyTarget: Identifiable, Sendable {
    let id: String
    let items: [ManualImportItem]
    let displayLabel: String
}

private struct ManualImportGroup: Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case identified(mediaID: Int)
        case unidentified(inferredKey: String)
    }

    let kind: Kind
    let displayTitle: String
    let posterURL: URL?
    let items: [ManualImportItem]

    var id: String {
        switch kind {
        case .identified(let id): return "id-\(id)"
        case .unidentified(let key): return "un-\(key)"
        }
    }

    var mediaID: Int? {
        if case .identified(let id) = kind { return id }
        return nil
    }

    var inferredKey: String? {
        if case .unidentified(let key) = kind { return key }
        return nil
    }

    var isIdentified: Bool {
        if case .identified = kind { return true }
        return false
    }

    var hasRejections: Bool {
        items.contains { !$0.rejectionReasons.isEmpty }
    }

    var rejectionReasons: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for item in items {
            for reason in item.rejectionReasons where seen.insert(reason).inserted {
                ordered.append(reason)
            }
        }
        return ordered
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    var episodeSummary: String {
        let seasons = Set(items.compactMap(\.seasonNumber)).sorted()
        let count = items.count
        if seasons.isEmpty {
            return count == 1 ? "1 file" : "\(count) files"
        }
        let seasonLabel: String
        if seasons.count == 1 {
            seasonLabel = "Season \(seasons[0])"
        } else {
            seasonLabel = "S\(String(format: "%02d", seasons.first!))–S\(String(format: "%02d", seasons.last!))"
        }
        return "\(seasonLabel) · \(count) episode\(count == 1 ? "" : "s")"
    }

    var fileSummary: String {
        guard let first = items.first else { return "" }
        if items.count == 1 {
            return first.fileName
        }
        return "\(first.fileName) + \(items.count - 1) more"
    }

    var qualityNames: [String] {
        Array(Set(items.compactMap(\.qualityName))).sorted()
    }
}

private struct ManualImportRow: View {
    let item: ManualImportItem
    let isSelected: Bool
    let isSelectingMode: Bool
    let onToggle: () -> Void

    private var episodeLabel: String? {
        guard let season = item.seasonNumber, !item.episodes.isEmpty else { return nil }
        let numbers = item.episodes.map { "E\(String(format: "%02d", $0.number))" }.joined(separator: " · ")
        let title = item.episodes.count == 1 ? item.episodes[0].title : nil
        var label = "S\(String(format: "%02d", season)) · \(numbers)"
        if let title, !title.isEmpty { label += " · \"\(title)\"" }
        return label
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                ArrArtworkView(url: item.posterURL) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        Image(systemName: item.warningMessages.isEmpty ? "photo" : "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(
                                item.warningMessages.isEmpty
                                    ? AnyShapeStyle(.tertiary)
                                    : AnyShapeStyle(.orange)
                            )
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.mediaTitle ?? item.fileName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if let quality = item.qualityName {
                            statusChip(quality, color: .blue)
                        }
                    }

                    if let epLabel = episodeLabel {
                        Text(epLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if item.mediaTitle != nil {
                        Text(item.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    statusChip(ByteFormatter.format(bytes: item.size), color: .secondary)

                    if let warning = item.warningMessages.first {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if isSelectingMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct ManualImportBlockedRow: View {
    let item: ManualImportItem
    let isSelected: Bool
    let isSelectingMode: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                ArrArtworkView(url: item.posterURL) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.mediaTitle ?? item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(item.rejectionReasons.enumerated()), id: \.offset) { _, reason in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(reason)
                            }
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if item.mediaTitle != nil {
                        Text(item.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    statusChip(ByteFormatter.format(bytes: item.size), color: .secondary)
                }

                Spacer(minLength: 0)

                if isSelectingMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private enum ManualImportGroupRowStyle {
    case ready
    case unidentified
    case blocked

    var placeholderIcon: String {
        switch self {
        case .ready: return "photo"
        case .unidentified: return "questionmark.circle"
        case .blocked: return "xmark.octagon"
        }
    }

    var accentColor: Color {
        switch self {
        case .ready: return .secondary
        case .unidentified: return .orange
        case .blocked: return .red
        }
    }

    var badge: (text: String, color: Color)? {
        switch self {
        case .ready: return nil
        case .unidentified: return ("Unidentified", .orange)
        case .blocked: return ("Blocked", .red)
        }
    }
}

private struct ManualImportGroupRow: View {
    let group: ManualImportGroup
    let style: ManualImportGroupRowStyle
    let selectionState: GroupSelectionState
    let isSelectingMode: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                ArrArtworkView(url: group.posterURL) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        Image(systemName: style.placeholderIcon)
                            .font(.system(size: 14))
                            .foregroundStyle(style == .ready
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(style.accentColor))
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let badge = style.badge {
                            statusChip(badge.text, color: badge.color)
                        }
                    }

                    Text(group.episodeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if group.isIdentified {
                        Text(group.fileSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 4) {
                        ForEach(group.qualityNames, id: \.self) { name in
                            statusChip(name, color: .blue)
                        }
                        statusChip(ByteFormatter.format(bytes: group.totalSize), color: .secondary)
                    }

                    if style == .blocked, let firstReason = group.rejectionReasons.first {
                        let extra = group.rejectionReasons.count - 1
                        let suffix = extra > 0 ? " · +\(extra) more" : ""
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Image(systemName: "xmark.circle.fill")
                            Text("\(firstReason)\(suffix)")
                                .lineLimit(2)
                        }
                        .font(.caption2)
                        .foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 0)

                if isSelectingMode {
                    selectionIcon
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectionIcon: some View {
        switch selectionState {
        case .all:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AnyShapeStyle(.tint))
        case .partial:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(AnyShapeStyle(.orange))
        case .none:
            Image(systemName: "circle")
                .foregroundStyle(AnyShapeStyle(.secondary))
        }
    }
}

private func statusChip(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
}

// MARK: - Group Review Sheet

private struct ManualImportGroupSheet: View {
    let initialGroup: ManualImportGroup
    let viewModel: ManualImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: ManualImportIdentifyTarget?

    private var currentItems: [ManualImportItem] {
        initialGroup.items.compactMap { item in
            viewModel.importableFiles.first { $0.id == item.id }
        }
    }

    private func identifyTarget(for item: ManualImportItem) -> ManualImportIdentifyTarget {
        ManualImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
    }

    var body: some View {
        NavigationStack {
            List {
                if currentItems.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "All Imported",
                            systemImage: "checkmark.circle.fill",
                            description: Text("All files in this group have been imported.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    if viewModel.service == .sonarr {
                        Section {
                            Toggle(isOn: Binding(
                                get: { viewModel.seasonFolder },
                                set: { viewModel.seasonFolder = $0 }
                            )) {
                                Label("Season Folder", systemImage: "folder.badge.plus")
                            }
                        } footer: {
                            Text("Place imported files in the season subfolder.")
                        }
                    }

                    Section {
                        ForEach(currentItems) { item in
                            ManualImportRow(
                                item: item,
                                isSelected: false,
                                isSelectingMode: false,
                                onToggle: { identifyingTarget = identifyTarget(for: item) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Re-identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: item)
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text(currentItems.count == 1 ? "File" : "\(currentItems.count) Files")
                    } footer: {
                        Text("Tap any file to re-identify it.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle(initialGroup.displayTitle)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(currentItems.count == 1 ? "Import" : "Import All") {
                            let items = currentItems
                            dismiss()
                            Task { await viewModel.importItems(items) }
                        }
                        .fontWeight(.semibold)
                        .disabled(currentItems.isEmpty)
                    }
                }
            }
            .sheet(item: $identifyingTarget) { target in
                ManualImportIdentifySheet(
                    target: target,
                    viewModel: viewModel,
                    importAfterAdding: false,
                    showsCancelButton: true,
                    wrapInNavigationStack: true
                )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ManualImportBlockedSelectionSheet: View {
    let viewModel: ManualImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: ManualImportIdentifyTarget?

    private var blockedItems: [ManualImportItem] {
        viewModel.selectedBlockedItems
    }

    private func identifyTarget(for item: ManualImportItem) -> ManualImportIdentifyTarget {
        ManualImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
    }

    private var readyItems: [ManualImportItem] {
        viewModel.importableFiles.filter { viewModel.selectedFiles.contains($0.id) }
    }

    private var unresolvedSelectedBlockedCount: Int {
        blockedItems.count
    }

    var body: some View {
        NavigationStack {
            List {
                if !readyItems.isEmpty {
                    Section {
                        ForEach(readyItems) { item in
                            ManualImportRow(item: item, isSelected: false, isSelectingMode: false) {}
                        }
                    } header: {
                        Text("Ready to Import")
                    } footer: {
                        Text("These files are identified and queued for the final import step.")
                    }
                }

                if blockedItems.isEmpty {
                    Section {
                        ContentUnavailableView(
                            readyItems.isEmpty ? "No Unidentified Files Left" : "Ready to Import",
                            systemImage: readyItems.isEmpty ? "checkmark.circle" : "checkmark.circle.fill",
                            description: Text(readyItems.isEmpty
                                ? "Everything in this selection has been cleared."
                                : "All selected blocked files are identified. You can import the ready files now.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(blockedItems) { item in
                            ManualImportBlockedRow(
                                item: item,
                                isSelected: false,
                                isSelectingMode: false,
                                onToggle: { identifyingTarget = identifyTarget(for: item) }
                            )
                            .contextMenu {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: item)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: item)
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Identify Before Import")
                    } footer: {
                        Text("Tap any file to identify it and move it to the ready list.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("Review Selection")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(unresolvedSelectedBlockedCount > 0 ? "Resolve \(unresolvedSelectedBlockedCount)" : "Import \(readyItems.count)") {
                        dismiss()
                        Task {
                            await viewModel.performImport()
                        }
                    }
                    .disabled(unresolvedSelectedBlockedCount > 0 || viewModel.selectedFiles.isEmpty || viewModel.isBusy)
                }
            }
            .sheet(item: $identifyingTarget) { target in
                ManualImportIdentifySheet(
                    target: target,
                    viewModel: viewModel,
                    importAfterAdding: false,
                    showsCancelButton: true,
                    wrapInNavigationStack: true
                )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Blocked Group Sheet

private struct ManualImportBlockedGroupSheet: View {
    let group: ManualImportGroup
    let viewModel: ManualImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: ManualImportIdentifyTarget?

    private var currentItems: [ManualImportItem] {
        // Re-read from viewModel.blockedFiles so live updates (e.g. an item gets identified)
        // refresh the list while the sheet is open.
        let ids = Set(group.items.map(\.id))
        return viewModel.blockedFiles.filter { ids.contains($0.id) }
    }

    private func identifyTarget(for item: ManualImportItem) -> ManualImportIdentifyTarget {
        ManualImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
    }

    var body: some View {
        NavigationStack {
            List {
                if currentItems.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Group Resolved",
                            systemImage: "checkmark.circle",
                            description: Text("All files in this group have moved out of the blocked list.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    if !group.rejectionReasons.isEmpty {
                        Section {
                            ForEach(group.rejectionReasons, id: \.self) { reason in
                                Label(reason, systemImage: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                        } header: {
                            Text("Rejections")
                        } footer: {
                            Text("These reasons come from \(viewModel.service.displayName). Resolve them on the server (e.g. lower the quality cutoff) before re-importing.")
                        }
                    }

                    Section {
                        ForEach(currentItems) { item in
                            ManualImportBlockedRow(
                                item: item,
                                isSelected: false,
                                isSelectingMode: false,
                                onToggle: { identifyingTarget = identifyTarget(for: item) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: item)
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text(currentItems.count == 1 ? "File" : "\(currentItems.count) Files")
                    } footer: {
                        Text("Tap any file to re-identify it.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle(group.displayTitle)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $identifyingTarget) { target in
                ManualImportIdentifySheet(
                    target: target,
                    viewModel: viewModel,
                    importAfterAdding: false,
                    showsCancelButton: true,
                    wrapInNavigationStack: true
                )
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Identify Sheet

private struct ManualImportIdentifySheet: View {
    let target: ManualImportIdentifyTarget
    let viewModel: ManualImportScanViewModel
    let importAfterAdding: Bool
    let showsCancelButton: Bool
    let wrapInNavigationStack: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private var representativeFileName: String {
        target.items.first?.fileName ?? target.displayLabel
    }

    private var navigationTitle: String {
        target.items.count > 1 ? "Identify \(target.items.count) Files" : "Identify File"
    }

    var body: some View {
        Group {
            if wrapInNavigationStack {
                NavigationStack {
                    content
                }
            } else {
                content
            }
        }
        .task {
            await viewModel.loadAutoSuggestions(for: representativeFileName)
        }
        .modifier(IdentifySheetPresentationModifier(isPresentedAsSheet: wrapInNavigationStack))
    }

    private var content: some View {
        Group {
            if viewModel.isLoadingLibrary {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isAddingToLibrary {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Adding to library…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library or Discover")
        #else
        .searchable(text: $searchText, prompt: "Search your library or Discover")
        #endif
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await viewModel.searchCatalog(term: newValue)
            }
        }
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            Section {
                if target.items.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.displayLabel)
                            .font(.subheadline.weight(.semibold))
                        Text("Your choice will apply to all \(target.items.count) files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(target.displayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if viewModel.service == .radarr {
                radarrSections
            } else {
                sonarrSections
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    @ViewBuilder
    private var radarrSections: some View {
        // Auto-suggestions based on filename — shown when not actively searching
        if searchText.isEmpty {
            let suggestions = viewModel.autoSuggestionMovies.prefix(5)
            if viewModel.isLoadingAutoSuggestions {
                Section("Maybe:") {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding suggestions…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else if !suggestions.isEmpty {
                Section("Maybe:") {
                    ForEach(Array(suggestions)) { movie in
                        if let match = viewModel.libraryMovies.first(where: { $0.tmdbId == movie.tmdbId }) {
                            libraryMovieRow(match)
                        } else {
                            catalogMovieRow(movie)
                        }
                    }
                }
            }
        }

        // Search results — library matches shown inline alongside new items
        if viewModel.isSearchingCatalog {
            Section("Results") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else if !viewModel.catalogMovieResults.isEmpty {
            Section("Results") {
                ForEach(viewModel.catalogMovieResults) { movie in
                    if let match = viewModel.libraryMovies.first(where: { $0.tmdbId == movie.tmdbId }) {
                        libraryMovieRow(match)
                    } else {
                        catalogMovieRow(movie)
                    }
                }
            }
        }

        if !viewModel.isSearchingCatalog && viewModel.catalogMovieResults.isEmpty && (searchText.isEmpty ? viewModel.autoSuggestionMovies.isEmpty : true) {
            if searchText.isEmpty {
                ContentUnavailableView("Search to Identify", systemImage: "magnifyingglass", description: Text("Search for a movie to match this file."))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private var sonarrSections: some View {
        // Auto-suggestions based on filename — shown when not actively searching
        if searchText.isEmpty {
            let suggestions = viewModel.autoSuggestionSeries.prefix(5)
            if viewModel.isLoadingAutoSuggestions {
                Section("Maybe:") {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding suggestions…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else if !suggestions.isEmpty {
                Section("Maybe:") {
                    ForEach(Array(suggestions)) { s in
                        if let match = viewModel.librarySeries.first(where: { $0.tvdbId == s.tvdbId }) {
                            librarySeriesRow(match)
                        } else {
                            catalogSeriesRow(s)
                        }
                    }
                }
            }
        }

        // Search results — library matches shown inline alongside new items
        if viewModel.isSearchingCatalog {
            Section("Results") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else if !viewModel.catalogSeriesResults.isEmpty {
            Section("Results") {
                ForEach(viewModel.catalogSeriesResults) { s in
                    if let match = viewModel.librarySeries.first(where: { $0.tvdbId == s.tvdbId }) {
                        librarySeriesRow(match)
                    } else {
                        catalogSeriesRow(s)
                    }
                }
            }
        }

        if !viewModel.isSearchingCatalog && viewModel.catalogSeriesResults.isEmpty && (searchText.isEmpty ? viewModel.autoSuggestionSeries.isEmpty : true) {
            if searchText.isEmpty {
                ContentUnavailableView("Search to Identify", systemImage: "magnifyingglass", description: Text("Search for a series to match this file."))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func libraryMovieRow(_ movie: RadarrMovie) -> some View {
        let posterURL = posterURL(from: movie.images)
        return Button {
            viewModel.applyIdentification(to: target.items, mediaID: movie.id, title: movie.title, posterURL: posterURL)
            dismiss()
        } label: {
            mediaRow(title: movie.title, year: movie.year, posterURL: posterURL, badge: nil)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func catalogMovieRow(_ movie: RadarrMovie) -> some View {
        let posterURL = posterURL(from: movie.images)
        return Button {
            Task {
                let succeeded = await viewModel.addToLibraryAndIdentify(
                    blockedItems: target.items,
                    movie: movie,
                    importAfterAdding: importAfterAdding
                )
                if succeeded {
                    dismiss()
                }
            }
        } label: {
            mediaRow(title: movie.title, year: movie.year, posterURL: posterURL, badge: importAfterAdding ? "Add & Import" : "Add")
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func librarySeriesRow(_ s: SonarrSeries) -> some View {
        let posterURL = posterURL(from: s.images)
        return Button {
            viewModel.applyIdentification(to: target.items, mediaID: s.id, title: s.title, posterURL: posterURL)
            dismiss()
        } label: {
            mediaRow(title: s.title, year: s.year, posterURL: posterURL, badge: nil)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func catalogSeriesRow(_ s: SonarrSeries) -> some View {
        let posterURL = posterURL(from: s.images)
        return Button {
            Task {
                let succeeded = await viewModel.addToLibraryAndIdentify(
                    blockedItems: target.items,
                    series: s,
                    importAfterAdding: importAfterAdding
                )
                if succeeded {
                    dismiss()
                }
            }
        } label: {
            mediaRow(title: s.title, year: s.year, posterURL: posterURL, badge: importAfterAdding ? "Add & Import" : "Add")
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func mediaRow(title: String, year: Int?, posterURL: URL?, badge: String?) -> some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: posterURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct IdentifySheetPresentationModifier: ViewModifier {
    let isPresentedAsSheet: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPresentedAsSheet {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}
