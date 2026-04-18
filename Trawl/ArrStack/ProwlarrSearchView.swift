import SwiftUI

struct ProwlarrSearchView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: ProwlarrViewModel?
    @State private var showIndexerFilter = false

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Indexer Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            if viewModel == nil {
                viewModel = ProwlarrViewModel(serviceManager: serviceManager)
            }
            await viewModel?.loadIndexers()
        }
    }

    @ViewBuilder
    private func content(vm: ProwlarrViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            searchControls(vm: vm)
            resultsList(vm: vm)
        }
        .background(backgroundGradient)
    }

    @ViewBuilder
    private func searchControls(vm: ProwlarrViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search indexers…", text: $vm.searchQuery)
                        .onSubmit { Task { await vm.performSearch() } }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if !vm.searchQuery.isEmpty {
                        Button {
                            vm.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button {
                    Task { await vm.performSearch() }
                } label: {
                    Text("Search")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .disabled(vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSearching)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProwlarrSearchType.allCases) { type in
                        Button {
                            vm.searchType = type
                        } label: {
                            Label(type.displayName, systemImage: type.systemImage)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(vm.searchType == type ? .white : .primary)
                        .background(vm.searchType == type ? Color.yellow : Color.secondary.opacity(0.12),
                                    in: Capsule())
                        .animation(.easeInOut(duration: 0.15), value: vm.searchType)
                    }

                    Divider()
                        .frame(height: 20)

                    Button {
                        showIndexerFilter = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(vm.selectedIndexerIds.isEmpty ? "All Indexers" : "\(vm.selectedIndexerIds.count) selected")
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(vm.selectedIndexerIds.isEmpty ? Color.primary : Color.white)
                    .background(vm.selectedIndexerIds.isEmpty ? Color.secondary.opacity(0.12) : Color.yellow,
                                in: Capsule())
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .sheet(isPresented: $showIndexerFilter) {
            IndexerFilterSheet(indexers: vm.indexers, selectedIds: Binding(get: { vm.selectedIndexerIds }, set: { vm.selectedIndexerIds = $0 }))
        }
    }

    @ViewBuilder
    private func resultsList(vm: ProwlarrViewModel) -> some View {
        if vm.isSearching {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Searching…")
                    .foregroundStyle(.secondary)
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
                Label("Search Indexers", systemImage: "magnifyingglass")
            } description: {
                Text("Enter a search term to find releases across your indexers.")
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

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.yellow.opacity(0.12), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: ProwlarrSearchResult
    @State private var showActionSheet = false

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
                                Text(indexer)
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            if let age = result.ageDescription {
                                Text("·").foregroundStyle(.tertiary)
                                Text(age)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        Label("\(seeders)", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                        if let leechers = result.leechers {
                            Label("\(leechers)", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(.secondary)
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
                    Button("Add to qBittorrent") {
                        openMagnet(url)
                    }
                } else if result.isTorrent {
                    Button("Add to qBittorrent") {
                        openMagnet(url)
                    }
                } else {
                    Text("Usenet — not supported in Trawl")
                }
                Button("Copy Link") {
                    #if os(iOS)
                    UIPasteboard.general.string = url
                    #endif
                }
            }
            if let infoUrl = result.infoUrl, !infoUrl.isEmpty, let url = URL(string: infoUrl) {
                Button("Open Info Page") {
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    #endif
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func openMagnet(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Indexer Filter Sheet

private struct IndexerFilterSheet: View {
    let indexers: [ProwlarrIndexer]
    @Binding var selectedIds: Set<Int>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("All Indexers") {
                        selectedIds = []
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
                        } label: {
                            HStack {
                                Text(indexer.name ?? "Unknown")
                                    .foregroundStyle(.primary)
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
