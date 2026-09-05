import SwiftUI
import SwiftData
import OSLog

// MARK: - Import Kind / Mode

/// Which Arr import flow a screen drives. Library Import bulk-adopts an existing
/// organized library (adding titles as needed); Manual Import brings files into
/// titles that are already in the library. Both run on the same scan/identify
/// engine - this just toggles the title, copy, and existing-only behaviour.
enum ArrImportKind: Sendable, Hashable {
    case library
    case manual

    var navigationTitle: String {
        switch self {
        case .library: return "Library Import"
        case .manual: return "Manual Import"
        }
    }

    var accent: MoreDestinationAccent {
        switch self {
        case .library: return .libraryImport
        case .manual: return .manualImport
        }
    }
}

/// How Sonarr/Radarr place an imported file. Mirrors the `importMode` the
/// interactive import sends; a hardlink happens automatically under `.copy`
/// when the server's media management is configured for it.
enum ArrImportMode: String, CaseIterable, Sendable, Identifiable {
    case move
    case copy

    var id: String { rawValue }
    var apiValue: String { rawValue }

    var label: String {
        switch self {
        case .move: return "Move"
        case .copy: return "Copy"
        }
    }
}

// MARK: - Import Location Browser

/// Lets the user pick a root or custom folder to scan, for either import flow.
struct ArrImportLocationView: View {
    let kind: ArrImportKind

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(ArrImportLocationBrowserState.self) private var sharedBrowser: ArrImportLocationBrowserState?
    @Query private var allProfiles: [ArrServiceProfile]

    /// Only the Library Import root sits in the sidebar's split view; Manual
    /// Import is pushed from More and owns its own selection.
    @State private var localBrowser = ArrImportLocationBrowserState()
    private var browser: ArrImportLocationBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var selectedInstanceID: UUID? {
        get { browser.selectedInstanceID }
        nonmutating set { browser.selectedInstanceID = newValue }
    }

    /// Which folder the detail pane is scanning. Nil on iPhone, where the row
    /// pushes instead.
    private var selectedPath: String? {
        get { browser.selectedPath }
        nonmutating set { browser.selectedPath = newValue }
    }

    @State private var showAddLocation = false

