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
    /// The builder pushed at compact width. Wider layouts select into the detail column.
    @State private var compactTarget: ArrNamingFormatEditorTarget?
    @State private var saveTask: Task<Void, Never>?
    @State private var showSettings = false

    /// A selection or server change waiting on the unsaved-changes question.
    @State private var pendingChange: PendingChange?
    @State private var guardedSession: ArrNamingEditorSession?
    @State private var showUnsavedChanges = false

    private enum PendingChange {
        case select(ArrNamingFormatEditorTarget)
        case server(UUID?)
    }

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

    /// The loaded configs still belong to the server that was selected before a
    /// switch. Their rows must not be offered under the new server's scope, where a
    /// tap would open that server's draft seeded with the other server's format.
    private var isShowingStaleServer: Bool {
        guard let loaded = browser.loadedInstanceID else { return false }
        return loaded != selectedInstance?.id
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    var body: some View {
        TrawlListDetailPanes(title: "Naming") {
            namingScreen
        } detail: {
            selectedFormatDetail
        }
    }

    @ViewBuilder
    private var namingScreen: some View {
        Group {
            if isSelectedConnecting || !isConnected {
                ArrServiceConnectionStatusView(
                    serviceType: selectedService,
                    title: isSelectedConnecting ? "Connecting to \(selectedService.displayName)" : "\(selectedService.displayName) Unreachable",
                    message: serviceManager.connectionError(selectedService) ?? "Check your server connection and try again."
                )
            } else if let error = errorMessage {
                ServiceErrorView(title: "Could Not Load Settings", message: error, onRetry: { await load() })
            } else if (isLoading && sonarrConfig == nil && radarrConfig == nil) || isShowingStaleServer {
                ProgressView("Loading naming settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedService == .sonarr, let config = sonarrConfig {
                sonarrForm(config: config)
            } else if selectedService == .radarr, let config = radarrConfig {
                radarrForm(config: config)
            }
        }
        .moreDestinationBackground(selectedService == .sonarr ? .sonarrNaming : .radarrNaming)
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(
                instances: availableInstances,
                selection: Binding(
                    get: { browser.selectedInstanceID },
                    set: { requestServerChange(to: $0) }
                )
            )
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
            compactTarget = nil
        }
        .navigationDestination(item: $compactTarget) { target in
            if let session = session(for: target) {
                builder(for: session)
            }
        }
        .namingUnsavedChangesDialog(
            for: guardedSession,
            isPresented: $showUnsavedChanges,
            onSave: saveGuardedSessionAndContinue,
            onDiscard: discardGuardedSessionAndContinue
        )
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
        if let target = browser.selectedFormatTarget, let session = session(for: target) {
            builder(for: session)
                .id(session.id)
        } else {
            listDetailPlaceholder("Select a Naming Format", systemImage: "character.cursor.ibeam")
        }
    }

    private func builder(for session: ArrNamingEditorSession) -> some View {
        ArrNamingBuilderView(session: session) { format in
            await saveFormat(format, for: session.scope)
        }
        .onChange(of: currentFormat(for: session.target)) { _, serverFormat in
            // An untouched draft follows a value reloaded underneath it; one with
            // edits keeps measuring against what the person started from.
            if browser.loadedInstanceID == session.scope.instanceID {
                session.refreshBaseline(serverFormat)
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

    /// A format's familiar name and what it produces, rather than its token syntax.
    private func formatEditorRow(_ label: String, value: String, target: ArrNamingFormatEditorTarget) -> some View {
        let hasDraft = session(for: target)?.isDirty ?? false
        return Button {
            open(target)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if hasDraft {
                        Text("Edited")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(example(for: value, target: target))
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
        .accessibilityHint(showsDetailPane ? "Shows the format builder in the detail column" : "Opens the format builder")
    }

    private func example(for value: String, target: ArrNamingFormatEditorTarget) -> String {
        guard !value.isEmpty else { return "No format" }
        let catalog = ArrNamingBlockCatalog(target: target)
        return catalog.render(value).text + (catalog.previewFileExtension ?? "")
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

    // MARK: - Opening and leaving drafts

    private func scope(for target: ArrNamingFormatEditorTarget) -> ArrNamingEditorScope? {
        selectedInstance.map { ArrNamingEditorScope(instanceID: $0.id, target: target) }
    }

    private func session(for target: ArrNamingFormatEditorTarget) -> ArrNamingEditorSession? {
        scope(for: target).flatMap(browser.editorSession(for:))
    }

    private func open(_ target: ArrNamingFormatEditorTarget) {
        if showsDetailPane {
            guard browser.selectedFormatTarget != target else { return }
            if let current = browser.selectedFormatTarget, let session = session(for: current), session.isDirty {
                ask(before: .select(target), leaving: session)
                return
            }
        }
        apply(.select(target))
    }

    private func requestServerChange(to instanceID: UUID?) {
        guard instanceID != selectedInstance?.id else { return }
        if let session = browser.dirtySession(on: selectedInstance?.id) {
            ask(before: .server(instanceID), leaving: session)
            return
        }
        apply(.server(instanceID))
    }

    private func ask(before change: PendingChange, leaving session: ArrNamingEditorSession) {
        pendingChange = change
        guardedSession = session
        showUnsavedChanges = true
    }

    private func apply(_ change: PendingChange) {
        switch change {
        case .select(let target):
            guard let instance = selectedInstance, let scope = scope(for: target) else { return }
            browser.openEditorSession(
                for: scope,
                serverName: ArrInstanceScopeBar.label(for: instance, in: serviceManager),
                serverFormat: currentFormat(for: target)
            )
            if showsDetailPane {
                browser.selectedFormatTarget = target
            } else {
                compactTarget = target
            }
        case .server(let instanceID):
            withAnimation { selectedInstanceID = instanceID }
        }
    }

    /// Nothing changes until the server accepts the draft. A refusal leaves the
    /// selection, the server and the draft exactly where they were.
    private func saveGuardedSessionAndContinue() {
        guard let session = guardedSession, let change = pendingChange else { return }
        Task {
            let saved = await session.save { format in
                await saveFormat(format, for: session.scope)
            }
            if saved { apply(change) }
            pendingChange = nil
            guardedSession = nil
        }
    }

    private func discardGuardedSessionAndContinue() {
        guardedSession?.discardChanges()
        if let change = pendingChange { apply(change) }
        pendingChange = nil
        guardedSession = nil
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

    /// Writes one format to the server that owns the draft - captured in its scope,
    /// never whichever server is selected by the time this runs - and returns the
    /// value that server accepted, or nil when it refused.
    ///
    /// The body is that server's whole naming config with only this field changed,
    /// so file handling and the other formats go back exactly as the server had them.
    private func saveFormat(_ format: String, for scope: ArrNamingEditorScope) async -> String? {
        // A file-handling change still being written is part of the config this
        // write is built from, so it lands first.
        await saveTask?.value
        let serverName = availableInstances.first { $0.id == scope.instanceID }
            .map { ArrInstanceScopeBar.label(for: $0, in: serviceManager) } ?? scope.target.serviceType.displayName

        isSaving = true
        defer { isSaving = false }
        do {
            switch scope.target {
            case .sonarr(let field):
                guard let client = serviceManager.sonarrClient(for: scope.instanceID) else { return nil }
                var config: SonarrNamingConfig? = browser.loadedInstanceID == scope.instanceID ? sonarrConfig : nil
                if config == nil { config = try await client.getNamingConfig() }
                guard var config else { return nil }
                field.setValue(format, in: &config)
                let accepted = try await client.updateNamingConfig(config)
                if browser.loadedInstanceID == scope.instanceID { sonarrConfig = accepted }
                notificationCenter.showSuccess(title: "Naming Updated", message: "\(field.rowTitle) format saved to \(serverName)")
                return field.value(in: accepted) ?? format
            case .radarr(let field):
                guard let client = serviceManager.radarrClient(for: scope.instanceID) else { return nil }
                var config: RadarrNamingConfig? = browser.loadedInstanceID == scope.instanceID ? radarrConfig : nil
                if config == nil { config = try await client.getNamingConfig() }
                guard var config else { return nil }
                field.setValue(format, in: &config)
                let accepted = try await client.updateNamingConfig(config)
                if browser.loadedInstanceID == scope.instanceID { radarrConfig = accepted }
                notificationCenter.showSuccess(title: "Naming Updated", message: "\(field.rowTitle) format saved to \(serverName)")
                return field.value(in: accepted) ?? format
            }
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            return nil
        }
    }

    // MARK: - Data

    private func load() async {
        guard let instance = selectedInstance else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        selectedService = instance.serviceType
        // A response for a server that is no longer selected is dropped whole: it
        // must not replace the newly selected server's list, error or spinner.
        defer {
            if selectedInstance?.id == instance.id { isLoading = false }
        }
        do {
            switch instance.serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient(for: instance.id) else { return }
                let config: SonarrNamingConfig = try await client.getNamingConfig()
                guard selectedInstance?.id == instance.id else { return }
                sonarrConfig = config
                browser.loadedInstanceID = instance.id
            case .radarr:
                guard let client = serviceManager.radarrClient(for: instance.id) else { return }
                let config: RadarrNamingConfig = try await client.getNamingConfig()
                guard selectedInstance?.id == instance.id else { return }
                radarrConfig = config
                browser.loadedInstanceID = instance.id
            case .prowlarr, .bazarr:
                break
            }
        } catch {
            guard selectedInstance?.id == instance.id else { return }
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

    private func saveSonarr(_ config: SonarrNamingConfig) async {
        // Saved back to the server the form was loaded from, not to whichever
        // Sonarr happens to be active.
        guard let instance = selectedInstance,
              let client = serviceManager.sonarrClient(for: instance.id) else { return }
        isSaving = true
        defer {
            isSaving = false
            saveTask = nil
        }
        do {
            let accepted = try await client.updateNamingConfig(config)
            if browser.loadedInstanceID == instance.id { sonarrConfig = accepted }
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

    private func saveRadarr(_ config: RadarrNamingConfig) async {
        guard let instance = selectedInstance,
              let client = serviceManager.radarrClient(for: instance.id) else { return }
        isSaving = true
        defer {
            isSaving = false
            saveTask = nil
        }
        do {
            let accepted = try await client.updateNamingConfig(config)
            if browser.loadedInstanceID == instance.id { radarrConfig = accepted }
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            Task { await load() }
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
