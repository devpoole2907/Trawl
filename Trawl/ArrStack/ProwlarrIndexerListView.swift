import SwiftUI

struct ProwlarrIndexerListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: ProwlarrViewModel?
    @State private var indexerToDelete: ProwlarrIndexer?
    @State private var showTestAllConfirm = false
    @State private var showAddSheet = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var showIndexerFilter = false

    var body: some View {
        Group {
            if let vm = viewModel {
                mainContent(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Indexers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            if viewModel == nil {
                viewModel = ProwlarrViewModel(serviceManager: serviceManager)
            }
            await viewModel?.loadIndexers()
        }
        .sheet(isPresented: $showAddSheet) {
            if let vm = viewModel {
                ProwlarrAddIndexerSheet(viewModel: vm)
            }
        }
        .searchable(text: $searchText, isPresented: $isSearchActive, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search releases…")
        .onSubmit(of: .search) {
            guard let vm = viewModel else { return }
            vm.searchQuery = searchText
            Task { await vm.performSearch() }
        }
        .onChange(of: isSearchActive) { _, active in
            if !active {
                searchText = ""
                viewModel?.clearSearch()
            }
        }
    }

    // MARK: - Main content (hosts alerts so they work in both modes)

    @ViewBuilder
    private func mainContent(vm: ProwlarrViewModel) -> some View {
        @Bindable var vm = vm
        Group {
            if isSearchActive {
                searchContent(vm: vm)
            } else {
                indexerList(vm: vm)
            }
        }
        .alert("Delete Indexer?", isPresented: .init(
            get: { indexerToDelete != nil },
            set: { if !$0 { indexerToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let indexer = indexerToDelete else { return }
                let name = indexer.name ?? "Indexer"
                indexerToDelete = nil
                Task {
                    let deleted = await vm.deleteIndexer(indexer)
                    if let error = vm.indexerError {
                        InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
                        vm.clearIndexerError()
                    } else if deleted && !vm.containsIndexer(id: indexer.id) {
                        InAppNotificationCenter.shared.showSuccess(title: "Indexer Deleted", message: "\(name) has been removed.")
                    }
                }
            }
            Button("Cancel", role: .cancel) { indexerToDelete = nil }
        } message: {
            Text("This removes \"\(indexerToDelete?.name ?? "this indexer")\" from Prowlarr.")
        }
        .alert("Test All Indexers?", isPresented: $showTestAllConfirm) {
            Button("Test All") {
                Task { await vm.testAllIndexers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = vm.indexers.count
            Text("This will send a test request to all \(count) \(count == 1 ? "indexer" : "indexers"). It may take a moment.")
        }
        .onChange(of: vm.testResult) { _, result in
            guard let result else { return }
            if vm.testSucceeded == true {
                InAppNotificationCenter.shared.showSuccess(title: "Test Complete", message: result)
            } else {
                InAppNotificationCenter.shared.showError(title: "Test Failed", message: result)
            }
            vm.clearTestResult()
        }
        .sheet(isPresented: $showIndexerFilter) {
            IndexerFilterSheet(
                indexers: vm.indexers,
                selectedIds: $vm.selectedIndexerIds,
                onSelectionChanged: {
                    guard !vm.searchQuery.isEmpty else { return }
                    Task { await vm.performSearch() }
                }
            )
        }
    }

    // MARK: - Indexer list

    @ViewBuilder
    private func indexerList(vm: ProwlarrViewModel) -> some View {
        List {
            if vm.isLoadingIndexers && vm.indexers.isEmpty {
                loadingRows
            } else if vm.indexers.isEmpty {
                emptyState
            } else {
                if let stats = vm.indexerStats {
                    statsOverviewSection(stats: stats)
                }
                indexerSections(vm: vm)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .refreshable { await vm.loadIndexers() }
        .toolbar { toolbarContent(vm: vm) }
    }

    // MARK: - Search content

    @ViewBuilder
    private func searchContent(vm: ProwlarrViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProwlarrSearchType.allCases) { type in
                        Button {
                            vm.searchType = type
                            if !vm.searchQuery.isEmpty {
                                Task { await vm.performSearch() }
                            }
                        } label: {
                            Label(type.displayName, systemImage: type.systemImage)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(vm.searchType == type ? .white : .primary)
                        .background(
                            vm.searchType == type ? Color.yellow : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .animation(.easeInOut(duration: 0.15), value: vm.searchType)
                    }

                    Divider().frame(height: 20)

                    Button {
                        showIndexerFilter = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(vm.selectedIndexerIds.isEmpty
                                 ? "All Indexers"
                                 : "\(vm.selectedIndexerIds.count) selected")
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(vm.selectedIndexerIds.isEmpty ? Color.primary : Color.white)
                    .background(
                        vm.selectedIndexerIds.isEmpty ? Color.secondary.opacity(0.12) : Color.yellow,
                        in: Capsule()
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 10)

            Divider()

            searchResultsContent(vm: vm)
        }
        .background(backgroundGradient)
    }

    @ViewBuilder
    private func searchResultsContent(vm: ProwlarrViewModel) -> some View {
        if vm.isSearching {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Searching…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.searchError {
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if vm.searchResults.isEmpty && !vm.searchQuery.isEmpty {
            ContentUnavailableView.search(text: vm.searchQuery)
        } else if vm.searchResults.isEmpty {
            ContentUnavailableView {
                Label("Search Releases", systemImage: "magnifyingglass")
            } description: {
                Text("Enter a term and tap Return to search across your indexers.")
            }
        } else {
            List {
                Section {
                    Text("\(vm.searchResults.count) results")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))

                ForEach(vm.searchResults) { result in
                    SearchResultRow(result: result)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Indexer sections

    @ViewBuilder
    private func statsOverviewSection(stats: ProwlarrIndexerStats) -> some View {
        let entries = stats.indexers ?? []
        let totalQueries = entries.reduce(0) { $0 + ($1.numberOfQueries ?? 0) }
        let totalGrabs = entries.reduce(0) { $0 + ($1.numberOfGrabs ?? 0) }
        let totalFailed = entries.reduce(0) { $0 + ($1.numberOfFailedQueries ?? 0) }

        Section("Overview") {
            LabeledContent("Queries", value: "\(totalQueries)")
            LabeledContent("Grabs", value: "\(totalGrabs)")
            LabeledContent("Failed", value: "\(totalFailed)")
            if totalQueries > 0 {
                let rate = Double(totalQueries - totalFailed) / Double(totalQueries) * 100
                LabeledContent("Success Rate", value: String(format: "%.0f%%", rate))
            }
        }
    }

    @ViewBuilder
    private func indexerSections(vm: ProwlarrViewModel) -> some View {
        if !vm.torrentIndexers.isEmpty {
            Section("Torrent") {
                ForEach(vm.torrentIndexers) { indexer in
                    indexerRow(indexer, vm: vm)
                }
            }
        }
        if !vm.usenetIndexers.isEmpty {
            Section("Usenet") {
                ForEach(vm.usenetIndexers) { indexer in
                    indexerRow(indexer, vm: vm)
                }
            }
        }
        if !vm.otherIndexers.isEmpty {
            Section("Other") {
                ForEach(vm.otherIndexers) { indexer in
                    indexerRow(indexer, vm: vm)
                }
            }
        }
    }

    @ViewBuilder
    private func indexerRow(_ indexer: ProwlarrIndexer, vm: ProwlarrViewModel) -> some View {
        NavigationLink {
            ProwlarrIndexerDetailView(indexer: indexer, viewModel: vm)
        } label: {
            IndexerRowView(
                indexer: indexer,
                status: vm.statusForIndexer(id: indexer.id),
                stats: vm.statsForIndexer(id: indexer.id)
            )
        }
        .swipeActions(edge: .leading) {
            Button {
                Task {
                    await vm.testIndexer(indexer)
                    // result flows through onChange(of: vm.testResult)
                }
            } label: {
                Label("Test", systemImage: "checkmark.circle")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                indexerToDelete = indexer
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                let wasEnabled = indexer.enable
                let name = indexer.name ?? "Indexer"
                Task {
                    await vm.toggleIndexer(indexer)
                    if let error = vm.indexerError {
                        InAppNotificationCenter.shared.showError(title: "Update Failed", message: error)
                        vm.clearIndexerError()
                    } else {
                        InAppNotificationCenter.shared.showSuccess(
                            title: wasEnabled ? "Indexer Disabled" : "Indexer Enabled",
                            message: "\(name) has been \(wasEnabled ? "disabled" : "enabled")."
                        )
                    }
                }
            } label: {
                Label(indexer.enable ? "Disable" : "Enable",
                      systemImage: indexer.enable ? "pause.circle" : "play.circle")
            }
            Button {
                Task { await vm.testIndexer(indexer) }
            } label: {
                Label("Test", systemImage: "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) {
                indexerToDelete = indexer
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(vm: ProwlarrViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Indexer", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showTestAllConfirm = true
            } label: {
                Label("Test All", systemImage: "checkmark.circle.badge.questionmark")
            }
            .disabled(vm.isTesting || vm.indexers.isEmpty)
        }
    }

    // MARK: - Empty / loading states

    private var loadingRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 8, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 140, height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 90, height: 11)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Indexers",
            systemImage: "magnifyingglass.circle",
            description: Text("Tap + to add your first indexer.")
        )
        .listRowBackground(Color.clear)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.yellow.opacity(0.15), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.yellow.opacity(0.12), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Indexer row view

private struct IndexerRowView: View {
    let indexer: ProwlarrIndexer
    let status: ProwlarrIndexerStatus?
    let stats: ProwlarrIndexerStatEntry?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(statusColor)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(indexer.name ?? "Unknown")
                        .font(.body.weight(.medium))
                        .foregroundStyle(indexer.enable ? .primary : .secondary)

                    if let priority = indexer.priority, priority != 25 {
                        Text("P\(priority)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.8), in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    if let impl = indexer.implementationName ?? indexer.implementation {
                        Text(impl).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let proto = indexer.protocol {
                        Text("·").foregroundStyle(.tertiary)
                        Label(proto.displayName, systemImage: proto.systemImage)
                            .font(.caption).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
                    }
                    if let grabs = stats?.numberOfGrabs, grabs > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(grabs) grabs").font(.caption).foregroundStyle(.green)
                    }
                    if let rate = stats?.successRate {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: "%.0f%%", rate * 100))
                            .font(.caption)
                            .foregroundStyle(rate > 0.9 ? .green : rate > 0.7 ? .orange : .red)
                    }
                }
            }

            Spacer()

            if status?.isDisabled == true {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            } else if indexer.enable {
                Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
            } else {
                Image(systemName: "circle").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(indexer.enable ? 1.0 : 0.6)
    }

    private var statusColor: Color {
        if status?.isDisabled == true { return .orange }
        return indexer.enable ? .yellow : .secondary.opacity(0.4)
    }
}

// MARK: - Search result row

private struct SearchResultRow: View {
    let result: ProwlarrSearchResult
    @State private var showActionSheet = false
    @State private var showAddTorrentSheet = false
    @State private var downloadedTorrentURL: String?

    var body: some View {
        Button {
            showActionSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title ?? "Unknown")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            if let indexer = result.indexer {
                                Text(indexer).font(.caption).foregroundStyle(.yellow)
                            }
                            if let age = result.ageDescription {
                                Text("·").foregroundStyle(.tertiary)
                                Text(age).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        if let size = result.size {
                            Text(ByteFormatter.format(bytes: size))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        if result.isFreeleech {
                            Text("FL")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.green, in: Capsule())
                        }
                    }
                }

                if let seeders = result.seeders, result.isTorrent {
                    HStack(spacing: 10) {
                        Label("\(seeders)", systemImage: "arrow.up.circle.fill").foregroundStyle(.green)
                        if let leechers = result.leechers {
                            Label("\(leechers)", systemImage: "arrow.down.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(result.title ?? "Download", isPresented: $showActionSheet, titleVisibility: .visible) {
            if let url = result.downloadUrl {
                if result.isMagnet {
                    Button("Add to qBittorrent") { openMagnet(url) }
                } else if result.isTorrent {
                    Button("Add to qBittorrent") {
                        downloadedTorrentURL = url
                        showAddTorrentSheet = true
                    }
                } else {
                    Text("Usenet — not supported in Trawl")
                }
                Button("Copy Link") { copyToClipboard(url) }
            }
            if let infoUrl = result.infoUrl, !infoUrl.isEmpty, let url = URL(string: infoUrl) {
                Button("Open Info Page") { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showAddTorrentSheet) {
            if let urlString = downloadedTorrentURL {
                AddTorrentSheet(initialMagnetURL: urlString)
            }
        }
    }

    private func copyToClipboard(_ urlString: String) {
        #if os(iOS)
        UIPasteboard.general.string = urlString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        #endif
        InAppNotificationCenter.shared.showSuccess(title: "Link Copied", message: "The download link has been copied to your clipboard.")
    }

    private func openURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func openMagnet(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Indexer filter sheet

private struct IndexerFilterSheet: View {
    let indexers: [ProwlarrIndexer]
    @Binding var selectedIds: Set<Int>
    let onSelectionChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("All Indexers") {
                        selectedIds = []
                        onSelectionChanged()
                        dismiss()
                    }
                    .foregroundStyle(selectedIds.isEmpty ? .yellow : .primary)
                }

                Section("Select Indexers") {
                    ForEach(indexers) { indexer in
                        Button {
                            if selectedIds.contains(indexer.id) {
                                selectedIds.remove(indexer.id)
                            } else {
                                selectedIds.insert(indexer.id)
                            }
                            onSelectionChanged()
                        } label: {
                            HStack {
                                Text(indexer.name ?? "Unknown").foregroundStyle(.primary)
                                Spacer()
                                if selectedIds.contains(indexer.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.yellow)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter Indexers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
