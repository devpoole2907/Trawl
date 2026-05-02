import SwiftUI

struct RadarrAddMovieSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RadarrViewModel
    @State private var searchQuery = ""
    @State private var selectedMovie: RadarrMovie?
    @State private var selectedQualityProfileId: Int?
    @State private var selectedRootFolderPath: String?
    @State private var minimumAvailability = "released"
    @State private var monitorOption = "movieOnly"
    @State private var searchForMovie = true
    @State private var optionsExpanded = false
    @State private var isAdding = false
    @State private var qualityProfileForDetails: ArrQualityProfile?

    var body: some View {
        ArrSheetShell(
            title: "Add Movie",
            confirmTitle: "Add",
            isConfirmDisabled: !canAddSelectedMovie,
            onConfirm: {
                Task { await addSelectedMovie() }
            }
        ) {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search movies...", text: $searchQuery)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
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
                            movieSearchResultRow(for: result)
                        }
                    }
                }

                if let selectedMovie, !isInLibrary(selectedMovie) {
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

                            Picker("Minimum Availability", selection: $minimumAvailability) {
                                ForEach(RadarrMinimumAvailabilityOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }

                            Picker("Monitor", selection: $monitorOption) {
                                ForEach(RadarrMonitorOption.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }

                            Toggle("Search for Missing", isOn: $searchForMovie)
                        }
                    } header: {
                        Text("Add \(selectedMovie.title)")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("**Minimum Availability** sets when Radarr considers a release eligible for download (Announced → In Cinemas → Released).")
                            Text("**Monitor** controls what Radarr tracks: Movie Only monitors this film; Movie and Collection also monitors the collection it belongs to; None disables monitoring.")
                            Text("**Search for Missing** triggers an immediate search after adding if the movie is not yet available.")
                        }
                        .font(.caption)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .task {
                selectedQualityProfileId = viewModel.qualityProfiles.first?.id
                selectedRootFolderPath = viewModel.rootFolders.first?.path
            }
        }
        .sheet(item: $qualityProfileForDetails) { profile in
            NavigationStack {
                ArrQualityProfileDetailView(serviceType: .radarr, profile: profile)
            }
        }
    }

    private var canAddSelectedMovie: Bool {
        selectedMovie != nil &&
        selectedQualityProfileId != nil &&
        selectedRootFolderPath != nil &&
        !isAdding &&
        selectedMovie.map { !isInLibrary($0) } == true
    }

    private var selectedQualityProfile: ArrQualityProfile? {
        guard let selectedQualityProfileId else { return nil }
        return viewModel.qualityProfiles.first { $0.id == selectedQualityProfileId }
    }

    private func performSearch() async {
        await viewModel.searchForNewMovies(term: searchQuery)
        if viewModel.searchResults.isEmpty {
            selectedMovie = nil
            optionsExpanded = false
        }
    }

    private func isInLibrary(_ movie: RadarrMovie) -> Bool {
        viewModel.movies.contains(where: { $0.tmdbId == movie.tmdbId })
    }

    private func addSelectedMovie() async {
        guard let selectedMovie else { return }
        await addMovie(selectedMovie)
    }

    @ViewBuilder
    private func movieSearchResultRow(for result: RadarrMovie) -> some View {
        let isSelected = selectedMovie?.id == result.id
        let existsInLibrary = isInLibrary(result)

        MovieSearchResultRow(
            movie: result,
            isSelected: isSelected,
            existsInLibrary: existsInLibrary,
            onSelect: {
                selectedMovie = result
                optionsExpanded = true
            }
        )
    }

    private func addMovie(_ movie: RadarrMovie) async {
        guard let tmdbId = movie.tmdbId,
              let qpId = selectedQualityProfileId,
              let rootPath = selectedRootFolderPath else { return }

        isAdding = true
        let success = await viewModel.addMovie(
            title: movie.title,
            tmdbId: tmdbId,
            qualityProfileId: qpId,
            rootFolderPath: rootPath,
            minimumAvailability: minimumAvailability,
            monitorOption: monitorOption,
            searchForMovie: searchForMovie
        )
        isAdding = false
        if success { dismiss() }
    }
}

private enum RadarrMinimumAvailabilityOption: String, CaseIterable, Identifiable {
    case announced
    case inCinemas
    case released
    case preDB = "preDB"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .announced: "Announced"
        case .inCinemas: "In Cinemas"
        case .released: "Released"
        case .preDB: "Predb"
        }
    }
}

private enum RadarrMonitorOption: String, CaseIterable, Identifiable {
    case movieOnly
    case movieAndCollection
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movieOnly: "Movie Only"
        case .movieAndCollection: "Movie and Collection"
        case .none: "None"
        }
    }
}

private struct MovieSearchResultRow: View {
    let movie: RadarrMovie
    let isSelected: Bool
    let existsInLibrary: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ArrArtworkView(url: movie.posterURL) {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let year = movie.year { Text(String(year)).font(.caption2) }
                        if let studio = movie.studio, !studio.isEmpty { Text("• \(studio)").font(.caption2) }
                        if let runtime = movie.runtime, runtime > 0 { Text("• \(runtime)m").font(.caption2) }
                    }
                    .foregroundStyle(.secondary)
                    if let overview = movie.overview {
                        Text(overview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                Spacer()

                if existsInLibrary {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
