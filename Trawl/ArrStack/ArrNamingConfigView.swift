import SwiftUI

struct ArrNamingConfigView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(ArrNamingBrowserState.self) private var sharedBrowser: ArrNamingBrowserState?

    /// Which *server* this screen is editing. Naming formats are per-server
    /// configuration and an HD/4K pair usually differs - the 4K server writes into
    /// a different folder tree - so "the Sonarr naming config" was never a single
    /// thing once a pair was configured.
    @State private var localBrowser = ArrNamingBrowserState()
    @State private var sheetFormatTarget: ArrNamingFormatEditorTarget?
    @State private var saveTask: Task<Void, Never>?
    @State private var showSettings = false

    private var browser: ArrNamingBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var selectedInstanceID: UUID? {
        get { browser.selectedInstanceID }
        nonmutating set { browser.selectedInstanceID = newValue }
    }

    private var selectedService: ArrServiceType {
        get { browser.selectedService }
        nonmutating set { browser.selectedService = newValue }
    }

    private var sonarrConfig: SonarrNamingConfig? {
        get { browser.sonarrConfig }
        nonmutating set { browser.sonarrConfig = newValue }
    }

    private var radarrConfig: RadarrNamingConfig? {
        get { browser.radarrConfig }
        nonmutating set { browser.radarrConfig = newValue }
    }

    private var isLoading: Bool {
        get { browser.isLoading }
        nonmutating set { browser.isLoading = newValue }
    }

    private var errorMessage: String? {
        get { browser.errorMessage }
        nonmutating set { browser.errorMessage = newValue }
    }

    private var isSaving: Bool {
        get { browser.isSaving }
        nonmutating set { browser.isSaving = newValue }
    }

    #if DEBUG
    init(
        previewSonarrConfig: SonarrNamingConfig? = .preview,
        previewRadarrConfig: RadarrNamingConfig? = .preview,
        selectedService: ArrServiceType = .sonarr,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        let browser = ArrNamingBrowserState()
        browser.sonarrConfig = previewSonarrConfig
        browser.radarrConfig = previewRadarrConfig
        browser.selectedService = selectedService
        browser.isLoading = isLoading
        browser.errorMessage = errorMessage
        _localBrowser = State(initialValue: browser)
    }
    #endif

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances.map(\.ref)
    }

    /// The server being edited. Falls back to the first connected one when the
    /// stored selection has been removed or filtered away.
    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private var isConnected: Bool {
        selectedInstance != nil
    }

    private var isSelectedConnecting: Bool {
        !isConnected && (serviceManager.isInitializing || serviceManager.isConnecting(selectedService))
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    var body: some View {
        TrawlListDetailPanes(title: "Naming") {
            namingScreen
        } detail: {
            selectedFormatDetail
        }
        .sheet(item: $sheetFormatTarget) { target in
            ArrNamingFormatEditorSheet(
                target: target,
                initialFormat: currentFormat(for: target),
                onSave: { newFormat in await applyFormat(newFormat, for: target) }
            )
        }
    }

    @ViewBuilder
    private var namingScreen: some View {
        @Bindable var browser = browser
        Group {
            if isSelectedConnecting || !isConnected {
                ArrServiceConnectionStatusView(
                    serviceType: selectedService,
                    title: isSelectedConnecting ? "Connecting to \(selectedService.displayName)" : "\(selectedService.displayName) Unreachable",
                    message: serviceManager.connectionError(selectedService) ?? "Check your server connection and try again."
                )
            } else if isLoading && sonarrConfig == nil && radarrConfig == nil {
                ProgressView("Loading naming settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ServiceErrorView(title: "Could Not Load Settings", message: error, onRetry: { await load() })
            } else if selectedService == .sonarr, let config = sonarrConfig {
                sonarrForm(config: config)
            } else if selectedService == .radarr, let config = radarrConfig {
                radarrForm(config: config)
            }
        }
        .moreDestinationBackground(selectedService == .sonarr ? .sonarrNaming : .radarrNaming)
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(instances: availableInstances, selection: $browser.selectedInstanceID)
        }
        .task(id: selectedInstance?.id) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await load()
        }
        .onAppear {
            selectedInstanceID = serviceManager.defaultScopeInstanceID(preferring: selectedInstanceID)
        }
        .onChange(of: selectedInstance?.serviceType) { _, newValue in
            // The form rendered depends on the service, and switching servers can
            // cross from Sonarr to Radarr.
            if let newValue { selectedService = newValue }
        }
        .onChange(of: selectedInstanceID) {
            browser.selectedFormatTarget = nil
            sheetFormatTarget = nil
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: selectedService)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            .macSheetSizing()
        }
    }

    @ViewBuilder
    private var selectedFormatDetail: some View {
        if let target = browser.selectedFormatTarget {
            ArrNamingFormatEditorSheet(
                target: target,
                initialFormat: currentFormat(for: target),
                onSave: { newFormat in await applyFormat(newFormat, for: target) }
            )
            .id(target.id)
        } else {
            listDetailPlaceholder("Select a Naming Format", systemImage: "character.cursor.ibeam")
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
            if showsDetailPane {
                browser.selectedFormatTarget = target
            } else {
                sheetFormatTarget = target
            }
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
        .accessibilityHint(showsDetailPane ? "Shows the token editor in the detail column" : "Opens the token editor")
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

    /// Returns whether the server accepted the format, so a detail-pane editor
    /// only leaves edit mode once the write has landed.
    private func applyFormat(_ newFormat: String, for target: ArrNamingFormatEditorTarget) async -> Bool {
        switch target {
        case .sonarr(let field):
            guard var config = sonarrConfig else { return false }
            field.setValue(newFormat, in: &config)
            sonarrConfig = config
            return await saveSonarr(config, successMessage: "\(field.rowTitle) format saved")
        case .radarr(let field):
            guard var config = radarrConfig else { return false }
            field.setValue(newFormat, in: &config)
            radarrConfig = config
            return await saveRadarr(config, successMessage: "\(field.rowTitle) format saved")
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let instance = selectedInstance else { return }
        selectedService = instance.serviceType
        do {
            switch instance.serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient(for: instance.id) else { return }
                sonarrConfig = try await client.getNamingConfig()
            case .radarr:
                guard let client = serviceManager.radarrClient(for: instance.id) else { return }
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

    @discardableResult
    private func saveSonarr(_ config: SonarrNamingConfig, successMessage: String? = nil) async -> Bool {
        // Saved back to the server the form was loaded from, not to whichever
        // Sonarr happens to be active.
        guard let instance = selectedInstance,
              let client = serviceManager.sonarrClient(for: instance.id) else { return false }
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
            return true
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            Task { await load() }
            return false
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

    @discardableResult
    private func saveRadarr(_ config: RadarrNamingConfig, successMessage: String? = nil) async -> Bool {
        guard let instance = selectedInstance,
              let client = serviceManager.radarrClient(for: instance.id) else { return false }
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
            return true
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            Task { await load() }
            return false
        }
    }
}

#if DEBUG
#Preview("Naming - Sonarr") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrNamingConfigView(selectedService: .sonarr)
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Naming - Radarr") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrNamingConfigView(selectedService: .radarr)
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Naming - Error") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrNamingConfigView(previewSonarrConfig: nil, previewRadarrConfig: nil, errorMessage: "Naming configuration could not be loaded.")
        }
        .environment(InAppNotificationCenter.shared)
    }
}
#endif