    init(kind: ArrImportKind = .library) {
        self.kind = kind
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var selectedService: ArrServiceType {
        selectedInstance?.serviceType ?? .sonarr
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    /// Every connected Sonarr and Radarr, since an import writes into one
    /// server's library and the pair do not share root folders.
    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances.map(\.ref)
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private var rootFolders: [ArrRootFolder] {
        guard let instance = selectedInstance else { return [] }
        return serviceManager.rootFolders(for: instance.id)
    }

    /// The profile holding this server's custom import folders - bookmarks are
    /// stored per server, because the paths only exist on that server.
    private var currentProfile: ArrServiceProfile? {
        guard let instance = selectedInstance else { return nil }
        return allProfiles.first { $0.id == instance.id }
    }

    private var customFolders: [String] {
        currentProfile?.importFolders ?? []
    }

    /// Every location the list offers, in the order it shows them. The selection
    /// is reconciled against this, so a path that the scope bar took away does not
    /// leave a row looking selected beside an empty pane.
    private var allLocationPaths: [String] {
        rootFolders.map(\.path) + customFolders
    }

    var body: some View {
        // Two panes at regular width: picking a folder to scan and reading the scan
        // are one task, and the folder list is short enough that pushing over it
        // only costs a round trip back.
        TrawlListDetailPanes(title: kind.navigationTitle) {
            locationList
        } detail: {
            selectedLocationDetail
        }
    }

    @ViewBuilder
    private var locationList: some View {
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
        .moreDestinationBackground(kind.accent)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The right-hand pane: the scan of whichever folder is selected.
    ///
    /// The same view the row pushes without a pane, given the same arguments, so a
    /// scan started from either side is the same session-scoped scan.
    @ViewBuilder
    private var selectedLocationDetail: some View {
        if let selectedPath {
            scanView(path: selectedPath)
                .id("\(selectedInstance?.id.uuidString ?? "")|\(selectedPath)")
        } else {
            listDetailPlaceholder("Select a Folder", systemImage: "folder")
        }
    }

    private func scanView(path: String) -> some View {
        LibraryImportScanView(
            path: path,
            service: selectedService,
            serviceManager: serviceManager,
            instanceID: selectedInstance?.id,
            kind: kind
        )
    }

    /// Keeps the pane pointed at a folder the current server actually offers.
    private func reconcileSelection() {
        guard showsDetailPane else {
            selectedPath = nil
            return
        }
        if let selectedPath, !allLocationPaths.contains(selectedPath) {
            self.selectedPath = nil
        }
    }

    private var emptyState: some View {
        ServiceSetupView(
            title: "No Services Configured",
            message: kind == .manual
                ? "Add a Sonarr or Radarr server in Settings to import files into your library."
                : "Add a Sonarr or Radarr server in Settings to import an existing library.",
            systemImage: "tray.and.arrow.down"
        )
        .scrollableUnavailableState()
    }

    private var listContent: some View {
        @Bindable var browser = self.browser
        return List(selection: $browser.selectedPath) {
            importTipsSection

            if !rootFolders.isEmpty {
                Section {
                    ForEach(rootFolders) { folder in
                        locationLink(path: folder.path) {
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
                        locationLink(path: path) {
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
                    Text("Save frequently-used folders so you can quickly scan them for unmapped files.")
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedInstanceID)
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(instances: availableInstances, selection: $browser.selectedInstanceID)
        }
        .sheet(isPresented: $showAddLocation) {
            AddImportLocationSheet(service: selectedService, instanceID: selectedInstance?.id) { path in
                addBookmark(path: path)
            }
        }
        .onAppear {
            selectedInstanceID = serviceManager.defaultScopeInstanceID(preferring: selectedInstanceID)
            reconcileSelection()
        }
        // The scope bar rebuilds the list from a different server, and a saved
        // location is removed; both leave a selection naming a folder that is no
        // longer on offer.
        .onChange(of: selectedInstanceID) { reconcileSelection() }
        .onChange(of: allLocationPaths) { reconcileSelection() }
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func locationLink<Label: View>(path: String, @ViewBuilder label: () -> Label) -> some View {
        if showsDetailPane {
            label()
                .tag(path)
        } else {
            NavigationLink(value: scanDestination(path: path)) {
                label()
            }
        }
    }

    @ViewBuilder
    private var importTipsSection: some View {
        let plural = selectedService == .sonarr ? "series" : "movies"
        let perItem = selectedService == .sonarr ? "series" : "movie"
        switch kind {
        case .library:
            let singleFolder = selectedService == .sonarr ? "“/tv shows”" : "“/movies”"
            let specificFolder = selectedService == .sonarr ? "“/tv shows/The Simpsons”" : "“/movies/Inception”"
            let qualityExample = selectedService == .sonarr ? "episode.s02e15.bluray.mkv" : "the.movie.2009.bluray.mkv"
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    importTip("Make sure your files include the quality in their filenames, e.g. \(qualityExample).")
                    importTip("Point \(selectedService.displayName) at the folder containing all of your \(plural), not a specific one - e.g. \(singleFolder), not \(specificFolder). Each \(perItem) must be in its own folder within the root.")
                    importTip("Don’t use this for unsorted downloads from your download client. It’s only for libraries that are already organized.")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Import \(plural) you already have")
            } footer: {
                Text("Pick a library root below to scan it for \(plural) that aren’t in \(selectedService.displayName) yet.")
            }
        case .manual:
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    importTip("Use this to import files for \(plural) that are already in \(selectedService.displayName). To add new \(plural), use Library Import instead.")
                    importTip("Point \(selectedService.displayName) at the folder holding the files you want to import.")
                    importTip("Each file is matched to an existing \(perItem) - correct any match, and choose Move or Copy, before importing.")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Import files into your library")
            } footer: {
                Text("Pick a folder below to scan it for importable files.")
            }
        }
    }

    private func scanDestination(path: String) -> MoreDestination {
        switch kind {
        case .library: return .libraryImportScan(path: path, service: selectedService, instanceID: selectedInstance?.id)
        case .manual: return .manualImportScan(path: path, service: selectedService, instanceID: selectedInstance?.id)
        }
    }

    private func importTip(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
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
            ArrImportLocationView()
        }
    }
}

#Preview("Manual Import - Empty") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        NavigationStack {
            ArrImportLocationView()
        }
    }
}

#Preview("Manual Import - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrImportLocationView()
        }
    }
}
#endif

// MARK: - Add Location Sheet
