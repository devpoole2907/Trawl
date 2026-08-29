import SwiftUI

struct ArrRootFoldersView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var showingAddSheet = false
    @State private var pendingDelete: (folder: ArrRootFolder, instance: ArrInstanceRef)?
    @State private var isDeleting = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if !hasAnyService {
                ContentUnavailableView {
                    Label("No Services Configured", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Connect Sonarr or Radarr to view root folders.")
                } actions: {
                    MoreSettingsNavigationLink()
                }
                .scrollableUnavailableState()
            } else if !hasAnyConnectedService {
                ArrServicesConnectionStatusView(
                    services: rootFolderServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else if foldersByInstance.allSatisfy({ $0.values.isEmpty }) {
                ContentUnavailableView(
                    "No Root Folders",
                    systemImage: "folder",
                    description: Text("No root folders are configured in Sonarr or Radarr.")
                )
            } else {
                // One section per server rather than per service. Root folders are
                // per-server configuration, and an HD/4K pair almost never shares
                // one - grouping by service showed a single server's folders and
                // left the other's invisible.
                List {
                    ForEach(populatedGroups, id: \.ref.id) { group in
                        instanceSection(group)
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .refreshable {
                    await refreshRootFolders()
                }
            }
        }
        .navigationTitle("Root Folders")
        .moreDestinationBackground(.rootFolders)
        .task {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await refreshRootFolders()
        }
        .toolbar {
            if hasAnyConnectedService {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Root Folder", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: rootFoldersSettingsService)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddRootFolderSheet { path, instance in
                await addFolder(path: path, instance: instance)
            }
            .environment(serviceManager)
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .onChange(of: showingAddSheet) { _, isPresented in
            if !isPresented {
                // Sheet dismissed
            }
        }
        .alert(
            "Remove Root Folder?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            if let pending = pendingDelete {
                Button("Remove", role: .destructive) {
                    let capture = pending
                    pendingDelete = nil
                    Task { await deleteFolder(capture.folder, on: capture.instance) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            }
        } message: {
            if let pending = pendingDelete {
                Text("Remove \"\(pending.folder.path)\" from \(pending.instance.displayName)? Files will not be deleted.")
            }
        }
    }

    private var hasAnyService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var rootFolderServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasAnyConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var isConnecting: Bool {
        guard !hasAnyConnectedService else { return false }
        return serviceManager.isInitializing ||
            serviceManager.isConnecting(.sonarr) ||
            serviceManager.isConnecting(.radarr)
    }

    private var rootFoldersSettingsService: ArrServiceType {
        if serviceManager.hasSonarrInstance && !serviceManager.sonarrConnected { return .sonarr }
        return .radarr
    }

    private var foldersByInstance: [(ref: ArrInstanceRef, values: [ArrRootFolder])] {
        serviceManager.rootFoldersByInstance
    }

    private var populatedGroups: [(ref: ArrInstanceRef, values: [ArrRootFolder])] {
        foldersByInstance.filter { !$0.values.isEmpty }
    }

    @ViewBuilder
    private func instanceSection(_ group: (ref: ArrInstanceRef, values: [ArrRootFolder])) -> some View {
        Section(sectionTitle(for: group.ref)) {
            ForEach(group.values) { folder in
                rootFolderRow(folder, color: group.ref.serviceType.serviceIdentity.brandColor)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = (folder, group.ref)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
    }

    /// "Sonarr" with one server of that type, "Sonarr - 4K" with two, so the
    /// section header answers which server without the user counting rows.
    private func sectionTitle(for ref: ArrInstanceRef) -> String {
        guard serviceManager.showsInstanceProvenance(for: ref.serviceType) else {
            return ref.serviceType.displayName
        }
        return "\(ref.serviceType.displayName) - \(ref.shortLabel)"
    }

    private func refreshRootFolders() async {
        await serviceManager.refreshConfiguration()
    }

    private func rootFolderRow(_ folder: ArrRootFolder, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.accessible == false ? "folder.badge.minus" : "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(folder.accessible == false ? .red : color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.path)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if folder.accessible == false {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Not accessible")
                    }
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isDeleting ? 0.5 : 1)
    }

    private func addFolder(path: String, instance: ArrInstanceRef) async -> Bool {
        guard let client = serviceManager.sharedClient(for: instance) else { return false }
        do {
            _ = try await client.createRootFolder(path: path)
            await serviceManager.refreshConfiguration()
            notificationCenter.showSuccess(
                title: "Root Folder Added",
                message: "\(path) on \(instance.displayName)"
            )
            return true
        } catch {
            notificationCenter.showError(title: "Failed to Add", message: error.localizedDescription)
            return false
        }
    }

    /// Routed to the server whose section the row was in. Both instances number
    /// their root folders from the same sequence, so sending the delete anywhere
    /// else removes a different folder.
    private func deleteFolder(_ folder: ArrRootFolder, on instance: ArrInstanceRef) async {
        guard let client = serviceManager.sharedClient(for: instance) else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await client.deleteRootFolder(id: folder.id)
            await serviceManager.refreshConfiguration()
            notificationCenter.showSuccess(
                title: "Root Folder Removed",
                message: "\(folder.path) on \(instance.displayName)"
            )
        } catch {
            notificationCenter.showError(title: "Failed to Remove", message: error.localizedDescription)
        }
    }
}

#if DEBUG
#Preview("Root Folders - Loaded") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrRootFoldersView()
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Root Folders - Empty") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        NavigationStack {
            ArrRootFoldersView()
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Root Folder Editor - Add") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        AddRootFolderSheet { _, _ in true }
    }
}
#endif

