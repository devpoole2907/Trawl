import SwiftUI

struct BazarrMovieDetailView: View {
    let radarrId: Int
    @State var viewModel: BazarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var movie: BazarrMovie?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showProfilePicker = false
    @State private var selectedProfileId: Int?
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    var body: some View {
        Group {
            if isLoading && movie == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, movie == nil {
                ContentUnavailableView {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                contentView
            }
        }
        .navigationTitle(movie?.title ?? "Movie")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if movie != nil {
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    Menu {
                        ForEach(BazarrSeriesAction.allCases, id: \.self) { action in
                            Button {
                                Task { await performAction(action) }
                            } label: {
                                Label(action.displayName, systemImage: action.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await load() }
    }

    private var contentView: some View {
        List {
            if let movie {
                Section {
                    HStack(spacing: 16) {
                        ArrArtworkView(url: movie.poster.flatMap(URL.init(string:)), contentMode: .fill) {
                            Image(systemName: "film")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(movie.title)
                                .font(.title3.weight(.semibold))
                            if let year = movie.year {
                                Text(year)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let overview = movie.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }

                Section("Info") {
                    LabeledContent("Status", value: statusText)
                    if !movie.audioLanguages.isEmpty {
                        LabeledContent("Audio", value: movie.audioLanguages.map(\.name).joined(separator: ", "))
                    }
                    let profile = serviceManager.activeBazarrEntry?.languageProfiles.first { $0.profileId == movie.profileId }
                    Button {
                        selectedProfileId = movie.profileId
                        showProfilePicker = true
                    } label: {
                        LabeledContent("Language Profile", value: profile?.name ?? (movie.profileId == nil ? "None" : "Profile \(movie.profileId!)"))
                    }
                }

                if !movie.subtitles.isEmpty {
                    Section("Current Subtitles") {
                        ForEach(movie.subtitles, id: \.self) { sub in
                            subtitleRow(sub)
                                .swipeActions(edge: .trailing) {
                                    if sub.path != nil {
                                        Button(role: .destructive) {
                                            Task { await deleteSubtitle(sub) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }

                if !movie.missingSubtitles.isEmpty {
                    Section("Missing Languages") {
                        ForEach(movie.missingSubtitles, id: \.self) { lang in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(lang.name)
                                    if lang.hi || lang.forced {
                                        HStack(spacing: 4) {
                                            if lang.hi { Text("HI").font(.caption2).foregroundStyle(.blue) }
                                            if lang.forced { Text("Forced").font(.caption2).foregroundStyle(.orange) }
                                        }
                                    }
                                }
                                Spacer()
                                Button("Download") {
                                    Task { await downloadSubtitle(lang) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.teal)
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .sheet(isPresented: $showProfilePicker) {
            NavigationStack {
                let profiles = serviceManager.activeBazarrEntry?.languageProfiles ?? []
                List {
                    Picker("Profile", selection: $selectedProfileId) {
                        Text("None").tag(nil as Int?)
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(profile.profileId as Int?)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .navigationTitle("Language Profile")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            showProfilePicker = false
                            Task { await updateProfile() }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showProfilePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var statusText: String {
        guard let movie else { return "" }
        return movie.missingSubtitles.isEmpty ? "All Subtitles Present" : "\(movie.missingSubtitles.count) Language(s) Missing"
    }

    private func subtitleRow(_ sub: BazarrSubtitle) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(sub.name)
                    .font(.body)
                if let path = sub.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if sub.hi {
                Text("HI")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.15)))
            }
            if sub.forced {
                Text("Forced")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        error = nil
        let client = serviceManager.activeBazarrEntry?.client
        guard let client else {
            error = "No connected Bazarr instance"
            isLoading = false
            return
        }
        do {
            let page = try await client.getMovies(start: 0, length: 1, ids: [radarrId])
            movie = page.data.first
            if movie == nil {
                self.error = "Movie not found for id \(radarrId)"
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func performAction(_ action: BazarrSeriesAction) async {
        do {
            try await viewModel.runMovieAction(action, radarrId: radarrId)
            inAppNotificationCenter.showSuccess(title: "Action Started", message: "\(action.displayName) initiated for movie.")
        } catch {
            inAppNotificationCenter.showError(title: "Action Failed", message: error.localizedDescription)
        }
    }

    private func updateProfile() async {
        do {
            try await viewModel.setMovieProfile(radarrId: radarrId, profileId: selectedProfileId)
            await load()
            inAppNotificationCenter.showSuccess(title: "Updated", message: "Language profile updated.")
        } catch {
            inAppNotificationCenter.showError(title: "Failed", message: error.localizedDescription)
        }
    }

    private func downloadSubtitle(_ lang: BazarrSubtitleLanguage) async {
        do {
            try await viewModel.downloadMovieSubtitles(radarrId: radarrId, language: lang.code2, forced: lang.forced, hi: lang.hi)
            await load()
            inAppNotificationCenter.showSuccess(title: "Downloading", message: "\(lang.name) subtitles downloading...")
        } catch {
            inAppNotificationCenter.showError(title: "Download Failed", message: error.localizedDescription)
        }
    }

    private func deleteSubtitle(_ sub: BazarrSubtitle) async {
        guard let path = sub.path else { return }
        do {
            try await viewModel.deleteMovieSubtitles(radarrId: radarrId, language: sub.code2, forced: sub.forced, hi: sub.hi, path: path)
            await load()
            inAppNotificationCenter.showSuccess(title: "Deleted", message: "\(sub.name) subtitles removed.")
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}
