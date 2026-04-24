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
        .listStyle(.insetGrouped)
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
                        .textInputAutocapitalization(.never)
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

    let path: String
    let service: ArrServiceType
    let serviceManager: ArrServiceManager
    let libraryItemID: Int?

    var isLoading = false
    var importableFiles: [ManualImportItem] = []
    var blockedFiles: [ManualImportItem] = []
    var selectedFiles: Set<String> = []
    var selectedBlockedFiles: Set<String> = []
    var navigationAction: (() -> Void)?

    // Identify sheet
    var identifyingItem: ManualImportItem?
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

    init(path: String, service: ArrServiceType, serviceManager: ArrServiceManager, libraryItemID: Int? = nil) {
        self.path = path
        self.service = service
        self.serviceManager = serviceManager
        self.libraryItemID = libraryItemID
    }

    var folderName: String {
        (path as NSString).lastPathComponent
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
        isLoading = true
        defer { isLoading = false }

        do {
            let jsonValues = try await getManualImport(folder: path)
            let scannedFiles = jsonValues.compactMap { ManualImportItem(json: $0) }
            importableFiles = scannedFiles.filter(\.isImportable)
            blockedFiles = scannedFiles.filter { !$0.isImportable }
            let availableIDs = Set(importableFiles.map(\.id))
            selectedFiles = selectedFiles.intersection(availableIDs)
            let blockedIDs = Set(blockedFiles.map(\.id))
            selectedBlockedFiles = selectedBlockedFiles.intersection(blockedIDs)
        } catch is CancellationError {
            importableFiles = []
            blockedFiles = []
            selectedBlockedFiles = []
        } catch {
            InAppNotificationCenter.shared.showError(title: "Scan Failed", message: error.localizedDescription)
            importableFiles = []
            blockedFiles = []
            selectedBlockedFiles = []
        }
    }

    @discardableResult
    func performImport() async -> Bool {
        let availableIDs = Set(importableFiles.map(\.id))
        selectedFiles = selectedFiles.intersection(availableIDs)

        guard !selectedFiles.isEmpty else { return false }
        isLoading = true
        defer { isLoading = false }

        let filesToImport = importableFiles.filter { selectedFiles.contains($0.id) }.map { $0.importJSON(service: service) }

        do {
            let count = filesToImport.count
            let importedIDs = selectedFiles
            let navAction = navigationAction
            let tabName = service == .sonarr ? "Series" : "Movies"
            let fileWord = count == 1 ? "file" : "files"

            let fileMeta = importableFiles.filter { importedIDs.contains($0.id) }
                .map { "\($0.fileName) mediaID:\($0.mediaID?.description ?? "nil")" }
            Self.logger.info("Sending \(count) \(fileWord) to \(self.service.displayName, privacy: .public): \(fileMeta, privacy: .private)")

            // Optimistically remove from list while command runs
            withAnimation(.snappy) {
                importableFiles.removeAll { importedIDs.contains($0.id) }
            }
            selectedFiles = []
            selectedBlockedFiles = []

            // Wait for the command to actually complete (polls up to 30s)
            let command = try await manualImport(files: filesToImport)
            Self.logger.info("Command finished — id:\(command.id ?? -1) status:\(command.status ?? "nil", privacy: .public) exception:\(command.exception ?? "none", privacy: .private)")

            // Check if command is still in progress (non-terminal)
            if !command.isTerminal {
                Self.logger.info("Command \(command.id ?? -1) is still running with status \(command.status ?? "unknown", privacy: .public)")
                InAppNotificationCenter.shared.showSuccess(
                    title: "Import In Progress",
                    message: "\(count) \(fileWord) submitted to \(service.displayName). Import is still running."
                )
                return false
            }

            if command.succeeded {
                // Items were already optimistically removed. Don't reload — rescanning the folder
                // will find the file again (hardlinks/copies leave the source in place) and undo
                // the removal, making it look like the import failed when it didn't.
                InAppNotificationCenter.shared.showSuccess(
                    title: "Imported",
                    message: "\(count) \(fileWord) imported by \(service.displayName).",
                    actionLabel: navAction != nil ? "View \(tabName)" : nil,
                    action: navAction
                )
                return true
            } else {
                let reason = manualImportFailureMessage(for: command)
                Self.logger.error("Command failed — \(reason, privacy: .private)")
                InAppNotificationCenter.shared.showError(title: "Import Failed", message: reason)
                await loadFiles()
                return false
            }
        } catch is CancellationError {
            Self.logger.info("Task cancelled")
            return false
        } catch {
            Self.logger.error("Threw error — \(error, privacy: .private)")
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
            await loadFiles()
            return false
        }
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
            return try await client.getManualImport(folder: folder, seriesId: libraryItemID)
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
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
        identifyingItem = item
        Task { await loadLibraryIfNeeded() }
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
        autoSuggestionMovies = []
        autoSuggestionSeries = []
        let term = extractTitleFromFilename(filename)
        guard !term.isEmpty else { return }
        do {
            switch service {
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                let results = try await client.lookupMovie(term: term)
                withAnimation(.snappy) { autoSuggestionMovies = results }
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                let results = try await client.lookupSeries(term: term)
                withAnimation(.snappy) { autoSuggestionSeries = results }
            case .prowlarr:
                break
            }
        } catch {
            // Silently fail — suggestions are best-effort
        }
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
        let identified = item.withIdentification(mediaID: mediaID, title: title, posterURL: posterURL)
        withAnimation(.snappy) {
            blockedFiles.removeAll { $0.id == item.id }
            selectedBlockedFiles.remove(item.id)
            importableFiles.append(identified)
            selectedFiles.insert(identified.id)
        }
        identifyingItem = nil
    }

    @discardableResult
    func addToLibraryAndIdentify(blockedItem: ManualImportItem, movie: RadarrMovie, importAfterAdding: Bool = true) async -> Bool {
        guard let client = serviceManager.radarrClient,
              let tmdbId = movie.tmdbId,
              let rootFolder = serviceManager.radarrRootFolders.first?.path,
              let qualityProfileId = qualityProfiles.first?.id else { return false }
        isAddingToLibrary = true
        defer { isAddingToLibrary = false }
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
            applyIdentification(to: blockedItem, mediaID: added.id, title: added.title, posterURL: posterURL(from: added.images))
            if importAfterAdding {
                await performImport()
            }
            return true
        } catch {
            InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func addToLibraryAndIdentify(blockedItem: ManualImportItem, series: SonarrSeries, importAfterAdding: Bool = true) async -> Bool {
        guard let client = serviceManager.sonarrClient,
              let tvdbId = series.tvdbId,
              let titleSlug = series.titleSlug,
              let rootFolder = serviceManager.sonarrRootFolders.first?.path,
              let qualityProfileId = qualityProfiles.first?.id else { return false }
        isAddingToLibrary = true
        defer { isAddingToLibrary = false }
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
            applyIdentification(to: blockedItem, mediaID: added.id, title: added.title, posterURL: posterURL(from: added.images))
            if importAfterAdding {
                await performImport()
            }
            return true
        } catch {
            InAppNotificationCenter.shared.showError(title: "Couldn't Add", message: error.localizedDescription)
            return false
        }
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

private func extractTitleFromFilename(_ filename: String) -> String {
    // Strip file extension
    var name = filename
    let knownExts = ["mkv", "mp4", "avi", "mov", "m4v", "wmv", "ts", "flac", "m2ts"]
    if let dot = name.range(of: ".", options: .backwards) {
        let ext = String(name[dot.upperBound...]).lowercased()
        if knownExts.contains(ext) { name = String(name[..<dot.lowerBound]) }
    }

    // Strip bracketed metadata groups, e.g. [BluRay-1080p], (2022)
    if let bracketRegex = try? NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)") {
        let range = NSRange(name.startIndex..., in: name)
        name = bracketRegex.stringByReplacingMatches(in: name, range: range, withTemplate: " ")
    }

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
        if token.range(of: #"^[Ss]\d{1,2}"#, options: .regularExpression) != nil { break }
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
    let showsCloseButton: Bool

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
            if viewModel.isLoading && viewModel.importableFiles.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Scanning for files…")
                        Spacer()
                    }
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
                if !viewModel.importableFiles.isEmpty {
                    Section {
                        ForEach(viewModel.importableFiles) { item in
                            ManualImportRow(
                                item: item,
                                isSelected: viewModel.selectedFiles.contains(item.id)
                            ) {
                                withAnimation(.snappy) {
                                    viewModel.toggleFile(item.id)
                                }
                            }
                        }
                    } header: {
                        Text("Importable Files")
                    }
                }

                if !viewModel.blockedFiles.isEmpty {
                    Section {
                        ForEach(viewModel.blockedFiles) { item in
                            ManualImportBlockedRow(
                                item: item,
                                isSelected: viewModel.selectedBlockedFiles.contains(item.id),
                                onToggle: {
                                    withAnimation(.snappy) {
                                        viewModel.toggleBlockedFile(item.id)
                                    }
                                }
                            )
                            .contextMenu {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    viewModel.beginIdentifying(item)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    viewModel.beginIdentifying(item)
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Blocked Files")
                    } footer: {
                        Text("Files flagged as dangerous or otherwise rejected by \(viewModel.service.displayName) can't be imported until the underlying issue is resolved.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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

            if !viewModel.importableFiles.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(viewModel.allSelected ? "Deselect" : "Select All") {
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
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Import")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isLoading || !viewModel.hasAnySelection)
                }
            }
        }
        .sheet(item: $viewModel.identifyingItem) { item in
            ManualImportIdentifySheet(
                item: item,
                viewModel: viewModel,
                importAfterAdding: true,
                showsCancelButton: true,
                wrapInNavigationStack: true
            )
        }
        .sheet(isPresented: $showBlockedSelectionReview) {
            ManualImportBlockedSelectionSheet(viewModel: viewModel)
        }
        .task {
            if !showsCloseButton {
                switch viewModel.service {
                case .sonarr: viewModel.navigationAction = navigateToSeriesTab
                case .radarr: viewModel.navigationAction = navigateToMoviesTab
                case .prowlarr: break
                }
            }
            if viewModel.importableFiles.isEmpty {
                await viewModel.loadFiles()
            }
        }
    }

    private var navigationSubtitleText: String {
        if viewModel.selectedFiles.isEmpty {
            if !viewModel.importableFiles.isEmpty && !viewModel.blockedFiles.isEmpty {
                return "\(viewModel.importableFiles.count) importable · \(viewModel.blockedFiles.count) blocked"
            }
            if !viewModel.blockedFiles.isEmpty && viewModel.importableFiles.isEmpty {
                return "\(viewModel.blockedFiles.count) blocked"
            }
            return viewModel.path
        } else {
            let count = viewModel.selectedFiles.count + viewModel.selectedBlockedFiles.count
            return "\(count) file\(count == 1 ? "" : "s") selected"
        }
    }
}

// MARK: - Models

private struct ManualImportEpisode {
    let number: Int
    let title: String
}

private struct ManualImportItem: Identifiable {
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

    /// The JSON to send in the ManualImport command.
    /// Always sets the flat `movieId`/`seriesId` field based on the service type, since
    /// Radarr/Sonarr's command handler reads the flat field and scan results often have it as 0.
    /// Also injects a minimal `movie`/`series` object when one is absent (user-identified files).
    func importJSON(service: ArrServiceType) -> JSONValue {
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

    init?(json: JSONValue) {
        guard case .object(let dict) = json else { return nil }

        if case .string(let p) = dict["path"] {
            self.path = p
            self.id = p
        } else {
            return nil
        }

        if case .string(let n) = dict["name"] {
            self.fileName = n
        } else if case .string(let fn) = dict["fileName"] {
            self.fileName = fn
        } else {
            self.fileName = (path as NSString).lastPathComponent
        }

        if case .number(let s) = dict["size"] {
            self.size = Int64(s)
        } else {
            self.size = 0
        }

        var parsedRejections = ManualImportItem.extractMessages(from: dict["rejections"])
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

        // If the media wasn't matched to a real library item, synthesize a rejection so the file
        // shows up in Blocked rather than being sent with id=0 and causing a server error.
        if (self.mediaID ?? 0) == 0 && parsedRejections.isEmpty {
            parsedRejections.append("Not matched to any item in your library. Add it to Sonarr/Radarr first.")
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
}

private struct ManualImportRow: View {
    let item: ManualImportItem
    let isSelected: Bool
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

                    Text(item.mediaTitle == nil ? item.path : item.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    statusChip(ByteFormatter.format(bytes: item.size), color: .secondary)

                    if let warning = item.warningMessages.first {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
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

                    Text(item.mediaTitle == nil ? item.path : item.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    statusChip(ByteFormatter.format(bytes: item.size), color: .secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
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

private struct ManualImportBlockedSelectionSheet: View {
    let viewModel: ManualImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingItem: ManualImportItem?

    private var blockedItems: [ManualImportItem] {
        viewModel.selectedBlockedItems
    }

    private var readyItems: [ManualImportItem] {
        viewModel.importableFiles.filter { viewModel.selectedFiles.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !readyItems.isEmpty {
                    Section {
                        ForEach(readyItems) { item in
                            ManualImportRow(item: item, isSelected: true) {}
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
                                isSelected: true,
                                onToggle: {}
                            )
                            .contextMenu {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    Task {
                                        await viewModel.loadLibraryIfNeeded()
                                        identifyingItem = item
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    Task {
                                        await viewModel.loadLibraryIfNeeded()
                                        identifyingItem = item
                                    }
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Identify Before Import")
                    } footer: {
                        Text("These selected files are still blocked. Identify each one to move it into the importable list.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review Selection")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.selectedFiles.isEmpty ? "Identify to Continue" : "Import \(readyItems.count)") {
                        dismiss()
                        Task {
                            await viewModel.performImport()
                        }
                    }
                    .disabled(viewModel.selectedFiles.isEmpty || viewModel.isLoading)
                }
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { identifyingItem != nil },
                    set: { if !$0 { identifyingItem = nil } }
                )
            ) {
                if let item = identifyingItem {
                    ManualImportIdentifySheet(
                        item: item,
                        viewModel: viewModel,
                        importAfterAdding: false,
                        showsCancelButton: false,
                        wrapInNavigationStack: false
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Identify Sheet

private struct ManualImportIdentifySheet: View {
    let item: ManualImportItem
    let viewModel: ManualImportScanViewModel
    let importAfterAdding: Bool
    let showsCancelButton: Bool
    let wrapInNavigationStack: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    private var libraryMovies: [RadarrMovie] {
        guard !searchText.isEmpty else { return viewModel.libraryMovies }
        return viewModel.libraryMovies.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var librarySeries: [SonarrSeries] {
        guard !searchText.isEmpty else { return viewModel.librarySeries }
        return viewModel.librarySeries.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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
            await viewModel.loadAutoSuggestions(for: item.fileName)
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
        .navigationTitle("Identify File")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library or Discover")
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
                Text(item.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if viewModel.service == .radarr {
                radarrSections
            } else {
                sonarrSections
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var radarrSections: some View {
        // Auto-suggestions based on filename — shown when not actively searching
        if searchText.isEmpty {
            let suggestions = viewModel.autoSuggestionMovies.prefix(5)
            if !suggestions.isEmpty {
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

        // Library matches
        if !libraryMovies.isEmpty {
            Section("In Your Library") {
                ForEach(libraryMovies) { movie in
                    libraryMovieRow(movie)
                }
            }
        }

        // Catalog search results
        if viewModel.isSearchingCatalog {
            Section("Discover") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else if !viewModel.catalogMovieResults.isEmpty {
            let newMovies = viewModel.catalogMovieResults.filter { r in
                !viewModel.libraryMovies.contains(where: { $0.tmdbId == r.tmdbId })
            }
            if !newMovies.isEmpty {
                Section("Discover") {
                    ForEach(newMovies) { movie in
                        catalogMovieRow(movie)
                    }
                }
            }
        }

        if libraryMovies.isEmpty && !viewModel.isSearchingCatalog && viewModel.catalogMovieResults.isEmpty && (searchText.isEmpty ? viewModel.autoSuggestionMovies.isEmpty : true) {
            if searchText.isEmpty {
                ContentUnavailableView("No Movies in Library", systemImage: "film", description: Text("Search to find and add a movie via Discover."))
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
            if !suggestions.isEmpty {
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

        if !librarySeries.isEmpty {
            Section("In Your Library") {
                ForEach(librarySeries) { s in
                    librarySeriesRow(s)
                }
            }
        }

        if viewModel.isSearchingCatalog {
            Section("Discover") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else if !viewModel.catalogSeriesResults.isEmpty {
            let newSeries = viewModel.catalogSeriesResults.filter { r in
                !viewModel.librarySeries.contains(where: { $0.tvdbId == r.tvdbId })
            }
            if !newSeries.isEmpty {
                Section("Discover") {
                    ForEach(newSeries) { s in
                        catalogSeriesRow(s)
                    }
                }
            }
        }

        if librarySeries.isEmpty && !viewModel.isSearchingCatalog && viewModel.catalogSeriesResults.isEmpty && (searchText.isEmpty ? viewModel.autoSuggestionSeries.isEmpty : true) {
            if searchText.isEmpty {
                ContentUnavailableView("No Series in Library", systemImage: "tv", description: Text("Search to find and add a series via Discover."))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func libraryMovieRow(_ movie: RadarrMovie) -> some View {
        let posterURL = posterURL(from: movie.images)
        return Button {
            viewModel.applyIdentification(to: item, mediaID: movie.id, title: movie.title, posterURL: posterURL)
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
                    blockedItem: item,
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
            viewModel.applyIdentification(to: item, mediaID: s.id, title: s.title, posterURL: posterURL)
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
                    blockedItem: item,
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
