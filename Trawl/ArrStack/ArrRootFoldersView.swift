import SwiftUI

struct ArrRootFoldersView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var showingAddSheet = false
    @State private var pendingDelete: (folder: ArrRootFolder, service: ArrServiceType)?
    @State private var isDeleting = false

    var body: some View {
        Group {
            if !hasAnyService {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Connect Sonarr or Radarr to view root folders.")
                )
            } else if !hasAnyConnectedService {
                ContentUnavailableView(
                    "Services Unreachable",
                    systemImage: "network.slash",
                    description: Text("Unable to reach your configured Sonarr or Radarr servers.")
                )
            } else if sonarrFolders.isEmpty && radarrFolders.isEmpty {
                ContentUnavailableView(
                    "No Root Folders",
                    systemImage: "folder",
                    description: Text("No root folders are configured in Sonarr or Radarr.")
                )
            } else {
                List {
                    if !sonarrFolders.isEmpty {
                        Section("Sonarr") {
                            ForEach(sonarrFolders) { folder in
                                rootFolderRow(folder, color: .purple)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDelete = (folder, .sonarr)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                    if !radarrFolders.isEmpty {
                        Section("Radarr") {
                            ForEach(radarrFolders) { folder in
                                rootFolderRow(folder, color: .orange)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDelete = (folder, .radarr)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .navigationTitle("Root Folders")
        .moreDestinationBackground(.rootFolders)
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
        .sheet(isPresented: $showingAddSheet) {
            AddRootFolderSheet { path, service in
                await addFolder(path: path, service: service)
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
                    Task { await deleteFolder(capture.folder, service: capture.service) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            }
        } message: {
            if let pending = pendingDelete {
                Text("Remove \"\(pending.folder.path)\" from \(pending.service.displayName)? Files will not be deleted.")
            }
        }
    }

    private var hasAnyService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var hasAnyConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var sonarrFolders: [ArrRootFolder] {
        serviceManager.sonarrRootFolders
    }

    private var radarrFolders: [ArrRootFolder] {
        serviceManager.radarrRootFolders
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
                    Label("Not accessible", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isDeleting ? 0.5 : 1)
    }

    private func addFolder(path: String, service: ArrServiceType) async -> Bool {
        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return false }
                _ = try await client.createRootFolder(path: path)
            case .radarr:
                guard let client = serviceManager.radarrClient else { return false }
                _ = try await client.createRootFolder(path: path)
            case .prowlarr:
                return false
            }
            await serviceManager.refreshConfiguration()
            notificationCenter.showSuccess(title: "Root Folder Added", message: path)
            return true
        } catch {
            notificationCenter.showError(title: "Failed to Add", message: error.localizedDescription)
            return false
        }
    }

    private func deleteFolder(_ folder: ArrRootFolder, service: ArrServiceType) async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                try await client.deleteRootFolder(id: folder.id)
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                try await client.deleteRootFolder(id: folder.id)
            case .prowlarr:
                return
            }
            await serviceManager.refreshConfiguration()
            notificationCenter.showSuccess(title: "Root Folder Removed", message: folder.path)
        } catch {
            notificationCenter.showError(title: "Failed to Remove", message: error.localizedDescription)
        }
    }
}

private struct AddRootFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager

    let onAdd: @Sendable (String, ArrServiceType) async -> Bool

    @State private var path = ""
    @State private var selectedService: ArrServiceType = .sonarr
    @State private var isSaving = false

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.sonarrConnected { services.append(.sonarr) }
        if serviceManager.radarrConnected { services.append(.radarr) }
        return services
    }

    private var canSave: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                if availableServices.count > 1 {
                    Section {
                        Picker("Service", selection: $selectedService) {
                            ForEach(availableServices, id: \.self) { service in
                                Text(service.displayName).tag(service)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    TextField("/mnt/media/shows", text: $path)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Path")
                } footer: {
                    Text("Enter the full path to the folder on your \(selectedService.displayName) server.")
                }
            }
            .navigationTitle("Add Root Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: platformCancellationPlacement) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add") {
                            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            isSaving = true
                            Task {
                                let success = await onAdd(trimmed, selectedService)
                                isSaving = false
                                if success {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                if let first = availableServices.first {
                    selectedService = first
                }
            }
        }
    }
}
