import SwiftUI

struct ArrNamingConfigView: View {
    let serviceType: ArrServiceType

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var sonarrConfig: SonarrNamingConfig?
    @State private var radarrConfig: RadarrNamingConfig?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var isConnected: Bool {
        switch serviceType {
        case .sonarr: serviceManager.sonarrConnected
        case .radarr: serviceManager.radarrConnected
        case .prowlarr: false
        }
    }

    var body: some View {
        Group {
            if isLoading && sonarrConfig == nil && radarrConfig == nil {
                ProgressView("Loading naming settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "Could Not Load Settings",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if serviceType == .sonarr, let config = sonarrConfig {
                sonarrForm(config: config)
            } else if serviceType == .radarr, let config = radarrConfig {
                radarrForm(config: config)
            } else if !isConnected {
                ContentUnavailableView(
                    "\(serviceType.displayName) Unreachable",
                    systemImage: "network.slash",
                    description: Text("Check your server connection and try again.")
                )
            }
        }
        .navigationTitle("Naming")
        .moreDestinationBackground(serviceType == .sonarr ? .sonarrNaming : .radarrNaming)
        .task {
            await load()
        }
    }

    @ViewBuilder
    private func sonarrForm(config: SonarrNamingConfig) -> some View {
        Form {
            Section {
                Toggle("Rename Episodes", isOn: Binding(
                    get: { config.renameEpisodes ?? false },
                    set: { updateSonarr(renameEpisodes: $0) }
                ))
                Toggle("Replace Illegal Characters", isOn: Binding(
                    get: { config.replaceIllegalCharacters ?? true },
                    set: { updateSonarr(replaceIllegalCharacters: $0) }
                ))
                colonPicker(current: config.colonReplacementFormat) { updateSonarr(colonFormat: $0) }
            } header: {
                Text("File Handling")
            } footer: {
                Text("When renaming is off, Sonarr imports files using their original names.")
            }

            if let format = config.standardEpisodeFormat, !format.isEmpty {
                formatsSection(
                    title: "Episode Formats",
                    rows: [
                        ("Standard", config.standardEpisodeFormat),
                        ("Daily", config.dailyEpisodeFormat),
                        ("Anime", config.animeEpisodeFormat)
                    ]
                )
            }

            if let seriesFolder = config.seriesFolderFormat, !seriesFolder.isEmpty {
                formatsSection(
                    title: "Folder Formats",
                    rows: [
                        ("Series", config.seriesFolderFormat),
                        ("Season", config.seasonFolderFormat),
                        ("Specials", config.specialsFolderFormat)
                    ]
                )
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .disabled(isSaving)
        .overlay(alignment: .top) {
            if isSaving {
                ProgressView()
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func radarrForm(config: RadarrNamingConfig) -> some View {
        Form {
            Section {
                Toggle("Rename Movies", isOn: Binding(
                    get: { config.renameMovies ?? false },
                    set: { updateRadarr(renameMovies: $0) }
                ))
                Toggle("Replace Illegal Characters", isOn: Binding(
                    get: { config.replaceIllegalCharacters ?? true },
                    set: { updateRadarr(replaceIllegalCharacters: $0) }
                ))
                colonPicker(current: config.colonReplacementFormat) { updateRadarr(colonFormat: $0) }
            } header: {
                Text("File Handling")
            } footer: {
                Text("When renaming is off, Radarr imports files using their original names.")
            }

            if let format = config.standardMovieFormat, !format.isEmpty {
                formatsSection(
                    title: "Movie Formats",
                    rows: [
                        ("Standard", config.standardMovieFormat),
                        ("Folder", config.movieFolderFormat)
                    ]
                )
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .disabled(isSaving)
        .overlay(alignment: .top) {
            if isSaving {
                ProgressView()
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func colonPicker(current: Int?, onChange: @escaping (Int) -> Void) -> some View {
        let binding = Binding<Int>(
            get: { current ?? 0 },
            set: { onChange($0) }
        )
        Picker("Colon Replacement", selection: binding) {
            ForEach(ArrColonReplacementFormat.allCases) { format in
                Text(format.displayName).tag(format.rawValue)
            }
        }
    }

    @ViewBuilder
    private func formatsSection(title: String, rows: [(String, String?)]) -> some View {
        Section {
            ForEach(rows.filter { $0.1?.isEmpty == false }, id: \.0) { label, format in
                if let format {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(format)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text("Format strings are read-only. Edit them in the \(serviceType.displayName) web interface.")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard isConnected else { return }
        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                sonarrConfig = try await client.getNamingConfig()
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                radarrConfig = try await client.getNamingConfig()
            case .prowlarr:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateSonarr(
        renameEpisodes: Bool? = nil,
        replaceIllegalCharacters: Bool? = nil,
        colonFormat: Int? = nil
    ) {
        guard var config = sonarrConfig else { return }
        if let v = renameEpisodes { config.renameEpisodes = v }
        if let v = replaceIllegalCharacters { config.replaceIllegalCharacters = v }
        if let v = colonFormat { config.colonReplacementFormat = v }
        sonarrConfig = config
        Task { await saveSonarr(config) }
    }

    private func saveSonarr(_ config: SonarrNamingConfig) async {
        guard let client = serviceManager.sonarrClient else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            sonarrConfig = try await client.updateNamingConfig(config)
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            Task { await load() }
        }
    }

    private func updateRadarr(
        renameMovies: Bool? = nil,
        replaceIllegalCharacters: Bool? = nil,
        colonFormat: Int? = nil
    ) {
        guard var config = radarrConfig else { return }
        if let v = renameMovies { config.renameMovies = v }
        if let v = replaceIllegalCharacters { config.replaceIllegalCharacters = v }
        if let v = colonFormat { config.colonReplacementFormat = v }
        radarrConfig = config
        Task { await saveRadarr(config) }
    }

    private func saveRadarr(_ config: RadarrNamingConfig) async {
        guard let client = serviceManager.radarrClient else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            radarrConfig = try await client.updateNamingConfig(config)
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            Task { await load() }
        }
    }
}
