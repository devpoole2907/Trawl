import SwiftUI

// MARK: - Tab

enum LibraryImportScanTab: Hashable, CaseIterable {
    case all, new, inLibrary

    var displayName: String {
        switch self {
        case .new: return "New"
        case .inLibrary: return "Owned"
        case .all: return "All"
        }
    }

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(displayName, value: self)
    }
}

// MARK: - Scan View

struct LibraryImportScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateToSeriesTab) private var navigateToSeriesTab
    @Environment(\.navigateToMoviesTab) private var navigateToMoviesTab
    @State private var viewModel: LibraryImportScanViewModel
    @State private var showSelectionReview = false
    @State private var isSelectingMode = false
    @State private var reviewingGroup: LibraryImportGroup?
    @State private var reviewingBlockedGroup: LibraryImportGroup?
    @State private var selectedTab: LibraryImportScanTab = .new
    @State private var searchText = ""
    @State private var readyExpanded = true
    @State private var pendingAddExpanded = true
    @State private var needsIDExpanded = true
    @State private var blockedExpanded = false
    @State private var inLibraryExpanded = true
    @State private var importedExpanded = false
    @ScaledMetric(relativeTo: .subheadline) private var autoIdentifyStatusRowHeight: CGFloat = 50
    let showsCloseButton: Bool

    // MARK: Filtered groups

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var readyGroups: [LibraryImportGroup] {
        // Always the "new" (not-in-library) importable set. In-library files have
        // their own section, so sourcing from groupedImportableFiles here listed
        // them twice under the All tab (and while searching).
        searchFiltered(viewModel.groupedNewImportableFiles)
    }

    private var pendingAddGroups: [LibraryImportGroup] { searchFiltered(viewModel.groupedIdentifiedPendingAddFiles) }
    private var needsIDGroups: [LibraryImportGroup] { searchFiltered(viewModel.groupedUnidentifiedFiles) }
    private var blockedGroups: [LibraryImportGroup] { searchFiltered(viewModel.groupedBlockedFiles) }
    private var inLibraryGroups: [LibraryImportGroup] { searchFiltered(viewModel.groupedInLibraryFiles) }

    private var ownedImportedTitles: [OwnedLibraryTitle] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.ownedTitlesInFolder }
        return viewModel.ownedTitlesInFolder.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func searchFiltered(_ groups: [LibraryImportGroup]) -> [LibraryImportGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.items.contains { $0.fileName.localizedCaseInsensitiveContains(query) }
        }
    }

    private var hasAnyContent: Bool { !viewModel.importableFiles.isEmpty || !viewModel.blockedFiles.isEmpty }

    private func groupSelectionState(_ group: LibraryImportGroup) -> GroupSelectionState {
        let n = group.items.filter { viewModel.selectedFiles.contains($0.id) }.count
        if n == 0 { return .none }
        return n == group.items.count ? .all : .partial
    }

    private func blockedGroupSelectionState(_ group: LibraryImportGroup) -> GroupSelectionState {
        let n = group.items.filter { viewModel.selectedBlockedFiles.contains($0.id) }.count
        if n == 0 { return .none }
        return n == group.items.count ? .all : .partial
    }

    // MARK: Auto-identify text

    private var autoIdentifyStatusText: String {
        if let current = viewModel.autoIdentifyCurrentFileName, viewModel.isAutoIdentifying {
            return "Matching \(current)"
        }
        if let outcome = viewModel.autoIdentifyLastOutcomeMessage { return outcome }
        if let last = viewModel.autoIdentifyLastMatchedTitle { return "Last match: \(last)" }
        let count = viewModel.unresolvedUnidentifiedCount
        return count == 1 ? "1 file waiting for automatic matching." : "\(count) files waiting for automatic matching."
    }

    private var autoIdentifyProgressText: String {
        let processed = viewModel.autoIdentifyProcessedCount
        if viewModel.isAutoIdentifying { return processed == 0 ? "Running" : "Matched \(processed)" }
        return processed > 0 ? "Matched \(processed)" : "Idle"
    }

    init(
        path: String,
        service: ArrServiceType,
        serviceManager: ArrServiceManager,
        libraryItemID: Int? = nil,
        showsCloseButton: Bool = false,
        kind: ArrImportKind = .library
    ) {
        _viewModel = State(wrappedValue: LibraryImportScanViewModel(path: path, service: service, serviceManager: serviceManager, libraryItemID: libraryItemID, kind: kind))
        self.showsCloseButton = showsCloseButton
    }

    // MARK: Import mode (manual import only)

    @ViewBuilder
    private var importModeSection: some View {
        Section {
            Picker("Import Mode", selection: Binding(
                get: { viewModel.importMode },
                set: { viewModel.importMode = $0 }
            )) {
                ForEach(ArrImportMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Move relocates each file into your library. Copy leaves the original in place (hardlinked when your server is set up for it).")
        }
    }

    // MARK: Body

    var body: some View {
        List {
            statusSection

            if viewModel.importKind == .manual {
                importModeSection
            }

            if hasActiveSearch || selectedTab != .inLibrary {
                readySection
                pendingAddSection
                needsIDSection
                blockedSection
            }

            if hasActiveSearch || selectedTab == .all || selectedTab == .inLibrary {
                inLibrarySection
            }

            if hasActiveSearch || selectedTab == .inLibrary {
                ownedImportedSection
            }

            if !viewModel.isScanning && !hasAnyContent && viewModel.hasPerformedInitialScan {
                Section {
                    ContentUnavailableView(
                        "No Importable Files",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("No unmapped files found in this directory.")
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #else
        .listStyle(.inset)
        #endif
        .animation(.snappy, value: viewModel.hasPerformedInitialScan)
        .animation(.snappy, value: viewModel.isAutoIdentifying)
        .animation(.snappy, value: viewModel.isImporting)
        .animation(.snappy, value: readyGroups.count)
        .animation(.snappy, value: pendingAddGroups.count)
        .animation(.snappy, value: needsIDGroups.count)
        .animation(.snappy, value: blockedGroups.count)
        .animation(.snappy, value: inLibraryGroups.count)
        .animation(.snappy, value: ownedImportedTitles.count)
        .moreDestinationBackground(.libraryImport)
        .navigationTitle(viewModel.folderName)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable {
            await viewModel.loadFiles()
            await viewModel.loadLibraryIfNeeded()
            viewModel.relinkIdentifiedItemsToLibrary()
            await viewModel.loadInLibraryStatus()
        }
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "View",
                selection: $selectedTab,
                items: LibraryImportScanTab.allCases.map(\.segmentBarItem),
                searchText: $searchText,
                searchHint: "Search files…",
                searchPlacement: .leading,
                alignment: .leading
            )
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }

            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                if isSelectingMode {
                    Button(viewModel.allSelected ? "Deselect All" : "Select All") {
                        withAnimation(.snappy) { viewModel.toggleSelectAll() }
                    }
                    .font(.subheadline)

                    Button {
                        showSelectionReview = true
                    } label: {
                        Text("Import").fontWeight(.semibold)
                    }
                    // Intentionally not gated on `isImporting`: a manual import is
                    // POSTed to the *arr server immediately and runs server-side, so
                    // the user can queue another batch while one is in flight (matches
                    // the per-title / group "Add & Import" paths). Only block mid-scan.
                    .disabled(viewModel.isScanning || !viewModel.hasAnySelection)
                }

                if hasAnyContent {
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
            LibraryImportIdentifySheet(target: target, viewModel: viewModel, importAfterAdding: false, showsCancelButton: true, wrapInNavigationStack: true)
        }
        .sheet(isPresented: $showSelectionReview) {
            LibraryImportSelectionReviewSheet(viewModel: viewModel)
        }
        .sheet(item: $reviewingGroup) { group in
            LibraryImportGroupSheet(initialGroup: group, viewModel: viewModel)
        }
        .sheet(item: $reviewingBlockedGroup) { group in
            LibraryImportBlockedGroupSheet(group: group, viewModel: viewModel)
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
            await viewModel.loadLibraryIfNeeded()
            viewModel.relinkIdentifiedItemsToLibrary()
            await viewModel.loadInLibraryStatus()
            if !viewModel.userPausedAutoIdentify {
                viewModel.startAutoIdentify()
            }
        }
        .onDisappear {
            viewModel.stopAutoIdentify()
        }
    }

    // MARK: Status Section

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if viewModel.isScanning && !viewModel.hasPerformedInitialScan {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning for files…")
                            .font(.subheadline.weight(.medium))
                        Text(viewModel.scanStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if viewModel.isScanTakingLong {
                            Text("Taking longer than usual…")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeIn, value: viewModel.isScanTakingLong)
                }
                .padding(.vertical, 2)
            } else if viewModel.hasPerformedInitialScan {
                countChipsRow
            } else if let errorMessage = viewModel.scanError {
                ContentUnavailableView {
                    Label(
                        viewModel.scanFolderMissing ? "No Files to Import" : "Scan Failed",
                        systemImage: viewModel.scanFolderMissing ? "folder.badge.questionmark" : "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await viewModel.loadFiles() } }
                        .buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)
            }

            if viewModel.isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Importing…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.hasPerformedInitialScan || viewModel.isScanning {
                HStack(spacing: 8) {
                    if viewModel.isAutoIdentifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: viewModel.unresolvedUnidentifiedCount == 0 ? "checkmark.circle.fill" : "sparkle.magnifyingglass")
                            .foregroundStyle(viewModel.unresolvedUnidentifiedCount == 0 ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(autoIdentifyProgressText)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(autoIdentifyStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(viewModel.isAutoIdentifying ? "Stop" : "Auto Match") {
                        if viewModel.isAutoIdentifying {
                            viewModel.stopAutoIdentify(userInitiated: true)
                        } else {
                            viewModel.startAutoIdentify()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(viewModel.groupedUnidentifiedFiles.isEmpty && !viewModel.isAutoIdentifying)
                }
                .frame(height: autoIdentifyStatusRowHeight)
                .padding(.vertical, 2)
            }
        } footer: {
            if viewModel.hasPerformedInitialScan {
                Text("These are untracked files found in this folder — extra copies, samples, and anything \(viewModel.service.displayName) hasn't imported yet. Files already in your library are listed under the Owned tab.")
            }
        }
    }

    private var countChipsRow: some View {
        let newCount = viewModel.groupedNewImportableFiles.reduce(0) { $0 + $1.items.count }
        let pendingCount = viewModel.groupedIdentifiedPendingAddFiles.reduce(0) { $0 + $1.items.count }
        let needsIDCount = viewModel.groupedUnidentifiedFiles.reduce(0) { $0 + $1.items.count }
        let blockedCount = viewModel.groupedBlockedFiles.reduce(0) { $0 + $1.items.count }
        let inLibraryCount = viewModel.groupedInLibraryFiles.reduce(0) { $0 + $1.items.count }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statusChip("\(newCount) ready", color: newCount > 0 ? .green : .secondary)
                if pendingCount > 0 { statusChip("\(pendingCount) identified", color: .blue) }
                if needsIDCount > 0 { statusChip("\(needsIDCount) to identify", color: .orange) }
                if blockedCount > 0 { statusChip("\(blockedCount) blocked", color: .red) }
                if inLibraryCount > 0 { statusChip("\(inLibraryCount) extra", color: .secondary) }
            }
        }
    }

    // MARK: Content Sections

    @ViewBuilder
    private var readySection: some View {
        if !readyGroups.isEmpty {
            Section(isExpanded: $readyExpanded) {
                if viewModel.service == .sonarr {
                    Toggle(isOn: Binding(get: { viewModel.seasonFolder }, set: { viewModel.seasonFolder = $0 })) {
                        Label("Season Folder", systemImage: "folder.badge.plus")
                    }
                }
                ForEach(readyGroups) { group in
                    LibraryImportGroupRow(
                        group: group, style: .ready,
                        selectionState: groupSelectionState(group),
                        isSelectingMode: isSelectingMode,
                        onToggle: {
                            if isSelectingMode {
                                withAnimation(.snappy) { viewModel.toggleGroup(itemIDs: group.items.map(\.id)) }
                            } else { reviewingGroup = group }
                        }
                    )
                    .contextMenu { Button("Review", systemImage: "list.bullet.rectangle") { reviewingGroup = group } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { reviewingGroup = group } label: { Label("Review", systemImage: "list.bullet.rectangle") }.tint(.blue)
                    }
                }
            } header: {
                Text("Ready to Import (\(readyGroups.count))")
            }
        }
    }

    @ViewBuilder
    private var pendingAddSection: some View {
        if !pendingAddGroups.isEmpty {
            Section(isExpanded: $pendingAddExpanded) {
                ForEach(pendingAddGroups) { group in
                    LibraryImportGroupRow(
                        group: group, style: .pendingAdd,
                        selectionState: blockedGroupSelectionState(group),
                        isSelectingMode: isSelectingMode,
                        onToggle: {
                            if isSelectingMode {
                                withAnimation(.snappy) { viewModel.toggleBlockedGroup(itemIDs: group.items.map(\.id)) }
                            } else { viewModel.beginIdentifying(group: group) }
                        }
                    )
                    .contextMenu { Button("Add to \(viewModel.service.displayName)", systemImage: "plus.circle") { viewModel.beginIdentifying(group: group) } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Add", systemImage: "plus.circle") { viewModel.beginIdentifying(group: group) }.tint(.green)
                    }
                }
            } header: {
                Text("Identified (\(pendingAddGroups.count))")
            }
        }
    }

    @ViewBuilder
    private var needsIDSection: some View {
        if !needsIDGroups.isEmpty {
            Section(isExpanded: $needsIDExpanded) {
                ForEach(needsIDGroups) { group in
                    LibraryImportGroupRow(
                        group: group, style: .unidentified,
                        selectionState: blockedGroupSelectionState(group),
                        isSelectingMode: isSelectingMode,
                        onToggle: {
                            if isSelectingMode {
                                withAnimation(.snappy) { viewModel.toggleBlockedGroup(itemIDs: group.items.map(\.id)) }
                            } else { viewModel.beginIdentifying(group: group) }
                        }
                    )
                    .contextMenu { Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { viewModel.beginIdentifying(group: group) } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { viewModel.beginIdentifying(group: group) }.tint(.blue)
                    }
                }
            } header: {
                Text("Needs Identification (\(needsIDGroups.count))")
            }
        }
    }

    @ViewBuilder
    private var blockedSection: some View {
        if !blockedGroups.isEmpty {
            Section {
                if blockedExpanded {
                    ForEach(blockedGroups) { group in
                        LibraryImportGroupRow(
                            group: group, style: .blocked,
                            selectionState: blockedGroupSelectionState(group),
                            isSelectingMode: isSelectingMode,
                            onToggle: {
                                if isSelectingMode {
                                    withAnimation(.snappy) { viewModel.toggleBlockedGroup(itemIDs: group.items.map(\.id)) }
                                } else { reviewingBlockedGroup = group }
                            }
                        )
                        .contextMenu {
                            Button("Review", systemImage: "list.bullet.rectangle") { reviewingBlockedGroup = group }
                            if !group.isIdentified {
                                Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { viewModel.beginIdentifying(group: group) }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { reviewingBlockedGroup = group } label: { Label("Review", systemImage: "list.bullet.rectangle") }.tint(.blue)
                        }
                    }
                }
            } header: {
                Button {
                    withAnimation(.snappy) { blockedExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Blocked (\(blockedGroups.count))")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(blockedExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-import-blocked-disclosure")
                .accessibilityValue(blockedExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(blockedExpanded ? "Collapses blocked files" : "Expands blocked files")
            }
        }
    }

    @ViewBuilder
    private var inLibrarySection: some View {
        if !inLibraryGroups.isEmpty {
            Section(isExpanded: $inLibraryExpanded) {
                Text("Untracked files for movies you already own — import only to replace or upgrade the existing file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(inLibraryGroups) { group in
                    LibraryImportGroupRow(
                        group: group, style: .ready,
                        selectionState: groupSelectionState(group),
                        isSelectingMode: isSelectingMode,
                        onToggle: {
                            if isSelectingMode {
                                withAnimation(.snappy) { viewModel.toggleGroup(itemIDs: group.items.map(\.id)) }
                            } else { reviewingGroup = group }
                        }
                    )
                    .contextMenu { Button("Review", systemImage: "list.bullet.rectangle") { reviewingGroup = group } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { reviewingGroup = group } label: { Label("Review", systemImage: "list.bullet.rectangle") }.tint(.blue)
                    }
                    .opacity(0.65)
                }
            } header: {
                Text("Extra Copies (\(inLibraryGroups.count))")
            }
        }
    }

    @ViewBuilder
    private var ownedImportedSection: some View {
        if !ownedImportedTitles.isEmpty {
            Section(isExpanded: $importedExpanded) {
                Text("Already imported into \(viewModel.service.displayName) from this folder. Nothing to do here — shown so you can see what's already handled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ownedImportedTitles) { title in
                    OwnedImportedRow(title: title)
                }
            } header: {
                Text("In Library (\(ownedImportedTitles.count))")
            }
        }
    }
}

private struct OwnedImportedRow: View {
    let title: OwnedLibraryTitle

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: title.posterURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "film")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 46, height: 69)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(title.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let year = title.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Label("Imported", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .font(.title3)
        }
        .padding(.vertical, 4)
        .opacity(0.75)
    }
}

struct ArrQueueImportIssueResolutionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: LibraryImportScanViewModel
    @State private var readyExpanded = true
    @State private var needsIDExpanded = true
    @State private var blockedExpanded = false

    let resolution: ArrQueueImportIssueResolution
    let onImportCompleted: () async -> Void

    private var readyItems: [LibraryImportItem] {
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
        _viewModel = State(wrappedValue: LibraryImportScanViewModel(
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
            isConfirmDisabled: readyItems.isEmpty || viewModel.isScanning,
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
                    Section(isExpanded: $readyExpanded) {
                        ForEach(readyItems) { item in
                            NavigationLink {
                                LibraryImportIdentifySheet(
                                    target: identifyTarget(for: item),
                                    viewModel: viewModel,
                                    importAfterAdding: false,
                                    showsCancelButton: false,
                                    wrapInNavigationStack: false
                                )
                            } label: {
                                LibraryImportRow(item: item, isSelected: false, isSelectingMode: false, onToggle: {})
                            }
                        }
                    } header: {
                        Text("Ready to Import (\(readyItems.count))")
                    }
                }

                if !viewModel.groupedUnidentifiedFiles.isEmpty {
                    Section(isExpanded: $needsIDExpanded) {
                        ForEach(viewModel.groupedUnidentifiedFiles) { group in
                            NavigationLink {
                                LibraryImportIdentifySheet(
                                    target: identifyTarget(for: group),
                                    viewModel: viewModel,
                                    importAfterAdding: false,
                                    showsCancelButton: false,
                                    wrapInNavigationStack: false
                                )
                            } label: {
                                LibraryImportGroupRow(group: group, style: .unidentified, selectionState: .none, isSelectingMode: false, onToggle: {})
                            }
                        }
                    } header: {
                        Text("Needs Identification (\(viewModel.groupedUnidentifiedFiles.count))")
                    }
                }

                if !viewModel.groupedBlockedFiles.isEmpty {
                    Section(isExpanded: $blockedExpanded) {
                        ForEach(viewModel.groupedBlockedFiles) { group in
                            NavigationLink {
                                LibraryImportBlockedGroupInlineView(group: group, viewModel: viewModel)
                            } label: {
                                LibraryImportGroupRow(group: group, style: .blocked, selectionState: .none, isSelectingMode: false, onToggle: {})
                            }
                        }
                    } header: {
                        Text("Still Blocked (\(viewModel.groupedBlockedFiles.count))")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .animation(.snappy, value: hasScannedFiles)
            .animation(.snappy, value: viewModel.isScanning)
            .animation(.snappy, value: readyItems.count)
            .animation(.snappy, value: viewModel.groupedUnidentifiedFiles.count)
            .animation(.snappy, value: viewModel.groupedBlockedFiles.count)
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

    private func identifyTarget(for item: LibraryImportItem) -> LibraryImportIdentifyTarget {
        LibraryImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
    }

    private func identifyTarget(for group: LibraryImportGroup) -> LibraryImportIdentifyTarget {
        let label = group.items.count == 1
            ? (group.items.first?.fileName ?? group.displayTitle)
            : "\(group.displayTitle) · \(group.items.count) files"
        return LibraryImportIdentifyTarget(id: group.id, items: group.items, displayLabel: label)
    }
}

private struct LibraryImportBlockedGroupInlineView: View {
    let group: LibraryImportGroup
    let viewModel: LibraryImportScanViewModel

    private var currentItems: [LibraryImportItem] {
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
                    LibraryImportBlockedRow(
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

struct LibraryImportEpisode: Sendable {
    let number: Int
    let title: String
}

nonisolated struct LibraryImportEpisodeKey: Hashable, Sendable {
    let seasonNumber: Int
    let episodeNumber: Int
}

struct LibraryImportItem: Identifiable, Sendable {
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
    let episodes: [LibraryImportEpisode]
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
            // Always force the embedded movie's id to the current match. A re-identified
            // file otherwise carries the previous match's movie object (or an empty `{}`
            // left from an "Unknown Movie" scan), and the ManualImport command keys off
            // that — importing to the wrong movie or failing as "Movie with id 0…".
            if case .object(var movieDict) = dict["movie"] {
                movieDict["id"] = .number(Double(id))
                dict["movie"] = .object(movieDict)
            } else {
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
            if case .object(var seriesDict) = dict["series"] {
                seriesDict["id"] = .number(Double(id))
                dict["series"] = .object(seriesDict)
            } else {
                dict["series"] = .object(["id": .number(Double(id))])
            }
        case .prowlarr, .bazarr:
            break
        }
        return .object(dict)
    }

    /// Returns a copy of this item identified as the given library entry.
    func withIdentification(mediaID: Int, title: String, posterURL: URL?) -> LibraryImportItem {
        LibraryImportItem(
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

    func withPendingAddIdentification(title: String, catalogID: Int?, posterURL: URL?) -> LibraryImportItem {
        LibraryImportItem(
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
        seasonNumber: Int?, episodes: [LibraryImportEpisode], qualityName: String?
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

        let parsedRejections = LibraryImportItem.extractMessages(from: dict["rejections"])
        self.warningMessages = LibraryImportItem.extractMessages(from: dict["warnings"])
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
            self.posterURL = LibraryImportItem.extractPosterURL(from: mediaDict["images"])
        } else {
            self.mediaTitle = nil
            self.mediaID = Self.intValue(from: dict["seriesId"]) ?? Self.intValue(from: dict["movieId"])
            self.catalogID = Self.intValue(from: dict["tvdbId"]) ?? Self.intValue(from: dict["tmdbId"])
            self.posterURL = nil
        }

        self.rejectionReasons = parsedRejections

        if case .number(let sn) = dict["seasonNumber"] { self.seasonNumber = Int(sn) } else { self.seasonNumber = nil }

        if case .array(let eps) = dict["episodes"] {
            self.episodes = eps.compactMap { ep -> LibraryImportEpisode? in
                guard case .object(let epDict) = ep,
                      case .number(let num) = epDict["episodeNumber"] else { return nil }
                let title: String
                if case .string(let t) = epDict["title"] { title = t } else { title = "" }
                return LibraryImportEpisode(number: Int(num), title: title)
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

/// A library title (movie/series) already imported from the scanned folder. Informational
/// only — shown under the Owned tab so the user can see what's already handled.
struct OwnedLibraryTitle: Identifiable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let posterURL: URL?
}

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
struct LibraryImportIdentifyTarget: Identifiable, Sendable {
    let id: String
    let items: [LibraryImportItem]
    let displayLabel: String
}

struct LibraryImportGroup: Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case identified(mediaID: Int)
        case pendingAdd(inferredKey: String)
        case unidentified(inferredKey: String)
    }

    let kind: Kind
    let displayTitle: String
    let posterURL: URL?
    let items: [LibraryImportItem]

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

private struct LibraryImportRow: View {
    let item: LibraryImportItem
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
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
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
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryImportBlockedRow: View {
    let item: LibraryImportItem
    let isSelected: Bool
    let isSelectingMode: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                ArrArtworkView(url: item.posterURL) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum LibraryImportGroupRowStyle {
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

private struct LibraryImportGroupRow: View {
    let group: LibraryImportGroup
    let style: LibraryImportGroupRowStyle
    let selectionState: GroupSelectionState
    let isSelectingMode: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                ArrArtworkView(url: group.posterURL) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        Image(systemName: style.placeholderIcon)
                            .font(.system(size: 14))
                            .foregroundStyle(style == .ready
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(style.accentColor))
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 8))

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

                    if group.isIdentified || group.isPendingAdd {
                        Text(group.fileSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(height: 32, alignment: .topLeading)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(group.qualityNames, id: \.self) { name in
                                statusChip(name, color: .blue)
                            }
                            statusChip(ByteFormatter.format(bytes: group.totalSize), color: .secondary)
                        }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

struct LibraryImportGroupSheet: View {
    let initialGroup: LibraryImportGroup
    let viewModel: LibraryImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: LibraryImportIdentifyTarget?

    private var currentItems: [LibraryImportItem] {
        initialGroup.items.compactMap { item in
            viewModel.importableFiles.first { $0.id == item.id }
        }
        // Drop files that were re-identified to a different title — they belong to another
        // group now and shouldn't linger here under this group's (stale) heading.
        .filter { initialGroup.mediaID == nil || $0.mediaID == initialGroup.mediaID }
    }

    private func identifyTarget(for item: LibraryImportItem) -> LibraryImportIdentifyTarget {
        LibraryImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
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
                            LibraryImportRow(
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
                LibraryImportIdentifySheet(
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

private struct LibraryImportSelectionReviewSheet: View {
    let viewModel: LibraryImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: LibraryImportIdentifyTarget?

    private var pendingAddGroups: [LibraryImportGroup] {
        viewModel.selectedBlockedGroups.filter(\.isPendingAdd)
    }

    private var unresolvedGroups: [LibraryImportGroup] {
        viewModel.selectedBlockedGroups.filter { !$0.isPendingAdd }
    }

    private var upgradingGroups: [LibraryImportGroup] {
        viewModel.selectedReadyGroups.filter { group in
            group.items.allSatisfy { viewModel.inLibraryItemIDs.contains($0.id) }
        }
    }

    private var trueReadyGroups: [LibraryImportGroup] {
        viewModel.selectedReadyGroups.filter { group in
            !group.items.allSatisfy { viewModel.inLibraryItemIDs.contains($0.id) }
        }
    }

    private var allImportableGroups: [LibraryImportGroup] {
        trueReadyGroups + pendingAddGroups + upgradingGroups
    }

    private var hasUnresolved: Bool { !unresolvedGroups.isEmpty }

    private func identifyTarget(for group: LibraryImportGroup) -> LibraryImportIdentifyTarget {
        let label = group.items.count == 1 ? group.items[0].fileName : "\(group.displayTitle) · \(group.items.count) files"
        return LibraryImportIdentifyTarget(id: group.id, items: group.items, displayLabel: label)
    }

    private var confirmCount: Int {
        viewModel.selectedFiles.count + pendingAddGroups.reduce(0) { $0 + $1.items.count }
    }

    private var importableGroupsFileCount: Int {
        allImportableGroups.reduce(0) { $0 + $1.items.count }
    }

    private var confirmTitle: String {
        let fileWord = confirmCount == 1 ? "file" : "files"
        return "Import \(confirmCount) \(fileWord)"
    }

    private var isConfirmDisabled: Bool {
        hasUnresolved || (viewModel.selectedFiles.isEmpty && pendingAddGroups.isEmpty) || viewModel.isScanning
    }

    private var titleWord: String {
        viewModel.service == .sonarr ? "series" : "movies"
    }

    private var readyHeaderText: String {
        let groupCount = allImportableGroups.count
        let fileCount = importableGroupsFileCount
        if groupCount == fileCount {
            return "Ready to Import (\(fileCount))"
        }
        let unit = groupCount == 1 ? (viewModel.service == .sonarr ? "series" : "movie") : titleWord
        return "Ready to Import · \(groupCount) \(unit) · \(fileCount) files"
    }

    var body: some View {
        AppSheetShell(
            title: "Review Selection",
            cancelTitle: "Close",
            confirmTitle: confirmTitle,
            isConfirmDisabled: isConfirmDisabled,
            onConfirm: {
                dismiss()
                Task { await viewModel.performImport() }
            },
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            List {
                if !allImportableGroups.isEmpty {
                    Section {
                        ForEach(trueReadyGroups) { group in
                            LibraryImportGroupRow(group: group, style: .ready, selectionState: .none, isSelectingMode: false, onToggle: {})
                        }
                        ForEach(pendingAddGroups) { group in
                            LibraryImportGroupRow(group: group, style: .pendingAdd, selectionState: .none, isSelectingMode: false, onToggle: { identifyingTarget = identifyTarget(for: group) })
                                .contextMenu { Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { identifyingTarget = identifyTarget(for: group) } }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { identifyingTarget = identifyTarget(for: group) }.tint(.blue)
                                }
                        }
                        ForEach(upgradingGroups) { group in
                            LibraryImportGroupRow(group: group, style: .ready, selectionState: .none, isSelectingMode: false, onToggle: {})
                                .opacity(0.65)
                        }
                    } header: {
                        Text(readyHeaderText)
                    } footer: {
                        if !pendingAddGroups.isEmpty {
                            Text("Identified titles will be added to \(viewModel.service.displayName) and imported together.")
                        } else if !upgradingGroups.isEmpty {
                            Text("Dimmed titles will replace an existing file in your library.")
                        }
                    }
                }

                if allImportableGroups.isEmpty && unresolvedGroups.isEmpty {
                    Section {
                        ContentUnavailableView("No Files Selected", systemImage: "checkmark.circle", description: Text("Everything in this selection has been cleared."))
                            .listRowBackground(Color.clear)
                    }
                }

                if !unresolvedGroups.isEmpty {
                    Section {
                        if hasUnresolved {
                            Label("Identify the files below before importing.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(unresolvedGroups) { group in
                            LibraryImportGroupRow(group: group, style: group.isIdentified ? .blocked : .unidentified, selectionState: .none, isSelectingMode: false, onToggle: { identifyingTarget = identifyTarget(for: group) })
                                .contextMenu { Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { identifyingTarget = identifyTarget(for: group) } }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Identify", systemImage: "rectangle.and.text.magnifyingglass") { identifyingTarget = identifyTarget(for: group) }.tint(.blue)
                                }
                        }
                    } header: {
                        Text("Identify Before Import (\(unresolvedGroups.count))")
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
                LibraryImportIdentifySheet(target: target, viewModel: viewModel, importAfterAdding: false, showsCancelButton: true, wrapInNavigationStack: true)
            }
        }
    }
}

// MARK: - Blocked Group Sheet

private struct LibraryImportBlockedGroupSheet: View {
    let group: LibraryImportGroup
    let viewModel: LibraryImportScanViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var identifyingTarget: LibraryImportIdentifyTarget?

    private var currentItems: [LibraryImportItem] {
        // Re-read from viewModel.blockedFiles so live updates (e.g. an item gets identified)
        // refresh the list while the sheet is open.
        let ids = Set(group.items.map(\.id))
        return viewModel.blockedFiles.filter { ids.contains($0.id) }
    }

    private func identifyTarget(for item: LibraryImportItem) -> LibraryImportIdentifyTarget {
        LibraryImportIdentifyTarget(id: "item-\(item.id)", items: [item], displayLabel: item.fileName)
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
                            LibraryImportBlockedRow(
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
                LibraryImportIdentifySheet(
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

private struct LibraryImportIdentifySheet: View {
    let target: LibraryImportIdentifyTarget
    let viewModel: LibraryImportScanViewModel
    let importAfterAdding: Bool
    let showsCancelButton: Bool
    let wrapInNavigationStack: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var currentItems: [LibraryImportItem] = []
    @State private var excludedItemIDs: Set<String> = []
    @State private var isFilesExpanded = false
    @State private var selectedResult: IdentifySelection?

    private var includedItems: [LibraryImportItem] {
        currentItems.filter { !excludedItemIDs.contains($0.id) }
    }

    private var representativeFileName: String {
        target.items.first?.fileName ?? target.displayLabel
    }

    private var navigationTitle: String {
        target.items.count > 1 ? "Identify \(target.items.count) Files" : "Identify File"
    }

    private struct CurrentMatch {
        let title: String
        let posterURL: URL?
        let seasonEpisode: String?
        let isTentative: Bool
    }

    private enum IdentifySelection: Hashable {
        case libraryMovie(RadarrMovie)
        case catalogMovie(RadarrMovie)
        case librarySeries(SonarrSeries)
        case catalogSeries(SonarrSeries)
    }

    private var isConfirmDisabled: Bool {
        selectedResult == nil || viewModel.isAddingToLibrary
    }

    private var currentMatch: CurrentMatch? {
        guard let first = target.items.first, let title = first.mediaTitle, !title.isEmpty else { return nil }
        var seasonEpisode: String?
        if let season = first.seasonNumber, !first.episodes.isEmpty {
            let numbers = first.episodes.map { "E\(String(format: "%02d", $0.number))" }.joined(separator: " · ")
            seasonEpisode = "S\(String(format: "%02d", season)) · \(numbers)"
        }
        let isTentative = (first.mediaID ?? 0) <= 0
        return CurrentMatch(title: title, posterURL: first.posterURL, seasonEpisode: seasonEpisode, isTentative: isTentative)
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
            currentItems = target.items
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        #else
        .searchable(text: $searchText, prompt: searchPrompt)
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
        .safeAreaInset(edge: .bottom) {
            identifyActionBar
        }
    }

    private var identifyActionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await commitSelectedResult(importAfterAdding: false) }
            } label: {
                Text(addLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glass(.regular))

            Button {
                Task { await commitSelectedResult(importAfterAdding: true) }
            } label: {
                Text(addAndImportLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glass(.regular.tint(Color.accentColor)))
        }
        .disabled(isConfirmDisabled)
        .animation(.snappy, value: isConfirmDisabled)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        List {
            if let match = currentMatch {
                Section {
                    currentMatchRow(match)
                } header: {
                    Text(match.isTentative ? "Tentative Match" : "Currently Identified")
                }
            }

            Section {
                if currentItems.count > 1 {
                    let includedCount = currentItems.count - excludedItemIDs.count
                    DisclosureGroup(isExpanded: $isFilesExpanded) {
                        ForEach(currentItems) { item in
                            let isExcluded = excludedItemIDs.contains(item.id)
                            let isLastIncluded = !isExcluded && includedCount == 1
                            HStack(spacing: 10) {
                                Button {
                                    withAnimation {
                                        if isExcluded {
                                            excludedItemIDs.remove(item.id)
                                        } else {
                                            excludedItemIDs.insert(item.id)
                                        }
                                    }
                                } label: {
                                    Image(systemName: isExcluded ? "plus.circle.fill" : "minus.circle.fill")
                                        .foregroundStyle(isExcluded ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLastIncluded)

                                Text(item.path)
                                    .font(.caption)
                                    .foregroundStyle(isExcluded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                                    .lineLimit(2)
                                    .strikethrough(isExcluded, color: .secondary)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.displayLabel)
                                .font(.subheadline.weight(.semibold))
                            Text("Your choice will apply to \(includedCount == currentItems.count ? "all \(includedCount)" : "\(includedCount) of \(currentItems.count)") files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(currentItems.first?.path ?? target.displayLabel)
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
        if viewModel.importKind == .manual {
            manualRadarrSections
        } else {
            libraryRadarrSections
        }
    }

    @ViewBuilder
    private var libraryRadarrSections: some View {
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
        if viewModel.importKind == .manual {
            manualSonarrSections
        } else {
            librarySonarrSections
        }
    }

    @ViewBuilder
    private var librarySonarrSections: some View {
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

    // MARK: Manual import — existing library titles only

    private var addLabel: String { viewModel.importKind == .manual ? "Match" : "Add" }
    private var addAndImportLabel: String { viewModel.importKind == .manual ? "Match & Import" : "Add and Import" }
    private var searchPrompt: String { viewModel.importKind == .manual ? "Search your library" : "Search your library or Discover" }

    /// Library movies whose filename-derived suggestion matched — shown before the user searches.
    private var manualMovieSuggestions: [RadarrMovie] {
        let suggested = Set(viewModel.autoSuggestionMovies.compactMap(\.tmdbId))
        return viewModel.libraryMovies.filter { movie in
            guard let id = movie.tmdbId else { return false }
            return suggested.contains(id)
        }
    }

    private var manualMovieMatches: [RadarrMovie] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return viewModel.libraryMovies
            .filter { $0.title.localizedCaseInsensitiveContains(q) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var manualSeriesSuggestions: [SonarrSeries] {
        let suggested = Set(viewModel.autoSuggestionSeries.compactMap(\.tvdbId))
        return viewModel.librarySeries.filter { series in
            guard let id = series.tvdbId else { return false }
            return suggested.contains(id)
        }
    }

    private var manualSeriesMatches: [SonarrSeries] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return viewModel.librarySeries
            .filter { $0.title.localizedCaseInsensitiveContains(q) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @ViewBuilder
    private var manualRadarrSections: some View {
        let matches = searchText.isEmpty ? manualMovieSuggestions : manualMovieMatches
        if !matches.isEmpty {
            Section(searchText.isEmpty ? "Maybe:" : "Your Library") {
                ForEach(matches) { movie in
                    libraryMovieRow(movie)
                }
            }
        } else {
            ContentUnavailableView(
                searchText.isEmpty ? "Find the movie" : "No Library Match",
                systemImage: "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Search for a movie that's already in your library to match this file."
                    : "No movie in your library matches “\(searchText)”. To add a new movie, use Library Import.")
            )
        }
    }

    @ViewBuilder
    private var manualSonarrSections: some View {
        let matches = searchText.isEmpty ? manualSeriesSuggestions : manualSeriesMatches
        if !matches.isEmpty {
            Section(searchText.isEmpty ? "Maybe:" : "Your Library") {
                ForEach(matches) { series in
                    librarySeriesRow(series)
                }
            }
        } else {
            ContentUnavailableView(
                searchText.isEmpty ? "Find the series" : "No Library Match",
                systemImage: "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Search for a series that's already in your library to match this file."
                    : "No series in your library matches “\(searchText)”. To add a new series, use Library Import.")
            )
        }
    }

    private func select(_ selection: IdentifySelection) {
        withAnimation(.snappy) {
            selectedResult = selection
        }
    }

    private func badgeText(for selection: IdentifySelection) -> String {
        selectedResult == selection ? "Selected" : "Select"
    }

    private func isSelected(_ selection: IdentifySelection) -> Bool {
        selectedResult == selection
    }

    @MainActor
    private func commitSelectedResult(importAfterAdding: Bool) async {
        guard let selectedResult else { return }
        let originalIDs = Set(includedItems.map(\.id))
        let succeeded: Bool

        switch selectedResult {
        case .libraryMovie(let movie):
            viewModel.applyIdentification(to: includedItems, mediaID: movie.id, title: movie.title, posterURL: posterURL(from: movie.images))
            succeeded = importAfterAdding ? await viewModel.importIdentifiedItems(originalIDs: originalIDs) : true
        case .catalogMovie(let movie):
            succeeded = await viewModel.addToLibraryAndIdentify(blockedItems: includedItems, movie: movie, importAfterAdding: importAfterAdding)
        case .librarySeries(let series):
            viewModel.applyIdentification(to: includedItems, mediaID: series.id, title: series.title, posterURL: posterURL(from: series.images))
            succeeded = importAfterAdding ? await viewModel.importIdentifiedItems(originalIDs: originalIDs) : true
        case .catalogSeries(let series):
            succeeded = await viewModel.addToLibraryAndIdentify(blockedItems: includedItems, series: series, importAfterAdding: importAfterAdding)
        }

        if succeeded {
            dismiss()
        }
    }

    private func libraryMovieRow(_ movie: RadarrMovie) -> some View {
        let selection = IdentifySelection.libraryMovie(movie)
        let posterImageURL = posterURL(from: movie.images)
        return Button {
            select(selection)
        } label: {
            mediaRow(title: movie.title, year: movie.year, posterURL: posterImageURL, badge: badgeText(for: selection), isSelected: isSelected(selection))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func catalogMovieRow(_ movie: RadarrMovie) -> some View {
        let selection = IdentifySelection.catalogMovie(movie)
        let posterImageURL = posterURL(from: movie.images)
        return Button {
            select(selection)
        } label: {
            mediaRow(title: movie.title, year: movie.year, posterURL: posterImageURL, badge: badgeText(for: selection), isSelected: isSelected(selection))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func librarySeriesRow(_ s: SonarrSeries) -> some View {
        let selection = IdentifySelection.librarySeries(s)
        let posterImageURL = posterURL(from: s.images)
        return Button {
            select(selection)
        } label: {
            mediaRow(title: s.title, year: s.year, posterURL: posterImageURL, badge: badgeText(for: selection), isSelected: isSelected(selection))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func catalogSeriesRow(_ s: SonarrSeries) -> some View {
        let selection = IdentifySelection.catalogSeries(s)
        let posterImageURL = posterURL(from: s.images)
        return Button {
            select(selection)
        } label: {
            mediaRow(title: s.title, year: s.year, posterURL: posterImageURL, badge: badgeText(for: selection), isSelected: isSelected(selection))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func currentMatchRow(_ match: CurrentMatch) -> some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: match.posterURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(match.isTentative ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                }
            }
            .frame(width: 46, height: 69)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(match.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let seasonEpisode = match.seasonEpisode {
                    Text(seasonEpisode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(match.isTentative
                     ? "Pending add to \(viewModel.service.displayName)"
                     : "Already in \(viewModel.service.displayName)")
                    .font(.caption2)
                    .foregroundStyle(match.isTentative ? .orange : .secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func mediaRow(title: String, year: Int?, posterURL: URL?, badge: String?, isSelected: Bool) -> some View {
        ArrCatalogMediaRow(title: title, year: year, posterURL: posterURL, badge: badge, isSelected: isSelected)
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
