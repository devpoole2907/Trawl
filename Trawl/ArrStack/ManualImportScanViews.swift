import SwiftUI

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

                if !viewModel.groupedIdentifiedPendingAddFiles.isEmpty {
                    Section {
                        ForEach(viewModel.groupedIdentifiedPendingAddFiles) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: .pendingAdd,
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
                                Button("Add to \(viewModel.service.displayName)", systemImage: "plus.circle") {
                                    viewModel.beginIdentifying(group: group)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Add", systemImage: "plus.circle") {
                                    viewModel.beginIdentifying(group: group)
                                }
                                .tint(.green)
                            }
                        }
                    } header: {
                        Text("Identified")
                    } footer: {
                        Text("These files matched a \(viewModel.service.displayName) result. Add the title to \(viewModel.service.displayName) to make it ready to import.")
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
                        showBlockedSelectionReview = true
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
                importAfterAdding: false,
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
                case .prowlarr, .bazarr: break
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
        if !viewModel.groupedIdentifiedPendingAddFiles.isEmpty {
            let titles = viewModel.groupedIdentifiedPendingAddFiles.count
            parts.append("\(titles) identified")
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
        AppSheetShell(
            title: "Resolve Import Issue",
            cancelTitle: "Close",
            confirmTitle: readyItems.count == 1 ? "Import" : "Import \(readyItems.count)",
            isConfirmDisabled: readyItems.isEmpty || viewModel.isBusy,
            isConfirmLoading: viewModel.isImporting,
            onConfirm: {
                let items = readyItems
                Task {
                    let succeeded = await viewModel.importItems(items)
                    if succeeded {
                        await onImportCompleted()
                        dismiss()
                    }
                }
            },
            detents: [.large],
            dragIndicator: .visible
        ) {
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
            .refreshable {
                await viewModel.loadFiles()
            }
            .task {
                if !viewModel.hasPerformedInitialScan {
                    await viewModel.loadFiles()
                }
            }
        }
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

struct ManualImportEpisode: Sendable {
    let number: Int
    let title: String
}

struct ManualImportItem: Identifiable, Sendable {
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
    let catalogID: Int?
    let posterURL: URL?
    let seasonNumber: Int?
    let episodes: [ManualImportEpisode]
    let qualityName: String?

    /// A file is only importable if it has no rejections AND is matched to a real library item (non-zero ID).
    /// Files with id == 0 or no media match would cause "Movie/Series with id 0 does not exist" on import.
    var isImportable: Bool {
        rejectionReasons.isEmpty && (mediaID ?? 0) > 0
    }

    var isIdentifiedPendingAdd: Bool {
        !isImportable
            && rejectionReasons.isEmpty
            && mediaID == nil
            && mediaTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
        case .prowlarr, .bazarr:
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
            catalogID: self.catalogID,
            posterURL: posterURL,
            seasonNumber: self.seasonNumber,
            episodes: self.episodes,
            qualityName: self.qualityName
        )
    }

    func withPendingAddIdentification(title: String, catalogID: Int?, posterURL: URL?) -> ManualImportItem {
        ManualImportItem(
            id: self.id,
            path: self.path,
            fileName: self.fileName,
            size: self.size,
            rejectionReasons: [],
            warningMessages: self.warningMessages,
            originalJSON: self.originalJSON,
            mediaTitle: title,
            mediaID: nil,
            catalogID: catalogID ?? self.catalogID,
            posterURL: posterURL,
            seasonNumber: self.seasonNumber,
            episodes: self.episodes,
            qualityName: self.qualityName
        )
    }

    private init(
        id: String, path: String, fileName: String, size: Int64,
        rejectionReasons: [String], warningMessages: [String], originalJSON: JSONValue,
        mediaTitle: String?, mediaID: Int?, catalogID: Int?, posterURL: URL?,
        seasonNumber: Int?, episodes: [ManualImportEpisode], qualityName: String?
    ) {
        self.id = id; self.path = path; self.fileName = fileName; self.size = size
        self.rejectionReasons = rejectionReasons; self.warningMessages = warningMessages
        self.originalJSON = originalJSON; self.mediaTitle = mediaTitle; self.mediaID = mediaID
        self.catalogID = catalogID; self.posterURL = posterURL; self.seasonNumber = seasonNumber; self.episodes = episodes
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

        // Extract identified media from series or movie object, falling back to flat IDs.
        let mediaDict: [String: JSONValue]?
        if case .object(let s) = dict["series"] { mediaDict = s }
        else if case .object(let m) = dict["movie"] { mediaDict = m }
        else { mediaDict = nil }

        if let mediaDict {
            if case .string(let t) = mediaDict["title"] { self.mediaTitle = t } else { self.mediaTitle = nil }
            if let id = Self.intValue(from: mediaDict["id"]) { self.mediaID = id } else { self.mediaID = nil }
            self.catalogID = Self.intValue(from: mediaDict["tvdbId"]) ?? Self.intValue(from: mediaDict["tmdbId"])
            self.posterURL = ManualImportItem.extractPosterURL(from: mediaDict["images"])
        } else {
            self.mediaTitle = nil
            self.mediaID = Self.intValue(from: dict["seriesId"]) ?? Self.intValue(from: dict["movieId"])
            self.catalogID = Self.intValue(from: dict["tvdbId"]) ?? Self.intValue(from: dict["tmdbId"])
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

    nonisolated static func intValue(from value: JSONValue?) -> Int? {
        switch value {
        case .number(let number):
            let intValue = Int(number)
            return intValue > 0 ? intValue : nil
        case .string(let string):
            guard let intValue = Int(string), intValue > 0 else { return nil }
            return intValue
        case .bool, .array, .object, .null, nil:
            return nil
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

enum GroupSelectionState { case none, partial, all }

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
struct ManualImportIdentifyTarget: Identifiable, Sendable {
    let id: String
    let items: [ManualImportItem]
    let displayLabel: String
}

struct ManualImportGroup: Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case identified(mediaID: Int)
        case pendingAdd(inferredKey: String)
        case unidentified(inferredKey: String)
    }

    let kind: Kind
    let displayTitle: String
    let posterURL: URL?
    let items: [ManualImportItem]

    var id: String {
        switch kind {
        case .identified(let id): return "id-\(id)"
        case .pendingAdd(let key): return "add-\(key)"
        case .unidentified(let key): return "un-\(key)"
        }
    }

    var mediaID: Int? {
        if case .identified(let id) = kind { return id }
        return nil
    }

    var inferredKey: String? {
        if case .pendingAdd(let key) = kind { return key }
        if case .unidentified(let key) = kind { return key }
        return nil
    }

    var isIdentified: Bool {
        if case .identified = kind { return true }
        return false
    }

    var isPendingAdd: Bool {
        if case .pendingAdd = kind { return true }
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
    case pendingAdd
    case unidentified
    case blocked

    var placeholderIcon: String {
        switch self {
        case .ready: return "photo"
        case .pendingAdd: return "plus.circle"
        case .unidentified: return "questionmark.circle"
        case .blocked: return "xmark.octagon"
        }
    }

    var accentColor: Color {
        switch self {
        case .ready: return .secondary
        case .pendingAdd: return .green
        case .unidentified: return .orange
        case .blocked: return .red
        }
    }

    var badge: (text: String, color: Color)? {
        switch self {
        case .ready: return nil
        case .pendingAdd: return nil
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

struct ManualImportGroupSheet: View {
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
        AppSheetShell(
            title: initialGroup.displayTitle,
            cancelTitle: "Close",
            confirmTitle: currentItems.count == 1 ? "Import" : "Import All",
            isConfirmDisabled: currentItems.isEmpty,
            isConfirmLoading: viewModel.isImporting,
            onConfirm: {
                let items = currentItems
                dismiss()
                Task { await viewModel.importItems(items) }
            },
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
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
    }
}

private struct ManualImportBlockedSelectionSheet: View {
    let viewModel: ManualImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: ManualImportIdentifyTarget?

    private var readyGroups: [ManualImportGroup] {
        viewModel.selectedReadyGroups
    }

    private var pendingAddGroups: [ManualImportGroup] {
        viewModel.selectedBlockedGroups.filter(\.isPendingAdd)
    }

    private var unresolvedGroups: [ManualImportGroup] {
        viewModel.selectedBlockedGroups.filter { !$0.isPendingAdd }
    }

    private var allReadyGroups: [ManualImportGroup] {
        readyGroups + pendingAddGroups
    }

    private var hasUnresolved: Bool {
        !unresolvedGroups.isEmpty
    }

    private func identifyTarget(for group: ManualImportGroup) -> ManualImportIdentifyTarget {
        let label = group.items.count == 1 ? group.items[0].fileName : "\(group.displayTitle) · \(group.items.count) files"
        return ManualImportIdentifyTarget(id: group.id, items: group.items, displayLabel: label)
    }

    private var confirmCount: Int {
        viewModel.selectedFiles.count + pendingAddGroups.reduce(0) { $0 + $1.items.count }
    }

    private var confirmButtonTitle: String {
        hasUnresolved ? "Resolve \(unresolvedGroups.reduce(0) { $0 + $1.items.count })" : "Import \(confirmCount)"
    }

    private var isConfirmDisabled: Bool {
        hasUnresolved || (viewModel.selectedFiles.isEmpty && pendingAddGroups.isEmpty) || viewModel.isBusy
    }

    var body: some View {
        AppSheetShell(
            title: "Review Selection",
            cancelTitle: "Close",
            confirmTitle: confirmButtonTitle,
            isConfirmDisabled: isConfirmDisabled,
            onConfirm: {
                dismiss()
                Task { await viewModel.performImport() }
            },
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            List {
                if !allReadyGroups.isEmpty {
                    Section {
                        ForEach(readyGroups) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: .ready,
                                selectionState: .none,
                                isSelectingMode: false,
                                onToggle: {}
                            )
                        }

                        ForEach(pendingAddGroups) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: .pendingAdd,
                                selectionState: .none,
                                isSelectingMode: false,
                                onToggle: { identifyingTarget = identifyTarget(for: group) }
                            )
                            .contextMenu {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: group)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: group)
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        Text("Ready to Import")
                    } footer: {
                        if !pendingAddGroups.isEmpty {
                            Text("These items will be added to \(viewModel.service.displayName) and imported together when you tap Import.")
                        }
                    }
                }

                if unresolvedGroups.isEmpty && !pendingAddGroups.isEmpty && readyGroups.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Ready to Import",
                            systemImage: "checkmark.circle.fill",
                            description: Text("These items will be added to \(viewModel.service.displayName) when you tap Import.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else if unresolvedGroups.isEmpty && allReadyGroups.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Files Selected",
                            systemImage: "checkmark.circle",
                            description: Text("Everything in this selection has been cleared.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else if !unresolvedGroups.isEmpty {
                    Section {
                        ForEach(unresolvedGroups) { group in
                            ManualImportGroupRow(
                                group: group,
                                style: group.isIdentified ? .blocked : .unidentified,
                                selectionState: .none,
                                isSelectingMode: false,
                                onToggle: { identifyingTarget = identifyTarget(for: group) }
                            )
                            .contextMenu {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: group)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") {
                                    identifyingTarget = identifyTarget(for: group)
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
        AppSheetShell(
            title: group.displayTitle,
            cancelTitle: "Close",
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
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
        let posterImageURL = posterURL(from: movie.images)
        return Button {
            viewModel.applyIdentification(to: target.items, mediaID: movie.id, title: movie.title, posterURL: posterImageURL)
            dismiss()
        } label: {
            mediaRow(title: movie.title, year: movie.year, posterURL: posterImageURL, badge: nil)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func catalogMovieRow(_ movie: RadarrMovie) -> some View {
        let posterImageURL = posterURL(from: movie.images)
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
            mediaRow(title: movie.title, year: movie.year, posterURL: posterImageURL, badge: importAfterAdding ? "Add & Import" : "Add")
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func librarySeriesRow(_ s: SonarrSeries) -> some View {
        let posterImageURL = posterURL(from: s.images)
        return Button {
            viewModel.applyIdentification(to: target.items, mediaID: s.id, title: s.title, posterURL: posterImageURL)
            dismiss()
        } label: {
            mediaRow(title: s.title, year: s.year, posterURL: posterImageURL, badge: nil)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func catalogSeriesRow(_ s: SonarrSeries) -> some View {
        let posterImageURL = posterURL(from: s.images)
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
            mediaRow(title: s.title, year: s.year, posterURL: posterImageURL, badge: importAfterAdding ? "Add & Import" : "Add")
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
