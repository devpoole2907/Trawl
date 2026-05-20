import SwiftUI

struct ArrNamingConfigView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var sonarrConfig: SonarrNamingConfig?
    @State private var radarrConfig: RadarrNamingConfig?
    @State private var isLoading = true
    @State private var editingFormatTarget: ArrNamingFormatEditorTarget?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var isConnected: Bool {
        switch selectedService {
        case .sonarr: serviceManager.sonarrConnected
        case .radarr: serviceManager.radarrConnected
        case .prowlarr, .bazarr: false
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
            } else if !isConnected {
                ContentUnavailableView(
                    "\(selectedService.displayName) Unreachable",
                    systemImage: "network.slash",
                    description: Text("Check your server connection and try again.")
                )
            } else if selectedService == .sonarr, let config = sonarrConfig {
                sonarrForm(config: config)
            } else if selectedService == .radarr, let config = radarrConfig {
                radarrForm(config: config)
            }
        }
        .navigationTitle("Naming")
        .moreDestinationBackground(selectedService == .sonarr ? .sonarrNaming : .radarrNaming)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedService },
                    set: { newService in
                        withAnimation { selectedService = newService }
                    }
                ),
                items: availableServices.map(\.segmentBarItem),
                alignment: .center
            )
        }
        .sheet(item: $editingFormatTarget) { target in
            ArrNamingFormatEditorSheet(
                target: target,
                initialFormat: currentFormat(for: target),
                onSave: { newFormat in applyFormat(newFormat, for: target) }
            )
        }
        .task(id: selectedService.rawValue) {
            await load()
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    // MARK: - Sonarr form

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

            if config.standardEpisodeFormat != nil || config.dailyEpisodeFormat != nil || config.animeEpisodeFormat != nil {
                Section("Episode Formats") {
                    sonarrFormatRow(.standardEpisode, config: config)
                    sonarrFormatRow(.dailyEpisode, config: config)
                    sonarrFormatRow(.animeEpisode, config: config)
                }
            }

            if config.seriesFolderFormat != nil || config.seasonFolderFormat != nil || config.specialsFolderFormat != nil {
                Section("Folder Formats") {
                    sonarrFormatRow(.seriesFolder, config: config)
                    sonarrFormatRow(.seasonFolder, config: config)
                    sonarrFormatRow(.specialsFolder, config: config)
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .disabled(isSaving)
        .overlay(alignment: .top) {
            if isSaving { ProgressView().padding(8) }
        }
    }

    // MARK: - Radarr form

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

            if config.standardMovieFormat != nil || config.movieFolderFormat != nil {
                Section("Movie Formats") {
                    radarrFormatRow(.standardMovie, config: config)
                    radarrFormatRow(.movieFolder, config: config)
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .disabled(isSaving)
        .overlay(alignment: .top) {
            if isSaving { ProgressView().padding(8) }
        }
    }

    // MARK: - Shared row helpers

    @ViewBuilder
    private func sonarrFormatRow(_ field: ArrNamingSonarrFormatField, config: SonarrNamingConfig) -> some View {
        if let value = field.value(in: config) {
            formatEditorRow(field.rowTitle, value: value, target: .sonarr(field))
        }
    }

    @ViewBuilder
    private func radarrFormatRow(_ field: ArrNamingRadarrFormatField, config: RadarrNamingConfig) -> some View {
        if let value = field.value(in: config) {
            formatEditorRow(field.rowTitle, value: value, target: .radarr(field))
        }
    }

    private func formatEditorRow(_ label: String, value: String, target: ArrNamingFormatEditorTarget) -> some View {
        Button {
            editingFormatTarget = target
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(value.isEmpty ? "No format" : value)
                    .font(.caption.monospaced())
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(ArrNamingFormatPreview.preview(for: value, groups: target.tokenGroups))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the token editor")
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

    // MARK: - Format helpers

    private func currentFormat(for target: ArrNamingFormatEditorTarget) -> String {
        switch target {
        case .sonarr(let field):
            return sonarrConfig.map { field.value(in: $0) ?? "" } ?? ""
        case .radarr(let field):
            return radarrConfig.map { field.value(in: $0) ?? "" } ?? ""
        }
    }

    private func applyFormat(_ newFormat: String, for target: ArrNamingFormatEditorTarget) {
        switch target {
        case .sonarr(let field):
            guard var config = sonarrConfig else { return }
            field.setValue(newFormat, in: &config)
            sonarrConfig = config
            Task { await saveSonarr(config, successMessage: "\(field.rowTitle) format saved") }
        case .radarr(let field):
            guard var config = radarrConfig else { return }
            field.setValue(newFormat, in: &config)
            radarrConfig = config
            Task { await saveRadarr(config, successMessage: "\(field.rowTitle) format saved") }
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard isConnected else { return }
        do {
            switch selectedService {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                sonarrConfig = try await client.getNamingConfig()
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                radarrConfig = try await client.getNamingConfig()
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Live-save helpers for toggles and picker

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

        let existingTask = saveTask
        saveTask = Task {
            await existingTask?.value
            guard !Task.isCancelled else { return }
            await saveSonarr(config)
        }
    }

    private func saveSonarr(_ config: SonarrNamingConfig, successMessage: String? = nil) async {
        guard let client = serviceManager.sonarrClient else { return }
        isSaving = true
        defer {
            isSaving = false
            saveTask = nil
        }
        do {
            sonarrConfig = try await client.updateNamingConfig(config)
            if let successMessage {
                notificationCenter.showSuccess(title: "Naming Updated", message: successMessage)
            }
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

        let existingTask = saveTask
        saveTask = Task {
            await existingTask?.value
            guard !Task.isCancelled else { return }
            await saveRadarr(config)
        }
    }

    private func saveRadarr(_ config: RadarrNamingConfig, successMessage: String? = nil) async {
        guard let client = serviceManager.radarrClient else { return }
        isSaving = true
        defer {
            isSaving = false
            saveTask = nil
        }
        do {
            radarrConfig = try await client.updateNamingConfig(config)
            if let successMessage {
                notificationCenter.showSuccess(title: "Naming Updated", message: successMessage)
            }
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            Task { await load() }
        }
    }
}