private struct AddRootFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager

    let onAdd: @Sendable (String, ArrInstanceRef) async -> Bool

    @State private var path = ""
    @State private var selectedInstanceID: UUID?
    @State private var isSaving = false
    @State private var showingBrowser = false

    /// Every connected server, since a root folder is added to one server, not to
    /// a service. With a pair configured this is four options, not two.
    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances.map(\.ref)
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private func optionTitle(for ref: ArrInstanceRef) -> String {
        guard serviceManager.showsInstanceProvenance(for: ref.serviceType) else {
            return ref.serviceType.displayName
        }
        return "\(ref.serviceType.displayName) - \(ref.shortLabel)"
    }

    private var canSave: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        AppSheetShell(
            title: "Add Root Folder",
            confirmTitle: "Add",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                guard let instance = selectedInstance else { return }
                isSaving = true
                Task {
                    let success = await onAdd(trimmed, instance)
                    isSaving = false
                    if success { dismiss() }
                }
            }
        ) {
            Form {
                // Picks a server, not a service: with an HD/4K pair configured
                // there are four possible destinations and they do not share
                // root folders.
                if availableInstances.count > 1 {
                    Section {
                        Picker("Server", selection: $selectedInstanceID) {
                            ForEach(availableInstances) { ref in
                                Text(optionTitle(for: ref)).tag(Optional(ref.id))
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("/mnt/media/shows", text: $path)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        Button {
                            showingBrowser = true
                        } label: {
                            Label("Browse", systemImage: "folder")
                        }
                        .buttonStyle(.borderless)
                        .disabled(browserSource == nil)
                    }
                } header: {
                    Text("Path")
                } footer: {
                    Text("Enter or browse to the full path on \(selectedInstance?.displayName ?? "your server") or its container.")
                }
            }
            .onAppear {
                if selectedInstanceID == nil {
                    selectedInstanceID = availableInstances.first?.id
                }
            }
            .sheet(isPresented: $showingBrowser) {
                if let source = browserSource {
                    NavigationStack {
                        RemotePathBrowserView(
                            title: "\(selectedInstance?.displayName ?? "Server") Folders",
                            source: source,
                            initialPath: path,
                            onClose: { showingBrowser = false }
                        ) { selectedPath in
                            path = selectedPath
                        }
                    }
                }
            }
        }
    }

    /// Browses the filesystem of the selected server - the paths only that
    /// server can see.
    private var browserSource: RemotePathBrowserSource? {
        guard let instance = selectedInstance,
              let client = serviceManager.sharedClient(for: instance) else { return nil }
        return Self.source(serviceName: instance.displayName, client: client)
    }

    private static func source<Client: SharedArrClient>(serviceName: String, client: Client) -> RemotePathBrowserSource {
        RemotePathBrowserSource(
            serviceName: serviceName,
            loadRoots: {
                try await client.getFileSystem(path: "", includeFiles: false).map(\.remotePathEntry)
            },
            loadChildren: { path in
                try await client.getFileSystem(path: path, includeFiles: false).map(\.remotePathEntry)
            }
        )
    }
}
