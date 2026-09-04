import CoreTransferable
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A selectable backup provider in the segment bar. The Arr services and Jellyfin
/// have different capabilities (e.g. Jellyfin can't download, upload or delete), so
/// the view branches on this and hides unsupported actions - the same way Bazarr
/// already hides the upload button.
private enum BackupSource: Hashable, Sendable, Identifiable {
    /// One *server*, not one service. Each half of an HD/4K pair keeps its own
    /// backups, and restoring the wrong one would overwrite a working library
    /// with the other server's configuration.
    case arr(ArrInstanceRef)
    case jellyfin

    var id: String {
        switch self {
        case .arr(let instance): "arr.\(instance.id.uuidString)"
        case .jellyfin: "jellyfin"
        }
    }

    var displayName: String {
        switch self {
        case .arr(let instance): instance.serviceType.displayName
        case .jellyfin: "Jellyfin"
        }
    }

    var arrInstance: ArrInstanceRef? {
        if case .arr(let instance) = self { return instance }
        return nil
    }

    var arrService: ArrServiceType? { arrInstance?.serviceType }

    /// Sonarr/Radarr/Prowlarr accept uploaded archives; Bazarr and Jellyfin do not.
    var supportsUpload: Bool {
        switch self {
        case .arr(let instance): instance.serviceType != .bazarr
        case .jellyfin: false
        }
    }

    /// Jellyfin's backup API exposes no delete or download endpoints.
    var supportsDelete: Bool { arrInstance != nil }
    var supportsShare: Bool { arrInstance != nil }
}

