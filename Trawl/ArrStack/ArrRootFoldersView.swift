import SwiftUI

struct ArrRootFoldersView: View {
    private let initialInstanceID: UUID?
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(ArrRootFolderBrowserState.self) private var sharedBrowser: ArrRootFolderBrowserState?
    @State private var localBrowser = ArrRootFolderBrowserState()

    private var browser: ArrRootFolderBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var showsDetailPane: Bool { sidebarColumn != nil }

    @State private var showingAddSheet = false
    @State private var pendingDelete: (folder: ArrRootFolder, instance: ArrInstanceRef)?
    @State private var isDeleting = false
    @State private var showSettings = false

    init(initialInstanceID: UUID? = nil) {
        self.initialInstanceID = initialInstanceID
    }

    var body: some View {
        if showsDetailPane {
            TrawlListDetailPanes(title: "Root Folders", subtitle: "Library Management") {
                instanceList
            } detail: {
                selectedInstanceDetail
            }
            .task {
                #if DEBUG
                if ArrPreviewRuntime.isActive { return }
                #endif
                guard sidebarColumn != .detail else { return }
                await refreshRootFolders()
            }
        } else {
            compactContent
        }
    }

    // MARK: - Split View List Column
    @ViewBuilder
    private var instanceList: some View {
        @Bindable var browser = self.browser
        Group {
            if !hasAnyService {
                ServiceSetupView(title: "No Services Configured", message: "Connect Sonarr or Radarr to view root folders.", systemImage: "folder.badge.questionmark")
                    .scrollableUnavailableState()
            } else if !hasAnyConnectedService {
                ArrServicesConnectionStatusView(
                    services: rootFolderServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else {
                List(selection: $browser.selectedInstanceID) {
                    Section {
                        ForEach(foldersByInstance, id: \.ref.id) { group in
                            instanceRow(group)
                                .tag(group.ref.id)
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
                .refreshable {
                    await refreshRootFolders()
                }
            }
        }
        .moreDestinationBackground(.rootFolders)
        .onChange(of: foldersByInstance.map(\.ref.id), initial: true) { _, instanceIDs in
            if let selected = browser.selectedInstanceID, !instanceIDs.contains(selected) {
                browser.selectedInstanceID = instanceIDs.first
            } else if browser.selectedInstanceID == nil {
                browser.selectedInstanceID = initialInstanceID ?? instanceIDs.first
            }
        }
    }

    private func instanceRow(_ group: (ref: ArrInstanceRef, values: [ArrRootFolder])) -> some View {
        let hasInaccessible = group.values.contains { $0.accessible == false }
        let count = group.values.count
        let countText = count == 1 ? "1 root folder" : "\(count) root folders"

        return HStack(spacing: 12) {
            Image(systemName: group.ref.serviceType.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(group.ref.serviceType.serviceIdentity.brandColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(sectionTitle(for: group.ref))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if hasInaccessible {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Split View Detail Column
    @ViewBuilder
    private var selectedInstanceDetail: some View {
        if let selectedID = browser.selectedInstanceID,
           let group = foldersByInstance.first(where: { $0.ref.id == selectedID }) {
            ArrInstanceRootFoldersDetailView(
                instance: group.ref,
                folders: group.values,
                onAdd: { path, instance in
                    await addFolder(path: path, instance: instance)
                },
                onDelete: { folder, instance in
                    await deleteFolder(folder, on: instance)
                }
            )
            .id(group.ref.id)
        } else if foldersByInstance.isEmpty {
            listDetailPlaceholder("No Servers Configured", systemImage: "folder")
        } else {
            listDetailPlaceholder("Select a Server", systemImage: "folder")
        }
    }

    // MARK: - Compact Content (Existing iPhone Layout)
    @ViewBuilder
    private var compactContent: some View {
        Group {
            if !hasAnyService {
                ServiceSetupView(title: "No Services Configured", message: "Connect Sonarr or Radarr to view root folders.", systemImage: "folder.badge.questionmark")
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
            .macSheetSizing()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddRootFolderSheet(initialInstanceID: initialInstanceID) { path, instance in
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
        serviceManager.rootFoldersByInstance.sorted { lhs, rhs in
            if lhs.ref.id == initialInstanceID { return true }
            if rhs.ref.id == initialInstanceID { return false }
            return lhs.ref.ordinal < rhs.ref.ordinal
        }
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

struct ArrInstanceRootFoldersDetailView: View {
    let instance: ArrInstanceRef
    let folders: [ArrRootFolder]
    let onAdd: @Sendable (String, ArrInstanceRef) async -> Bool
    let onDelete: @Sendable (ArrRootFolder, ArrInstanceRef) async -> Void

    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var showingAddSheet = false
    @State private var folderPendingDelete: ArrRootFolder?
    @State private var isDeleting = false

    private var title: String {
        guard serviceManager.showsInstanceProvenance(for: instance.serviceType) else {
            return instance.serviceType.displayName
        }
        return "\(instance.serviceType.displayName) - \(instance.shortLabel)"
    }

    private var subtitle: String {
        instance.displayName != instance.serviceType.displayName
            ? instance.displayName
            : "\(instance.serviceType.displayName) Server"
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        badges.append(ArrDetailBadge(
            icon: "folder.fill",
            label: folders.count == 1 ? "1 Folder" : "\(folders.count) Folders",
            color: instance.serviceType.serviceIdentity.brandColor
        ))
        if folders.contains(where: { $0.accessible == false }) {
            badges.append(ArrDetailBadge(
                icon: "exclamationmark.triangle.fill",
                label: "Inaccessible Folder",
                color: .red
            ))
        } else if !folders.isEmpty {
            badges.append(ArrDetailBadge(
                icon: "checkmark.circle.fill",
                label: "Accessible",
                color: .green
            ))
        }
        let totalFree = folders.compactMap(\.freeSpace).reduce(0, +)
        if totalFree > 0 {
            badges.append(ArrDetailBadge(
                icon: "internaldrive.fill",
                label: "\(ByteFormatter.format(bytes: totalFree)) Free",
                color: .secondary
            ))
        }
        return badges
    }

    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: title,
                    subtitle: subtitle,
                    systemImage: instance.serviceType.systemImage,
                    tint: instance.serviceType.serviceIdentity.brandColor,
                    shape: .rounded,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            if folders.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Root Folders", systemImage: "folder.badge.plus")
                    } description: {
                        Text("No root folders are configured on \(instance.displayName).")
                    } actions: {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("Add Root Folder", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 16)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(folders) { folder in
                    Section {
                        rootFolderDetailRow(folder)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .paneAwareNavigationTitle(
            title,
            subtitle: "Root Folders",
            whenPane: title
        )
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Root Folder", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddRootFolderSheet(initialInstanceID: instance.id) { path, targetInstance in
                await onAdd(path, targetInstance)
            }
            .environment(serviceManager)
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .alert(
            "Remove Root Folder?",
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            )
        ) {
            if let pending = folderPendingDelete {
                Button("Remove", role: .destructive) {
                    let capture = pending
                    folderPendingDelete = nil
                    Task {
                        isDeleting = true
                        await onDelete(capture, instance)
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {
                    folderPendingDelete = nil
                }
            }
        } message: {
            if let pending = folderPendingDelete {
                Text("Remove \"\(pending.path)\" from \(instance.displayName)? Files will not be deleted.")
            }
        }
    }

    @ViewBuilder
    private func rootFolderDetailRow(_ folder: ArrRootFolder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: folder.accessible == false ? "folder.badge.minus" : "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(folder.accessible == false ? .red : instance.serviceType.serviceIdentity.brandColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.path)
                        .font(.headline)
                        .textSelection(.enabled)

                    if folder.accessible == false {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Not accessible by \(instance.displayName)")
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 8)

                Button(role: .destructive) {
                    folderPendingDelete = folder
                } label: {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(isDeleting)
                .accessibilityLabel("Remove \(folder.path)")
            }

            if let totalSpace = folder.totalSpace, totalSpace > 0, let freeSpace = folder.freeSpace {
                let usedSpace = max(0, totalSpace - freeSpace)
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(usedSpace), total: Double(totalSpace))
                        .tint(freeSpace > totalSpace / 5 ? instance.serviceType.serviceIdentity.brandColor : .orange)

                    HStack {
                        Text("Used: \(ByteFormatter.format(bytes: usedSpace))")
                        Spacer()
                        Text("Free: \(ByteFormatter.format(bytes: freeSpace)) of \(ByteFormatter.format(bytes: totalSpace))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else if let freeSpace = folder.freeSpace {
                HStack {
                    Text("Free Space:")
                        .foregroundStyle(.secondary)
                    Text(ByteFormatter.format(bytes: freeSpace))
                        .fontWeight(.medium)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
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

fileprivate struct AddRootFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager

    let onAdd: @Sendable (String, ArrInstanceRef) async -> Bool
    private let initialInstanceID: UUID?

    @State private var path = ""
    @State private var selectedInstanceID: UUID?
    @State private var isSaving = false
    @State private var showingBrowser = false

    init(
        initialInstanceID: UUID? = nil,
        onAdd: @escaping @Sendable (String, ArrInstanceRef) async -> Bool
    ) {
        self.initialInstanceID = initialInstanceID
        self.onAdd = onAdd
        _selectedInstanceID = State(initialValue: initialInstanceID)
    }

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
                        // An example value, not a label: macOS draws a field's title beside it, where this
                        // reads as another entry that has already been added.
                        TextField("", text: $path, prompt: Text("/mnt/media/shows"))
                            .labelsHidden()
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
                    selectedInstanceID = initialInstanceID ?? availableInstances.first?.id
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
                    .macSheetSizing()
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
