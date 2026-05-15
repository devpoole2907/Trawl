import SwiftUI

struct JellyfinLibrariesView: View {
    let apiClient: JellyfinAPIClient
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var folders: [JellyfinVirtualFolder] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var scanningAll = false
    @State private var showingAddLibrary = false
    @State private var pendingLibraryRemoval: JellyfinVirtualFolder?
    @State private var scanningLibraryID: String?

    private var browserSource: RemotePathBrowserSource {
        RemotePathBrowserSource(
            serviceName: "Jellyfin",
            loadRoots: {
                try await apiClient.getDrives().map(\.remotePathEntry)
            },
            loadChildren: { path in
                try await apiClient.getDirectoryContents(
                    path: path,
                    includeFiles: false,
                    includeDirectories: true
                ).map(\.remotePathEntry)
            }
        )
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && folders.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if folders.isEmpty {
                ContentUnavailableView(
                    "No Libraries",
                    systemImage: "folder",
                    description: Text("No media libraries were returned by Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(folders) { folder in
                        NavigationLink {
                            JellyfinLibraryDetailView(
                                folder: folder,
                                apiClient: apiClient,
                                browserSource: browserSource,
                                scanningLibraryID: $scanningLibraryID,
                                onChanged: { Task { await loadLibraries() } }
                            )
                        } label: {
                            libraryRow(folder)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                scanLibrary(folder)
                            } label: {
                                Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(.blue)
                            .disabled(scanningLibraryID == folder.itemId)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingLibraryRemoval = folder
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Locations are paths on the Jellyfin server or container.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .navigationTitle("Libraries")
        .refreshable { await loadLibraries() }
        .task { await loadLibraries() }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Menu {
                    Button {
                        showingAddLibrary = true
                    } label: {
                        Label("Add Library", systemImage: "plus")
                    }

                    Button {
                        Task { await scanAllLibraries() }
                    } label: {
                        Label("Scan All", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(scanningAll || folders.isEmpty)
                } label: {
                    if scanningAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Library Actions", systemImage: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddLibrary) {
            JellyfinAddLibrarySheet(source: browserSource) { name, type, paths in
                await addLibrary(name: name, collectionType: type, paths: paths)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .alert("Remove Library?", isPresented: Binding(
            get: { pendingLibraryRemoval != nil },
            set: { if !$0 { pendingLibraryRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let folder = pendingLibraryRemoval else { return }
                pendingLibraryRemoval = nil
                Task { await removeLibrary(folder) }
            }
            Button("Cancel", role: .cancel) {
                pendingLibraryRemoval = nil
            }
        } message: {
            if let folder = pendingLibraryRemoval {
                Text("Remove \"\(folder.name)\" from Jellyfin? Files and folders on disk will not be deleted.")
            }
        }
    }

    @ViewBuilder
    private func libraryRow(_ folder: JellyfinVirtualFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.collectionIcon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(folder.name)
                        .font(.body.weight(.medium))
                    if scanningLibraryID == folder.itemId {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text(folder.collectionTypeDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if scanningLibraryID != folder.itemId {
                Text("\(folder.locations.count) \(folder.locations.count == 1 ? "path" : "paths")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Material.regular, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func loadLibraries() async {
        isLoading = true
        errorMessage = nil
        do {
            folders = try await apiClient.getVirtualFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func addLibrary(name: String, collectionType: String, paths: [String]) async -> Bool {
        do {
            try await apiClient.addVirtualFolder(name: name, collectionType: collectionType, paths: paths)
            await loadLibraries()
            inAppNotificationCenter.showSuccess(title: "Library Added", message: name)
            return true
        } catch {
            inAppNotificationCenter.showError(title: "Add Failed", message: error.localizedDescription)
            return false
        }
    }

    private func removeLibrary(_ folder: JellyfinVirtualFolder) async {
        do {
            try await apiClient.removeVirtualFolder(name: folder.name)
            await loadLibraries()
            inAppNotificationCenter.showSuccess(title: "Library Removed", message: folder.name)
        } catch {
            inAppNotificationCenter.showError(title: "Remove Failed", message: error.localizedDescription)
        }
    }

    private func scanAllLibraries() async {
        scanningAll = true
        inAppNotificationCenter.showProgress(
            title: "Scanning All Libraries",
            message: "Triggering full library scan...",
            key: "jellyfin_scan_all",
            source: .inApp
        )
        do {
            try await apiClient.refreshAllLibraries()
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_scan_all",
                title: "Scan Started",
                message: "Full library scan has been triggered."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_scan_all",
                title: "Scan Failed",
                message: error.localizedDescription
            )
        }
        scanningAll = false
    }

    private func scanLibrary(_ folder: JellyfinVirtualFolder) {
        scanningLibraryID = folder.itemId
        inAppNotificationCenter.showProgress(
            title: "Scanning \(folder.name)",
            message: "Triggering library scan...",
            key: "jellyfin_scan_\(folder.itemId)",
            source: .inApp
        )
        Task {
            do {
                try await apiClient.refreshItem(id: folder.itemId)
                inAppNotificationCenter.replaceProgressWithSuccess(
                    key: "jellyfin_scan_\(folder.itemId)",
                    title: "Scan Started",
                    message: "Scan of \(folder.name) has been triggered."
                )
            } catch {
                inAppNotificationCenter.replaceProgressWithError(
                    key: "jellyfin_scan_\(folder.itemId)",
                    title: "Scan Failed",
                    message: error.localizedDescription
                )
            }
            scanningLibraryID = nil
        }
    }
}

// MARK: - Library Detail View

private struct JellyfinLibraryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    let folder: JellyfinVirtualFolder
    let apiClient: JellyfinAPIClient
    let browserSource: RemotePathBrowserSource
    @Binding var scanningLibraryID: String?
    let onChanged: () -> Void

    @State private var showingAddPath = false
    @State private var showingRename = false
    @State private var pendingPathRemoval: String?
    @State private var pendingLibraryRemoval = false

    private var isScanning: Bool {
        scanningLibraryID == folder.itemId
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: folder.name)
                LabeledContent("Type", value: folder.collectionTypeDisplayName)
            }

            Section {
                if folder.locations.isEmpty {
                    ContentUnavailableView(
                        "No Paths Configured",
                        systemImage: "folder.badge.plus",
                        description: Text("Add at least one filesystem path to this library.")
                    )
                } else {
                    ForEach(folder.locations, id: \.self) { location in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingPathRemoval = location
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Paths")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .navigationTitle(folder.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Menu {
                    Button {
                        Task { await scanLibrary() }
                    } label: {
                        Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        showingAddPath = true
                    } label: {
                        Label("Add Path", systemImage: "folder.badge.plus")
                    }

                    Button {
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        pendingLibraryRemoval = true
                    } label: {
                        Label("Remove Library", systemImage: "trash")
                    }
                } label: {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .accessibilityLabel("Library Actions")
            }
        }
        .sheet(isPresented: $showingAddPath) {
            JellyfinAddPathSheet(folder: folder, source: browserSource) { path in
                await addPath(path)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .sheet(isPresented: $showingRename) {
            JellyfinRenameLibrarySheet(folder: folder) { newName in
                await renameLibrary(newName)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .alert("Remove Path?", isPresented: Binding(
            get: { pendingPathRemoval != nil },
            set: { if !$0 { pendingPathRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let path = pendingPathRemoval else { return }
                pendingPathRemoval = nil
                Task { await removePath(path) }
            }
            Button("Cancel", role: .cancel) {
                pendingPathRemoval = nil
            }
        } message: {
            if let path = pendingPathRemoval {
                Text("Remove \"\(path)\" from this library? Files on disk will not be deleted.")
            }
        }
        .alert("Remove Library?", isPresented: $pendingLibraryRemoval) {
            Button("Remove", role: .destructive) {
                Task { await removeLibrary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \"\(folder.name)\" from Jellyfin? Files and folders on disk will not be deleted.")
        }
    }

    private func addPath(_ path: String) async -> Bool {
        do {
            try await apiClient.addMediaPath(libraryName: folder.name, path: path)
            onChanged()
            inAppNotificationCenter.showSuccess(title: "Path Added", message: path)
            return true
        } catch {
            inAppNotificationCenter.showError(title: "Add Path Failed", message: error.localizedDescription)
            return false
        }
    }

    private func removePath(_ path: String) async {
        do {
            try await apiClient.removeMediaPath(libraryName: folder.name, path: path)
            onChanged()
            inAppNotificationCenter.showSuccess(title: "Path Removed", message: path)
        } catch {
            inAppNotificationCenter.showError(title: "Remove Failed", message: error.localizedDescription)
        }
    }

    private func renameLibrary(_ newName: String) async -> Bool {
        do {
            try await apiClient.renameVirtualFolder(name: folder.name, newName: newName)
            onChanged()
            inAppNotificationCenter.showSuccess(title: "Library Renamed", message: newName)
            return true
        } catch {
            inAppNotificationCenter.showError(title: "Rename Failed", message: error.localizedDescription)
            return false
        }
    }

    private func removeLibrary() async {
        do {
            try await apiClient.removeVirtualFolder(name: folder.name)
            onChanged()
            inAppNotificationCenter.showSuccess(title: "Library Removed", message: folder.name)
            dismiss()
        } catch {
            inAppNotificationCenter.showError(title: "Remove Failed", message: error.localizedDescription)
        }
    }

    private func scanLibrary() async {
        scanningLibraryID = folder.itemId
        inAppNotificationCenter.showProgress(
            title: "Scanning \(folder.name)",
            message: "Triggering library scan...",
            key: "jellyfin_scan_\(folder.itemId)",
            source: .inApp
        )
        do {
            try await apiClient.refreshItem(id: folder.itemId)
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_scan_\(folder.itemId)",
                title: "Scan Started",
                message: "Scan of \(folder.name) has been triggered."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_scan_\(folder.itemId)",
                title: "Scan Failed",
                message: error.localizedDescription
            )
        }
        scanningLibraryID = nil
    }
}

// MARK: - Add Library Sheet

private struct JellyfinAddLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: RemotePathBrowserSource
    let onAdd: (String, String, [String]) async -> Bool

    @State private var name = ""
    @State private var selectedContentType = JellyfinLibraryContentType.movies
    @State private var paths: [String] = []
    @State private var manualPath = ""
    @State private var showingBrowser = false
    @State private var isSaving = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !paths.isEmpty && !isSaving
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        AppSheetShell(
            title: "Add Library",
            confirmTitle: "Add",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { save() }
        ) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Movies", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Content Type") {
                        Picker("Content Type", selection: $selectedContentType) {
                            ForEach(JellyfinLibraryContentType.appCases) { type in
                                Label(type.displayName, systemImage: type.systemImage).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                } header: {
                    Text("Details")
                }

                Section {
                    ForEach(paths, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                    }
                    .onDelete { offsets in
                        paths.remove(atOffsets: offsets)
                    }

                    HStack {
                        TextField("/media/movies", text: $manualPath)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Button {
                            addManualPath()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button {
                        showingBrowser = true
                    } label: {
                        Label("Browse Jellyfin Folders", systemImage: "folder")
                    }
                } header: {
                    Text("Paths")
                } footer: {
                    Text("Paths are on the Jellyfin server or container.")
                }
            }
            .sheet(isPresented: $showingBrowser) {
                NavigationStack {
                    RemotePathBrowserView(title: "Jellyfin Folders", source: source, initialPath: manualPath) { path in
                        appendPath(path)
                    }
                }
            }
        }
    }

    private func addManualPath() {
        appendPath(manualPath)
        manualPath = ""
    }

    private func appendPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !paths.contains(trimmed) else { return }
        paths.append(trimmed)
    }

    private func save() {
        guard !trimmedName.isEmpty, !paths.isEmpty else { return }
        isSaving = true
        Task {
            let success = await onAdd(trimmedName, selectedContentType.rawValue, paths)
            isSaving = false
            if success { dismiss() }
        }
    }
}

// MARK: - Add Path Sheet

private struct JellyfinAddPathSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folder: JellyfinVirtualFolder
    let source: RemotePathBrowserSource
    let onAdd: (String) async -> Bool

    @State private var path = ""
    @State private var showingBrowser = false
    @State private var isSaving = false

    private var canSave: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        AppSheetShell(
            title: "Add Path to \(folder.name)",
            confirmTitle: "Add",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { save() }
        ) {
            Form {
                Section {
                    LabeledContent("Path") {
                        TextField("/media/movies", text: $path)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    Button {
                        showingBrowser = true
                    } label: {
                        Label("Browse Jellyfin Folders", systemImage: "folder")
                    }
                } footer: {
                    Text("Path is on the Jellyfin server or container.")
                }
            }
            .sheet(isPresented: $showingBrowser) {
                NavigationStack {
                    RemotePathBrowserView(title: "Jellyfin Folders", source: source, initialPath: path) { selectedPath in
                        path = selectedPath
                    }
                }
            }
        }
    }

    private func save() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            let success = await onAdd(trimmed)
            isSaving = false
            if success { dismiss() }
        }
    }
}

// MARK: - Rename Library Sheet

private struct JellyfinRenameLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss

    let folder: JellyfinVirtualFolder
    let onSave: (String) async -> Bool

    @State private var name: String
    @State private var isSaving = false

    init(folder: JellyfinVirtualFolder, onSave: @escaping (String) async -> Bool) {
        self.folder = folder
        self.onSave = onSave
        _name = State(initialValue: folder.name)
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != folder.name && !isSaving
    }

    var body: some View {
        AppSheetShell(
            title: "Rename \(folder.name)",
            confirmTitle: "Save",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { save() },
            detents: [.medium]
        ) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Library Name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            let success = await onSave(trimmed)
            isSaving = false
            if success { dismiss() }
        }
    }
}

// MARK: - Content Type

private enum JellyfinLibraryContentType: String, CaseIterable, Identifiable {
    case movies
    case tvshows
    case mixed

    var id: String { rawValue }

    static var appCases: [JellyfinLibraryContentType] {
        [.movies, .tvshows, .mixed]
    }

    var displayName: String {
        switch self {
        case .movies: "Movies"
        case .tvshows: "TV Shows"
        case .mixed: "Mixed"
        }
    }

    var systemImage: String {
        switch self {
        case .movies: "film"
        case .tvshows: "tv"
        case .mixed: "square.grid.2x2"
        }
    }
}

private extension JellyfinVirtualFolder {
    var collectionTypeDisplayName: String {
        guard let type = collectionType else { return "Library" }
        return JellyfinLibraryContentType(rawValue: type)?.displayName ?? type
    }
}