struct ArrBackupsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]

    /// Nil until the first appear picks the first configured server; there is no
    /// sensible default before the manager knows what exists.
    @State private var selectedSource: BackupSource?
    @State private var states: [UUID: BackupViewState] = [:]
    @State private var unavailable: Set<UUID> = []
    @State private var jellyfinState = JellyfinBackupState()
    @State private var sortOrder: BackupSortOrder = .newestFirst
    @State private var showSettings = false
    @State private var sourcePendingBackupCreation: BackupSource?
    @State private var backupPendingDelete: PendingBackupDelete?
    @State private var backupPendingRestore: PendingBackupDelete?
    @State private var jellyfinPendingRestore: JellyfinBackupManifest?
    @State private var showingJellyfinCreateSheet = false
    @State private var preparingShareID: String?
    @State private var showingFilePicker = false

    #if DEBUG
    init(
        previewStates: [ArrServiceType: [ArrBackup]] = [:],
        jellyfinPreview: [JellyfinBackupManifest]? = nil,
        selectedService: ArrServiceType = .sonarr,
        selectJellyfin: Bool = false,
        error: String? = nil
    ) {
        _selectedSource = State(
            initialValue: selectJellyfin ? .jellyfin : .arr(.preview(selectedService))
        )
        _states = State(initialValue: Dictionary(
            uniqueKeysWithValues: previewStates.map { service, backups in
                (
                    ArrInstanceRef.preview(service).id,
                    BackupViewState(backups: backups, isLoading: false, isCreating: false, isUploading: false, error: error)
                )
            }
        ))
        if let jellyfinPreview {
            _jellyfinState = State(initialValue: JellyfinBackupState(backups: jellyfinPreview, isLoading: false, isCreating: false, error: error))
        }
    }
    #endif

    private struct BackupViewState {
        var backups: [ArrBackup] = []
        var isLoading = false
        var isCreating = false
        var isUploading = false
        var error: String?
    }

    private struct JellyfinBackupState {
        var backups: [JellyfinBackupManifest] = []
        var isLoading = false
        var isCreating = false
        var error: String?
    }

    /// Backup create/restore run synchronously on the server and can take minutes
    /// (metadata, trickplay, etc.), so they need a far longer budget than the
    /// default 30s request timeout.
    private static let jellyfinBackupRequestTimeout: TimeInterval = 600

    private struct PendingBackupDelete: Identifiable, Sendable {
        let backup: ArrBackup
        let instance: ArrInstanceRef

        var id: String { "\(instance.id.uuidString)-\(backup.id)" }
    }

    private enum BackupSortOrder: String, CaseIterable, Identifiable {
        case newestFirst = "Newest First"
        case oldestFirst = "Oldest First"
        case nameAscending = "Name A-Z"
        case nameDescending = "Name Z-A"
        case largestFirst = "Largest First"
        case smallestFirst = "Smallest First"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .newestFirst: "clock.arrow.circlepath"
            case .oldestFirst: "clock"
            case .nameAscending: "textformat.abc"
            case .nameDescending: "textformat.abc.dottedunderline"
            case .largestFirst: "arrow.down.to.line.compact"
            case .smallestFirst: "arrow.up.to.line.compact"
            }
        }
    }

    private var availableSources: [BackupSource] {
        var sources: [BackupSource] = []
        for serviceType in [ArrServiceType.sonarr, .radarr, .prowlarr, .bazarr] {
            sources += serviceManager.refs(for: serviceType).map { BackupSource.arr($0) }
        }
        if jellyfinSupportsBackups { sources.append(.jellyfin) }
        return sources
    }

    private var navigationSubtitleText: String {
        guard let selectedSource else { return "" }
        return sourceLabel(selectedSource)
    }

    private func sourceLabel(_ source: BackupSource) -> String {
        guard let instance = source.arrInstance else { return source.displayName }
        return serviceManager.scopeLabel(for: instance)
    }

    /// A Jellyfin server is configured if the manager has a profile in any state.
    private var jellyfinConfigured: Bool {
        jellyfinServiceManager.isConnected
            || jellyfinServiceManager.isConnecting
            || jellyfinServiceManager.connectionError != nil
            || jellyfinServiceManager.activeProfileID != nil
    }

    /// Built-in backups landed in Jellyfin 10.11. Hide the segment on servers we know
    /// to be older; stay optimistic when the version isn't known yet.
    private var jellyfinSupportsBackups: Bool {
        guard jellyfinConfigured else { return false }
        guard let version = jellyfinServiceManager.cachedSystemInfo?.version else { return true }
        return Self.versionSupportsBackups(version)
    }

    private static func versionSupportsBackups(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        if major != 10 { return major > 10 }
        return (parts.count > 1 ? parts[1] : 0) >= 11
    }

    var body: some View {
        Group {
            if availableSources.isEmpty {
                ServiceSetupView(title: "No Services Configured", message: "Add a Sonarr, Radarr, Prowlarr, Bazarr, or Jellyfin server in Settings to manage backups.", systemImage: "externaldrive.fill")
                .scrollableUnavailableState()
            } else {
                selectedContent
            }
        }
        .navigationTitle("Backups")
        .navigationSubtitle(navigationSubtitleText)
        .moreDestinationBackground(.backups)
        .toolbar { backupsToolbar }
        .alertsAndSheets(self)
    }

    /// The alert and sheet chain, lifted out of `body`.
    ///
    /// Nine stacked modifiers in one expression pushed the type checker past its
    /// budget once the backup payloads started carrying a server instead of a
    /// service. Splitting it costs nothing at runtime.
    fileprivate func alertsAndSheetsContent(_ content: some View) -> some View {
        content
        .alert("Create Backup?", isPresented: Binding(
            get: { sourcePendingBackupCreation != nil },
            set: { if !$0 { sourcePendingBackupCreation = nil } }
        )) {
            Button("Create Backup") {
                guard let source = sourcePendingBackupCreation else { return }
                sourcePendingBackupCreation = nil
                Task { await performCreate(for: source) }
            }
            Button("Cancel", role: .cancel) {
                sourcePendingBackupCreation = nil
            }
        } message: {
            if let source = sourcePendingBackupCreation {
                let name = sourceLabel(source)
                Text("Create a manual backup for \(name)?")
            }
        }
        .alert("Delete Backup?", isPresented: Binding(
            get: { backupPendingDelete != nil },
            set: { if !$0 { backupPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let backupPendingDelete else { return }
                self.backupPendingDelete = nil
                Task { await deleteBackup(backupPendingDelete) }
            }
            Button("Cancel", role: .cancel) {
                backupPendingDelete = nil
            }
        } message: {
            if let backupPendingDelete {
                let name = serviceManager.scopeLabel(for: backupPendingDelete.instance)
                Text("Delete \"\(backupPendingDelete.backup.name)\" from \(name)?")
            }
        }
        .alert("Restore Backup?", isPresented: Binding(
            get: { backupPendingRestore != nil },
            set: { if !$0 { backupPendingRestore = nil } }
        )) {
            Button("Restore", role: .destructive) {
                guard let backupPendingRestore else { return }
                self.backupPendingRestore = nil
                Task { await restoreBackup(backupPendingRestore) }
            }
            Button("Cancel", role: .cancel) {
                backupPendingRestore = nil
            }
        } message: {
            if let backupPendingRestore {
                let name = serviceManager.scopeLabel(for: backupPendingRestore.instance)
                let backupName = backupPendingRestore.backup.name
                Text("Restore \"\(backupName)\" to \(name)? That server may restart while the backup is applied.")
            }
        }
        .alert("Restore Backup?", isPresented: Binding(
            get: { jellyfinPendingRestore != nil },
            set: { if !$0 { jellyfinPendingRestore = nil } }
        )) {
            Button("Restore", role: .destructive) {
                guard let jellyfinPendingRestore else { return }
                self.jellyfinPendingRestore = nil
                Task { await restoreJellyfinBackup(jellyfinPendingRestore) }
            }
            Button("Cancel", role: .cancel) {
                jellyfinPendingRestore = nil
            }
        } message: {
            if let jellyfinPendingRestore {
                Text("Restore \"\(jellyfinPendingRestore.archiveFileName)\"? Jellyfin will restart to apply the backup.")
            }
        }
        .sheet(isPresented: $showingJellyfinCreateSheet) {
            JellyfinBackupOptionsSheet { options in
                Task { await createJellyfinBackup(options: options) }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.zip]
        ) { result in
            guard let instance = selectedSource?.arrInstance else { return }
            switch result {
            case .success(let url):
                Task { await uploadBackup(url: url, for: instance) }
            case .failure(let error):
                InAppNotificationCenter.shared.showError(
                    title: "File Selection Failed",
                    message: error.localizedDescription
                )
            }
        }
        .safeAreaInset(edge: .top) {
            if !availableSources.isEmpty {
                TrawlSegmentBar(
                    "Source",
                    selection: Binding(
                        get: { selectedSource },
                        set: { newSource in withAnimation { selectedSource = newSource } }
                    ),
                    // Labelled per server, so an HD/4K pair reads as two entries
                    // rather than one ambiguous "Sonarr".
                    items: availableSources.map {
                        TrawlSegmentBarItem(sourceLabel($0), value: Optional($0))
                    },
                    alignment: .leading
                )
            }
        }
        .loadServicesPeriodically(
            id: availableSources.map { source -> String in
                switch source {
                case .arr(let instance): instance.id.uuidString
                case .jellyfin: "jellyfin:\(jellyfinServiceManager.isConnected)"
                }
            }.joined(),
            keys: availableSources
        ) { source in
            await load(source)
        }
        .sheet(isPresented: $showSettings) {
            if let instance = selectedSource?.arrInstance {
                NavigationStack {
                    ArrServiceSettingsView(serviceType: instance.serviceType)
                        .environment(serviceManager)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
        }
        .onAppear {
            if selectedSource == nil || !availableSources.contains(selectedSource!) {
                selectedSource = availableSources.first
            }
        }
    }

    // MARK: - Content

    /// Type-erased so the content area keeps one stable structural identity as the
    /// source changes. A `switch` here would land on different `_ConditionalContent`
    /// branches for Arr vs Jellyfin, causing SwiftUI to re-host the toolbar fresh
    /// (items snap in/out). Erasing to `AnyView` keeps the toolbar host stable so
    /// the Upload button animates away on Arr→Jellyfin exactly as it does Arr→Bazarr.
    private var selectedContent: AnyView {
        switch selectedSource {
        case .arr(let instance): AnyView(arrContent(instance: instance))
        case .jellyfin: AnyView(jellyfinContent())
        case nil: AnyView(EmptyView())
        }
    }

    @ToolbarContentBuilder
    private var backupsToolbar: some ToolbarContent {
            if !availableSources.isEmpty {
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    Menu {
                        ForEach(BackupSortOrder.allCases) { order in
                            Button {
                                withAnimation {
                                    sortOrder = order
                                }
                            } label: {
                                if sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Label(order.rawValue, systemImage: order.systemImage)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: sortOrder.systemImage)
                    }
                    .disabled(selectedBackupsIsEmpty)

                    if selectedSource?.supportsUpload == true {
                        if selectedIsUploading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Upload Backup", systemImage: "arrow.up.doc") {
                                showingFilePicker = true
                            }
                        }
                    }

                    if selectedIsCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create Backup", systemImage: "externaldrive.badge.plus") {
                            switch selectedSource {
                            case .arr: sourcePendingBackupCreation = selectedSource
                            case .jellyfin: showingJellyfinCreateSheet = true
                            case nil: break
                            }
                        }
                    }
                }
            }
    }

    // MARK: - Arr Content

    @ViewBuilder
    private func arrContent(instance: ArrInstanceRef) -> some View {
        let service = instance.serviceType
        let label = serviceManager.scopeLabel(for: instance)
        if !serviceManager.isConnected(service, profileID: instance.id)
            && (serviceManager.isInitializing || serviceManager.isConnecting(service) || unavailable.contains(instance.id)) {
            ArrServiceConnectionStatusView(
                serviceType: service,
                title: serviceManager.isConnecting(service) || serviceManager.isInitializing ? "Connecting to \(label)" : "\(label) Unreachable",
                message: serviceManager.connectionError(service) ?? "\(label) is configured but currently unreachable."
            )
        } else if let state = states[instance.id] {
            backupList(state: state, instance: instance)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func backupList(state: BackupViewState, instance: ArrInstanceRef) -> some View {
        List {
            if let error = state.error {
                ServiceErrorView(
                    title: "Backups Unavailable",
                    message: error,
                    identity: instance.serviceType.serviceIdentity,
                    hasContent: !state.backups.isEmpty,
                    onRetry: { await loadService(instance) }
                )
            }

            if state.isLoading && state.backups.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if state.backups.isEmpty {
                if state.error == nil {
                    ContentUnavailableView(
                        "No Backups",
                        systemImage: "externaldrive",
                        description: Text("No backups found for \(serviceManager.scopeLabel(for: instance)).")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(sortedBackups(state.backups), id: \.id) { backup in
                        if let client = client(for: instance) {
                            let shareID = sharePreparationID(for: backup, instance: instance)
                            let shareItem = ArrBackupShareItem(backup: backup, instance: instance, client: client) { isPreparing in
                                setSharePreparation(isPreparing, for: shareID)
                            }
                            ShareLink(
                                item: shareItem,
                                preview: SharePreview(backup.name, icon: Image(systemName: "externaldrive"))
                            ) {
                                ArrBackupRow(
                                    backup: backup,
                                    instance: instance,
                                    isPreparingShare: preparingShareID == shareID
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded {
                                setSharePreparation(true, for: shareID)
                            })
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    backupPendingDelete = PendingBackupDelete(backup: backup, instance: instance)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    backupPendingRestore = PendingBackupDelete(backup: backup, instance: instance)
                                } label: {
                                    Label("Restore", systemImage: "arrow.counterclockwise")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                ShareLink(
                                    item: shareItem,
                                    preview: SharePreview(backup.name, icon: Image(systemName: "externaldrive"))
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button("Restore", systemImage: "arrow.counterclockwise") {
                                    backupPendingRestore = PendingBackupDelete(backup: backup, instance: instance)
                                }

                                Divider()

                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    backupPendingDelete = PendingBackupDelete(backup: backup, instance: instance)
                                }
                            }
                        } else {
                            ArrBackupRow(backup: backup, instance: instance)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await loadService(instance) }
        .animation(.default, value: sortedBackups(state.backups).map(\.id))
    }

    // MARK: - Jellyfin Content

    @ViewBuilder
    private func jellyfinContent() -> some View {
        if jellyfinServiceManager.isConnecting && !jellyfinServiceManager.isConnected {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !jellyfinServiceManager.isConnected {
            ServiceErrorView(
                title: "Jellyfin Unreachable",
                message: jellyfinServiceManager.connectionError ?? "Jellyfin is configured but currently unreachable.",
                identity: .jellyfin,
                onRetry: { await jellyfinServiceManager.initialize(from: jellyfinProfiles) }
            )
        } else {
            jellyfinBackupList()
        }
    }

    @ViewBuilder
    private func jellyfinBackupList() -> some View {
        List {
            if let error = jellyfinState.error {
                ServiceErrorView(
                    title: "Backups Unavailable",
                    message: error,
                    identity: .jellyfin,
                    hasContent: !jellyfinState.backups.isEmpty,
                    onRetry: { await loadJellyfin() }
                )
            }

            if jellyfinState.isLoading && jellyfinState.backups.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if jellyfinState.backups.isEmpty {
                if jellyfinState.error == nil {
                    ContentUnavailableView(
                        "No Backups",
                        systemImage: "externaldrive",
                        description: Text("No backups found for Jellyfin.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(sortedJellyfinBackups(jellyfinState.backups)) { backup in
                        JellyfinBackupRow(backup: backup)
                            .contentShape(Rectangle())
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    jellyfinPendingRestore = backup
                                } label: {
                                    Label("Restore", systemImage: "arrow.counterclockwise")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button("Restore", systemImage: "arrow.counterclockwise") {
                                    jellyfinPendingRestore = backup
                                }
                            }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await loadJellyfin() }
        .animation(.default, value: sortedJellyfinBackups(jellyfinState.backups).map(\.id))
    }

    // MARK: - Load

    @MainActor
    private func load(_ source: BackupSource) async {
        switch source {
        case .arr(let instance): await loadService(instance)
        case .jellyfin: await loadJellyfin()
        }
    }

    @MainActor
    private func loadService(_ instance: ArrInstanceRef) async {
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
        guard let client = client(for: instance) else { unavailable.insert(instance.id); return }
        unavailable.remove(instance.id)
        states[instance.id, default: BackupViewState()].isLoading = true
        states[instance.id]?.error = nil
        do {
            let backups = try await client.getBackups()
            withAnimation {
                states[instance.id, default: BackupViewState()].backups = backups
                states[instance.id]?.isLoading = false
            }
        } catch {
            states[instance.id]?.error = error.localizedDescription
            states[instance.id]?.isLoading = false
        }
    }

    @MainActor
    private func loadJellyfin() async {
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
        guard let client = jellyfinServiceManager.activeClient else { return }
        jellyfinState.isLoading = true
        jellyfinState.error = nil
        do {
            let backups = try await client.getBackups()
            withAnimation {
                jellyfinState.backups = backups
                jellyfinState.isLoading = false
            }
        } catch {
            jellyfinState.error = error.localizedDescription
            jellyfinState.isLoading = false
        }
    }

    @MainActor
    private func performCreate(for source: BackupSource) async {
        switch source {
        case .arr(let instance): await createBackup(for: instance)
        case .jellyfin: await createJellyfinBackup(options: JellyfinBackupOptions())
        }
    }

    @MainActor
    private func createBackup(for instance: ArrInstanceRef) async {
        guard let client = client(for: instance) else { return }
        states[instance.id]?.isCreating = true
        do {
            try await client.createBackup()
            try? await Task.sleep(for: .seconds(3))
            await loadService(instance)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Backup Failed",
                message: error.localizedDescription
            )
        }
        states[instance.id]?.isCreating = false
    }

    @MainActor
    private func createJellyfinBackup(options: JellyfinBackupOptions) async {
        guard let client = jellyfinServiceManager.activeClient else { return }
        jellyfinState.isCreating = true
        do {
            try await client.createBackup(options: options, requestTimeout: Self.jellyfinBackupRequestTimeout)
            try? await Task.sleep(for: .seconds(3))
            await loadJellyfin()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Backup Failed",
                message: error.localizedDescription
            )
        }
        jellyfinState.isCreating = false
    }

    @MainActor
    private func uploadBackup(url: URL, for instance: ArrInstanceRef) async {
        guard let client = client(for: instance) else { return }
        states[instance.id]?.isUploading = true
        do {
            let filename = url.lastPathComponent
            let data = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            try await client.uploadBackup(data: data, filename: filename)
            InAppNotificationCenter.shared.showSuccess(
                title: "Restore Started",
                message: "\(serviceManager.scopeLabel(for: instance)) is restoring from the uploaded backup."
            )
            try? await Task.sleep(for: .seconds(3))
            await loadService(instance)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Upload Failed",
                message: error.localizedDescription
            )
        }
        states[instance.id]?.isUploading = false
    }

    @MainActor
    private func restoreBackup(_ pendingRestore: PendingBackupDelete) async {
        guard let client = client(for: pendingRestore.instance) else { return }
        do {
            try await client.restoreBackup(pendingRestore.backup)
            InAppNotificationCenter.shared.showSuccess(
                title: "Restore Started",
                message: "\(serviceManager.scopeLabel(for: pendingRestore.instance)) is restoring \"\(pendingRestore.backup.name)\"."
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Restore Failed",
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func restoreJellyfinBackup(_ backup: JellyfinBackupManifest) async {
        guard let client = jellyfinServiceManager.activeClient else { return }
        do {
            try await client.restoreBackup(archiveFileName: backup.archiveFileName, requestTimeout: Self.jellyfinBackupRequestTimeout)
            InAppNotificationCenter.shared.showSuccess(
                title: "Restore Started",
                message: "Jellyfin is restoring \"\(backup.archiveFileName)\" and will restart."
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Restore Failed",
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func deleteBackup(_ pendingDelete: PendingBackupDelete) async {
        guard let client = client(for: pendingDelete.instance) else { return }
        do {
            try await client.deleteBackup(pendingDelete.backup)
            withAnimation {
                states[pendingDelete.instance.id]?.backups.removeAll { $0.id == pendingDelete.backup.id }
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Backup Deleted",
                message: "\"\(pendingDelete.backup.name)\" was removed from \(serviceManager.scopeLabel(for: pendingDelete.instance))."
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Delete Failed",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Sorting

    private var selectedBackupsIsEmpty: Bool {
        switch selectedSource {
        case .arr(let instance): states[instance.id]?.backups.isEmpty != false
        case nil: true
        case .jellyfin: jellyfinState.backups.isEmpty
        }
    }

    private var selectedIsCreating: Bool {
        switch selectedSource {
        case .arr(let instance): states[instance.id]?.isCreating == true
        case nil: false
        case .jellyfin: jellyfinState.isCreating
        }
    }

    private var selectedIsUploading: Bool {
        if case .arr(let instance) = selectedSource { return states[instance.id]?.isUploading == true }
        return false
    }

    private func sortedBackups(_ backups: [ArrBackup]) -> [ArrBackup] {
        backups.sorted { lhs, rhs in
            switch sortOrder {
            case .newestFirst:
                backupTime(lhs, isOrderedBefore: rhs, newestFirst: true)
            case .oldestFirst:
                backupTime(lhs, isOrderedBefore: rhs, newestFirst: false)
            case .nameAscending:
                backupName(lhs, isOrderedBefore: rhs, ascending: true)
            case .nameDescending:
                backupName(lhs, isOrderedBefore: rhs, ascending: false)
            case .largestFirst:
                backupSize(lhs, isOrderedBefore: rhs, largestFirst: true)
            case .smallestFirst:
                backupSize(lhs, isOrderedBefore: rhs, largestFirst: false)
            }
        }
    }

    private func backupTime(_ lhs: ArrBackup, isOrderedBefore rhs: ArrBackup, newestFirst: Bool) -> Bool {
        if let lhsDate = backupDate(lhs), let rhsDate = backupDate(rhs), lhsDate != rhsDate {
            return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
        }
        if lhs.time == rhs.time {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return newestFirst ? lhs.time > rhs.time : lhs.time < rhs.time
    }

    private func backupDate(_ backup: ArrBackup) -> Date? {
        Self.parseDate(backup.time)
    }

    private func backupName(_ lhs: ArrBackup, isOrderedBefore rhs: ArrBackup, ascending: Bool) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame {
            return backupTime(lhs, isOrderedBefore: rhs, newestFirst: true)
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func backupSize(_ lhs: ArrBackup, isOrderedBefore rhs: ArrBackup, largestFirst: Bool) -> Bool {
        let lhsSize = lhs.size ?? (largestFirst ? -1 : Int.max)
        let rhsSize = rhs.size ?? (largestFirst ? -1 : Int.max)
        if lhsSize == rhsSize {
            return backupTime(lhs, isOrderedBefore: rhs, newestFirst: true)
        }
        return largestFirst ? lhsSize > rhsSize : lhsSize < rhsSize
    }

    /// Jellyfin manifests carry no size, so size orders fall back to date.
    private func sortedJellyfinBackups(_ backups: [JellyfinBackupManifest]) -> [JellyfinBackupManifest] {
        backups.sorted { lhs, rhs in
            switch sortOrder {
            case .newestFirst, .largestFirst:
                jellyfinTime(lhs, isOrderedBefore: rhs, newestFirst: true)
            case .oldestFirst, .smallestFirst:
                jellyfinTime(lhs, isOrderedBefore: rhs, newestFirst: false)
            case .nameAscending:
                jellyfinName(lhs, isOrderedBefore: rhs, ascending: true)
            case .nameDescending:
                jellyfinName(lhs, isOrderedBefore: rhs, ascending: false)
            }
        }
    }

    private func jellyfinTime(_ lhs: JellyfinBackupManifest, isOrderedBefore rhs: JellyfinBackupManifest, newestFirst: Bool) -> Bool {
        let lhsDate = Self.parseDate(lhs.dateCreated)
        let rhsDate = Self.parseDate(rhs.dateCreated)
        if let lhsDate, let rhsDate, lhsDate != rhsDate {
            return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
        }
        return lhs.archiveFileName.localizedStandardCompare(rhs.archiveFileName) == .orderedAscending
    }

    private func jellyfinName(_ lhs: JellyfinBackupManifest, isOrderedBefore rhs: JellyfinBackupManifest, ascending: Bool) -> Bool {
        let comparison = lhs.archiveFileName.localizedStandardCompare(rhs.archiveFileName)
        if comparison == .orderedSame {
            return jellyfinTime(lhs, isOrderedBefore: rhs, newestFirst: true)
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    /// The client for one specific server - every backup read, create, upload,
    /// delete and restore on this screen goes through it.
    private func client(for instance: ArrInstanceRef) -> (any SharedArrClient)? {
        switch instance.serviceType {
        case .sonarr, .radarr, .prowlarr: serviceManager.sharedClient(for: instance)
        case .bazarr: serviceManager.activeBazarrEntry?.client
        }
    }

    private func sharePreparationID(for backup: ArrBackup, instance: ArrInstanceRef) -> String {
        "\(instance.id.uuidString)-\(backup.id)"
    }

    @MainActor
    private func setSharePreparation(_ isPreparing: Bool, for shareID: String) {
        withAnimation(.default) {
            if isPreparing {
                preparingShareID = shareID
            } else if preparingShareID == shareID {
                preparingShareID = nil
            }
        }
    }
}

private struct ArrBackupShareItem: Transferable, Sendable {
    let backup: ArrBackup
    let instance: ArrInstanceRef
    let client: any SharedArrClient
    let onPreparationChanged: @MainActor @Sendable (Bool) -> Void

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            await item.onPreparationChanged(true)
            do {
                let data = try await item.client.downloadBackup(item.backup)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TrawlBackupShare-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let fileURL = directory.appendingPathComponent(item.fileName)
                try data.write(to: fileURL, options: .atomic)
                await item.onPreparationChanged(false)
                return SentTransferredFile(fileURL)
            } catch {
                await item.onPreparationChanged(false)
                throw error
            }
        }
    }

    private var fileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleanedName = backup.name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = cleanedName.isEmpty ? "\(instance.serviceType.displayName)-Backup-\(backup.id)" : cleanedName
        return baseName.lowercased().hasSuffix(".zip") ? baseName : "\(baseName).zip"
    }
}

// MARK: - Backup Rows

private struct ArrBackupRow: View {
    let backup: ArrBackup
    let instance: ArrInstanceRef
    let isPreparingShare: Bool

    init(backup: ArrBackup, instance: ArrInstanceRef, isPreparingShare: Bool = false) {
        self.backup = backup
        self.instance = instance
        self.isPreparingShare = isPreparingShare
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: typeIcon)
                    .font(.caption2)
                    .foregroundStyle(typeColor)
                Text(typeLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let size = backup.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isPreparingShare {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Preparing backup share")
                }
            }
            Text(backup.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let date = formattedDate {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var typeLabel: String {
        switch backup.type.lowercased() {
        case "manual": "Manual"
        case "scheduled": "Scheduled"
        case "update": "Pre-Update"
        default: backup.type.capitalized
        }
    }

    private var typeIcon: String {
        switch backup.type.lowercased() {
        case "manual": "hand.tap"
        case "scheduled": "clock"
        case "update": "arrow.down.app"
        default: "externaldrive"
        }
    }

    private var typeColor: Color {
        switch backup.type.lowercased() {
        case "manual": instance.serviceType.serviceIdentity.brandColor
        case "scheduled": .teal
        case "update": .green
        default: .secondary
        }
    }

    private var formattedDate: String? {
        guard let date = ArrBackupsView.parseDate(backup.time) else { return backup.time }
        return date.formatted(date: .long, time: .shortened)
    }
}

private struct JellyfinBackupOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var options: JellyfinBackupOptions
    let onCreate: (JellyfinBackupOptions) -> Void

    init(options: JellyfinBackupOptions = JellyfinBackupOptions(), onCreate: @escaping (JellyfinBackupOptions) -> Void) {
        _options = State(initialValue: options)
        self.onCreate = onCreate
    }

    var body: some View {
        AppSheetShell(
            title: "Create Backup",
            subtitle: "Jellyfin",
            confirmTitle: "Create",
            onConfirm: {
                onCreate(options)
                dismiss()
            },
            detents: [.medium, .large]
        ) {
            Form {
                Section {
                    Toggle("Database", isOn: .constant(true))
                        .disabled(true)
                } footer: {
                    Text("The database is always included in a backup.")
                }

                Section {
                    Toggle("Metadata & Images", isOn: $options.metadata)
                    Toggle("Subtitles", isOn: $options.subtitles)
                    Toggle("Trickplay Images", isOn: $options.trickplay)
                } header: {
                    Text("Also Include")
                } footer: {
                    Text("These can significantly increase the backup's size and the time it takes to create. The server may be slow to respond while the backup runs.")
                }
            }
        }
    }
}

private struct JellyfinBackupRow: View {
    let backup: JellyfinBackupManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.caption2)
                    .foregroundStyle(.teal)
                Text(components)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let version = backup.serverVersion {
                    Text("Jellyfin \(version)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(backup.archiveFileName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let date = formattedDate {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var components: String {
        guard let options = backup.options else { return "Database" }
        var parts: [String] = []
        if options.database { parts.append("Database") }
        if options.metadata { parts.append("Metadata") }
        if options.subtitles { parts.append("Subtitles") }
        if options.trickplay { parts.append("Trickplay") }
        return parts.isEmpty ? "Database" : parts.joined(separator: " · ")
    }

    private var formattedDate: String? {
        guard let date = ArrBackupsView.parseDate(backup.dateCreated) else { return backup.dateCreated }
        return date.formatted(date: .long, time: .shortened)
    }
}

#if DEBUG
#Preview("Backups - Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBackupsView(previewStates: [.sonarr: ArrBackup.previewList, .radarr: ArrBackup.previewList], selectedService: .sonarr)
        }
    }
}

#Preview("Backups - Jellyfin") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured), jellyfin: .preview(.connected)) {
        NavigationStack {
            ArrBackupsView(jellyfinPreview: JellyfinBackupManifest.previewList, selectJellyfin: true)
        }
    }
}

#Preview("Backups - Empty") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBackupsView(previewStates: [.sonarr: []], selectedService: .sonarr)
        }
    }
}

#Preview("Backups - Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBackupsView(selectedService: .sonarr)
        }
    }
}

#Preview("Backups - Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBackupsView(
                previewStates: [.sonarr: []],
                selectedService: .sonarr,
                error: "Failed to fetch backups: The operation couldn't be completed."
            )
        }
    }
}

#Preview("Backups - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrBackupsView(selectedService: .sonarr)
        }
    }
}
#endif


private extension View {
    func alertsAndSheets(_ host: ArrBackupsView) -> some View {
        host.alertsAndSheetsContent(self)
    }
}
