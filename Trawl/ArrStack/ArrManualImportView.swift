import SwiftUI
import SwiftData
import OSLog

// MARK: - Location Browser

struct ArrManualImportView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var showAddLocation = false

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var rootFolders: [ArrRootFolder] {
        selectedService == .sonarr ? serviceManager.sonarrRootFolders : serviceManager.radarrRootFolders
    }

    private var currentProfile: ArrServiceProfile? {
        let activeProfileID: UUID?
        switch selectedService {
        case .sonarr:
            activeProfileID = serviceManager.activeSonarrProfileID
        case .radarr:
            activeProfileID = serviceManager.activeRadarrProfileID
        case .prowlarr, .bazarr:
            activeProfileID = nil
        }

        if let activeProfileID, let profile = allProfiles.first(where: { $0.id == activeProfileID }) {
            return profile
        }
        return allProfiles.first { $0.resolvedServiceType == selectedService }
    }

    private var customFolders: [String] {
        currentProfile?.importFolders ?? []
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                emptyState
            } else if !hasConnectedService {
                ArrServicesConnectionStatusView(
                    services: availableServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else {
                listContent
            }
        }
        .navigationTitle("Manual Import")
        .moreDestinationBackground(.manualImport)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Services Configured", systemImage: "tray.and.arrow.down")
        } description: {
            Text("Add a Sonarr or Radarr server in Settings to use Manual Import.")
        }
    }

    private var listContent: some View {
        List {
            if !rootFolders.isEmpty {
                Section {
                    ForEach(rootFolders) { folder in
                        NavigationLink(value: MoreDestination.manualImportScan(path: folder.path, service: selectedService)) {
                            locationRow(
                                icon: "internaldrive",
                                title: folder.path,
                                subtitle: "Library Root",
                                tint: .secondary
                            )
                        }
                    }
                } header: {
                    Text("Library Roots")
                }
            }

            Section {
                if customFolders.isEmpty {
                    Text("No saved locations")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customFolders, id: \.self) { path in
                        NavigationLink(value: MoreDestination.manualImportScan(path: path, service: selectedService)) {
                            locationRow(
                                icon: "folder",
                                title: path,
                                subtitle: "Custom",
                                tint: .blue
                            )
                        }
                    }
                    .onDelete(perform: removeBookmarks)
                }
            } header: {
                Text("Your Locations")
            } footer: {
                if customFolders.isEmpty {
                    Text("Save the paths to your download directories so you can quickly scan them for unmapped files.")
                }
            }

            Section {
                Button {
                    showAddLocation = true
                } label: {
                    Label("Add Custom Path", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedService)
        .safeAreaInset(edge: .top) {
            if availableServices.count > 1 {
                TrawlSegmentBar("Service", selection: Binding(
                    get: { selectedService },
                    set: { newService in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedService = newService
                        }
                    }
                ), items: availableServices.map(\.segmentBarItem), alignment: .center)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showAddLocation) {
            AddImportLocationSheet(service: selectedService) { path in
                addBookmark(path: path)
            }
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    private func locationRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func addBookmark(path: String) {
        guard let profile = currentProfile else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profile.importFolders.contains(trimmed) else { return }

        guard isAbsoluteImportPath(trimmed) else { return }

        withAnimation {
            profile.importFolders.append(trimmed)
        }
    }

    private func removeBookmarks(at offsets: IndexSet) {
        guard let profile = currentProfile else { return }
        withAnimation {
            profile.importFolders.remove(atOffsets: offsets)
        }
    }
}

extension ArrServiceType {
    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(displayName, value: self)
    }
}

#if DEBUG
#Preview("Manual Import - Locations") {
    let profiles = PreviewSupport.ProfileScenario.custom { context in
        let sonarr = ArrServiceProfile.preview(.sonarr)
        sonarr.importFolders = ["/downloads/complete/tv", "/mnt/staging/sonarr"]
        context.insert(sonarr)

        let radarr = ArrServiceProfile.preview(.radarr, hostURL: "http://192.168.1.50:7878")
        radarr.importFolders = ["/downloads/complete/movies"]
        context.insert(radarr)
    }

    PreviewHost(profiles: profiles, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrManualImportView()
        }
    }
}

#Preview("Manual Import - Empty") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        NavigationStack {
            ArrManualImportView()
        }
    }
}

#Preview("Manual Import - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrManualImportView()
        }
    }
}
#endif

// MARK: - Add Location Sheet
