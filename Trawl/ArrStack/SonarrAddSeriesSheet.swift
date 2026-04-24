import SwiftUI

struct SonarrAddSeriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SonarrViewModel
    @State private var searchQuery = ""
    @State private var selectedSeries: SonarrSeries?
    @State private var selectedQualityProfileId: Int?
    @State private var selectedRootFolderPath: String?
    @State private var monitorOption = "all"
    @State private var searchForMissing = true
    @State private var optionsExpanded = false
    @State private var isAdding = false
    @State private var qualityProfileForDetails: ArrQualityProfile?

    var body: some View {
        ArrSheetShell(
            title: "Add Series",
            confirmTitle: "Add",
            isConfirmDisabled: !canAddSelectedSeries,
            onConfirm: {
                Task { await addSelectedSeries() }
            }
        ) {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search TV shows...", text: $searchQuery)
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                Task { await performSearch() }
                            }
                    }
                    .padding(10)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if viewModel.isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Searching...")
                            Spacer()
                        }
                    }
                } else if viewModel.searchResults.isEmpty && !searchQuery.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: searchQuery)
                    }
                } else if !viewModel.searchResults.isEmpty {
                    Section("Results") {
                        ForEach(viewModel.searchResults) { result in
                            searchResultRow(for: result)
                        }
                    }
                }

                if let selectedSeries, !isInLibrary(selectedSeries) {
                    Section {
                        DisclosureGroup("Options", isExpanded: $optionsExpanded) {
                            Picker("Quality Profile", selection: $selectedQualityProfileId) {
                                ForEach(viewModel.qualityProfiles, id: \.id) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }

                            if let selectedQualityProfile {
                                Button {
                                    qualityProfileForDetails = selectedQualityProfile
                                } label: {
                                    Label("View Selected Profile Details", systemImage: "info.circle")
                                }
                            }

                            Picker("Root Folder", selection: $selectedRootFolderPath) {
                                ForEach(viewModel.rootFolders, id: \.path) { folder in
                                    let freeLabel = folder.freeSpace.map { " · " + ByteFormatter.formatRounded(bytes: $0) + " free" } ?? ""
                                    Text(folder.path + freeLabel)
                                        .tag(Optional(folder.path))
                                }
                            }

                            Picker("Monitor", selection: $monitorOption) {
                                ForEach(SonarrMonitorOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }

                            Toggle("Search for Missing", isOn: $searchForMissing)
                        }
                    } header: {
                        Text("Add \(selectedSeries.title)")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("**Monitor** controls which episodes Sonarr tracks and downloads:")
                            Text("• **All** — every episode, past and future")
                            Text("• **Future** — only episodes that haven't aired yet")
                            Text("• **Missing** — existing episodes without files")
                            Text("• **First / Latest Season** — only that season")
                            Text("• **None** — nothing is monitored automatically")
                            Text("**Search for Missing** triggers an immediate search for any monitored episodes that don't have a file yet.")
                        }
                        .font(.caption)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .task {
                selectedQualityProfileId = viewModel.qualityProfiles.first?.id
                selectedRootFolderPath = viewModel.rootFolders.first?.path
            }
        }
        .sheet(item: $qualityProfileForDetails) { profile in
            NavigationStack {
                ArrQualityProfileDetailView(serviceType: .sonarr, profile: profile)
            }
        }
    }

    private var canAddSelectedSeries: Bool {
        selectedSeries != nil &&
        selectedQualityProfileId != nil &&
        selectedRootFolderPath != nil &&
        !isAdding &&
        selectedSeries.map { !isInLibrary($0) } == true
    }

    private var selectedQualityProfile: ArrQualityProfile? {
        guard let selectedQualityProfileId else { return nil }
        return viewModel.qualityProfiles.first { $0.id == selectedQualityProfileId }
    }

    private func performSearch() async {
        await viewModel.searchForNewSeries(term: searchQuery)
        if viewModel.searchResults.isEmpty {
            selectedSeries = nil
            optionsExpanded = false
        }
    }

    private func isInLibrary(_ series: SonarrSeries) -> Bool {
        viewModel.series.contains(where: { $0.tvdbId == series.tvdbId })
    }

    private func addSelectedSeries() async {
        guard let selectedSeries else { return }
        await addSeries(selectedSeries)
    }

    @ViewBuilder
    private func searchResultRow(for result: SonarrSeries) -> some View {
        let isSelected = selectedSeries?.id == result.id
        let existsInLibrary = isInLibrary(result)

        SearchResultRow(
            series: result,
            isSelected: isSelected,
            existsInLibrary: existsInLibrary,
            onSelect: {
                selectedSeries = result
                optionsExpanded = true
            }
        )
    }

    private func addSeries(_ series: SonarrSeries) async {
        guard !isAdding else { return }
        guard let qpId = selectedQualityProfileId,
              let rootPath = selectedRootFolderPath,
              let tvdbId = series.tvdbId,
              let titleSlug = series.titleSlug else { return }

        isAdding = true
        let success = await viewModel.addSeries(
            tvdbId: tvdbId,
            title: series.title,
            titleSlug: titleSlug,
            images: series.images ?? [],
            seasons: series.seasons ?? [],
            qualityProfileId: qpId,
            rootFolderPath: rootPath,
            monitorOption: monitorOption,
            searchForMissing: searchForMissing
        )
        isAdding = false
        if success { dismiss() }
    }
}

private enum SonarrMonitorOption: String, CaseIterable, Identifiable {
    case all
    case future
    case missing
    case firstSeason
    case latestSeason
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .future: "Future"
        case .missing: "Missing"
        case .firstSeason: "First Season"
        case .latestSeason: "Latest Season"
        case .none: "None"
        }
    }
}

private struct SearchResultRow: View {
    let series: SonarrSeries
    let isSelected: Bool
    let existsInLibrary: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ArrArtworkView(url: series.posterURL) {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
                }
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(series.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let year = series.year { Text(String(year)).font(.caption2) }
                        if let network = series.network { Text("• \(network)").font(.caption2) }
                        Text("• \(series.status?.capitalized ?? "")")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    if let overview = series.overview {
                        Text(overview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                Spacer()

                if existsInLibrary {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
