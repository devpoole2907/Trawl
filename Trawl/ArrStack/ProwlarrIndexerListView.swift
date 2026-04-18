import SwiftUI

struct ProwlarrIndexerListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: ProwlarrViewModel?
    @State private var indexerToDelete: ProwlarrIndexer?
    @State private var showTestResultAlert = false
    @State private var showAddSheet = false

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
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
    }

    @ViewBuilder
    private func content(vm: ProwlarrViewModel) -> some View {
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
        .alert("Delete Indexer?", isPresented: .init(
            get: { indexerToDelete != nil },
            set: { if !$0 { indexerToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let indexer = indexerToDelete else { return }
                Task { await vm.deleteIndexer(indexer) }
                indexerToDelete = nil
            }
            Button("Cancel", role: .cancel) { indexerToDelete = nil }
        } message: {
            Text("This removes \"\(indexerToDelete?.name ?? "this indexer")\" from Prowlarr.")
        }
        .alert("Test Result", isPresented: $showTestResultAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.testResult ?? "")
        }
        .onChange(of: vm.testResult) { _, result in
            if result != nil { showTestResultAlert = true }
        }
        .alert("Error", isPresented: .init(
            get: { vm.indexerError != nil },
            set: { if !$0 { vm.clearIndexerError() } }
        )) {
            Button("OK", role: .cancel) {
                vm.clearIndexerError()
            }
        } message: {
            Text(vm.indexerError ?? "")
        }
    }

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
                Task { await vm.toggleIndexer(indexer) }
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
                Task { await vm.testAllIndexers() }
            } label: {
                Label("Test All", systemImage: "checkmark.circle.badge.questionmark")
            }
            .disabled(vm.isTesting || vm.indexers.isEmpty)
        }
    }

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

// MARK: - Indexer Row

private struct IndexerRowView: View {
    let indexer: ProwlarrIndexer
    let status: ProwlarrIndexerStatus?
    let stats: ProwlarrIndexerStatEntry?

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator bar
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
                        Text(impl)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let proto = indexer.protocol {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Label(proto.displayName, systemImage: proto.systemImage)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .labelStyle(.titleAndIcon)
                    }

                    if let grabs = stats?.numberOfGrabs, grabs > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(grabs) grabs")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if let rate = stats?.successRate {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(String(format: "%.0f%%", rate * 100))
                            .font(.caption)
                            .foregroundStyle(rate > 0.9 ? .green : rate > 0.7 ? .orange : .red)
                    }
                }
            }

            Spacer()

            if status?.isDisabled == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if indexer.enable {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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