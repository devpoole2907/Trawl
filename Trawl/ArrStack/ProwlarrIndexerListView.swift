import SwiftData
import SwiftUI

struct ProwlarrIndexerListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    @State private var prowlarrViewModel: ProwlarrViewModel?
    @State private var directViewModel: ArrIndexerManagementViewModel?
    @State private var applicationsViewModel: ProwlarrApplicationsViewModel?
    @State private var deleteTarget: UnifiedIndexerDeleteTarget?
    @State private var addDestination: AddIndexerDestination?
    @State private var searchText = ""
    @State private var showTestAllConfirm = false

    var body: some View {
        Group {
            if let prowlarrViewModel, let directViewModel {
                content(
                    prowlarrViewModel: prowlarrViewModel,
                    directViewModel: directViewModel,
                    applicationsViewModel: applicationsViewModel
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Indexers")
        .navigationSubtitle("Prowlarr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            if prowlarrViewModel == nil {
                prowlarrViewModel = ProwlarrViewModel(serviceManager: serviceManager)
            }
            if directViewModel == nil {
                directViewModel = ArrIndexerManagementViewModel(serviceManager: serviceManager)
            }
            if applicationsViewModel == nil {
                applicationsViewModel = ProwlarrApplicationsViewModel(serviceManager: serviceManager)
            }
            await reloadData()
        }
        .sheet(item: $addDestination) { destination in
            switch destination {
            case .prowlarr:
                if let prowlarrViewModel {
                    ProwlarrAddIndexerSheet(viewModel: prowlarrViewModel)
                }
            case .direct(let profileID, let serviceType):
                if let directViewModel, let profile = profile(for: profileID) {
                    DirectIndexerSchemaPickerSheet(
                        profile: profile,
                        serviceType: serviceType,
                        viewModel: directViewModel,
                        linkedApplication: linkedApplication(for: profile, serviceType: serviceType)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func content(
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel,
        applicationsViewModel: ProwlarrApplicationsViewModel?
    ) -> some View {
        List {
            if let stats = prowlarrViewModel.indexerStats, serviceManager.prowlarrConnected {
                prowlarrStatsOverviewSection(stats: stats)
            }

            if !unavailableSources.isEmpty {
                Section("Unavailable") {
                    ForEach(unavailableSources) { source in
                        unavailableRow(source)
                    }
                }
            }

            if isLoadingInitialData(prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel) && combinedItems(prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel).isEmpty {
                loadingRows
            } else if combinedItems(prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel).isEmpty {
                emptyState
            } else {
                sections(prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .refreshable { await reloadData() }
        .searchable(text: $searchText, prompt: "Search indexers")
        .toolbar { toolbarContent(prowlarrViewModel: prowlarrViewModel) }
        .alert(
            "Delete Indexer?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                self.deleteTarget = nil
                Task { await delete(deleteTarget, prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteTarget?.deleteMessage ?? "This indexer will be removed.")
        }
        .onChange(of: prowlarrViewModel.testResult) { _, result in
            guard let result else { return }
            if prowlarrViewModel.testSucceeded == true {
                InAppNotificationCenter.shared.showSuccess(title: "Test Complete", message: result)
            } else {
                InAppNotificationCenter.shared.showError(title: "Test Failed", message: result)
            }
            prowlarrViewModel.clearTestResult()
        }
        .onChange(of: directViewModel.testResult) { _, result in
            guard let result else { return }
            if directViewModel.testSucceeded == true {
                InAppNotificationCenter.shared.showSuccess(title: "Test Complete", message: result)
            } else {
                InAppNotificationCenter.shared.showError(title: "Test Failed", message: result)
            }
            directViewModel.clearTestResult()
        }
        .confirmationDialog("Test All Indexers?", isPresented: $showTestAllConfirm) {
            Button("Test All", role: .destructive) {
                Task { await prowlarrViewModel.testAllIndexers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Prowlarr will run connectivity tests on all \(prowlarrViewModel.indexers.count) indexers.")
        }
    }

    @ViewBuilder
    private func prowlarrStatsOverviewSection(stats: ProwlarrIndexerStats) -> some View {
        let entries = stats.indexers ?? []
        let totalQueries = entries.reduce(0) { $0 + ($1.numberOfQueries ?? 0) }
        let totalGrabs = entries.reduce(0) { $0 + ($1.numberOfGrabs ?? 0) }
        let totalFailed = entries.reduce(0) { $0 + ($1.numberOfFailedQueries ?? 0) }

        Section("Prowlarr Overview") {
            LabeledContent("Queries", value: "\(totalQueries)")
            LabeledContent("Grabs", value: "\(totalGrabs)")
            LabeledContent("Failed", value: "\(totalFailed)")

            if totalQueries > 0 {
                let rate = Double(totalQueries - totalFailed) / Double(totalQueries) * 100
                LabeledContent("Success Rate", value: String(format: "%.0f%%", rate))
            }
        }
    }

    @ViewBuilder
    private func sections(
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel
    ) -> some View {
        ForEach(IndexerListSection.allCases) { section in
            let items = combinedItems(prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel)
                .filter { $0.section == section }

            if !items.isEmpty {
                Section(section.title) {
                    ForEach(items) { item in
                        row(for: item, prowlarrViewModel: prowlarrViewModel, directViewModel: directViewModel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        for item: UnifiedIndexerListItem,
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel
    ) -> some View {
        switch item.kind {
        case .prowlarr(let indexer):
            NavigationLink {
                ProwlarrIndexerDetailView(indexer: indexer, viewModel: prowlarrViewModel)
            } label: {
                UnifiedIndexerRowView(
                    title: indexer.name ?? "Unknown",
                    subtitle: subtitle(for: item),
                    sourceLabel: item.sourceLabel,
                    barColor: item.barColor,
                    priority: indexer.priority,
                    isEnabled: indexer.enable,
                    warningState: item.warningState
                )
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await prowlarrViewModel.testIndexer(indexer) }
                } label: {
                    Label("Test", systemImage: "checkmark.circle")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteTarget = .prowlarr(indexer)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    Task {
                        await prowlarrViewModel.toggleIndexer(indexer)
                        if let error = prowlarrViewModel.indexerError {
                            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error)
                            prowlarrViewModel.clearIndexerError()
                        }
                    }
                } label: {
                    Label(indexer.enable ? "Disable" : "Enable", systemImage: indexer.enable ? "pause.circle" : "play.circle")
                }

                Button {
                    Task { await prowlarrViewModel.testIndexer(indexer) }
                } label: {
                    Label("Test", systemImage: "checkmark.circle")
                }

                Divider()

                Button(role: .destructive) {
                    deleteTarget = .prowlarr(indexer)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

        case .direct(let ownedIndexer):
            NavigationLink {
                DirectIndexerEditorView(
                    profile: ownedIndexer.profile,
                    serviceType: ownedIndexer.serviceType,
                    viewModel: directViewModel,
                    mode: .edit(ownedIndexer.indexer),
                    linkedApplication: linkedApplication(for: ownedIndexer.profile, serviceType: ownedIndexer.serviceType)
                )
            } label: {
                UnifiedIndexerRowView(
                    title: ownedIndexer.indexer.name ?? "Unknown",
                    subtitle: subtitle(for: item),
                    sourceLabel: item.sourceLabel,
                    barColor: item.barColor,
                    priority: ownedIndexer.indexer.priority,
                    isEnabled: ownedIndexer.indexer.isEnabled,
                    warningState: item.warningState
                )
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task {
                        await directViewModel.testIndexer(
                            ownedIndexer.indexer,
                            for: ownedIndexer.profile.id,
                            serviceType: ownedIndexer.serviceType
                        )
                    }
                } label: {
                    Label("Test", systemImage: "checkmark.circle")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteTarget = .direct(ownedIndexer)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    Task {
                        await directViewModel.testIndexer(
                            ownedIndexer.indexer,
                            for: ownedIndexer.profile.id,
                            serviceType: ownedIndexer.serviceType
                        )
                    }
                } label: {
                    Label("Test", systemImage: "checkmark.circle")
                }

                Divider()

                Button(role: .destructive) {
                    deleteTarget = .direct(ownedIndexer)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(prowlarrViewModel: ProwlarrViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if serviceManager.prowlarrConnected {
                    Button("Add to Prowlarr", systemImage: "magnifyingglass.circle") {
                        addDestination = .prowlarr
                    }
                }

                addSubmenu(
                    title: "Add to Sonarr",
                    systemImage: "tv",
                    profiles: connectedProfiles(for: .sonarr),
                    serviceType: .sonarr
                )

                addSubmenu(
                    title: "Add to Radarr",
                    systemImage: "film",
                    profiles: connectedProfiles(for: .radarr),
                    serviceType: .radarr
                )
            } label: {
                Label("Add Indexer", systemImage: "plus")
            }
        }

        if serviceManager.prowlarrConnected {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task {
                        await syncAllProwlarrIndexers(
                            prowlarrViewModel: prowlarrViewModel,
                            directViewModel: directViewModel,
                            applicationsViewModel: applicationsViewModel
                        )
                    }
                } label: {
                    Label("Sync All Indexers", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(
                    prowlarrViewModel.isSyncingApplications
                        || applicationsViewModel?.supportedApplications.isEmpty != false
                )
            }

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showTestAllConfirm = true
                } label: {
                    Label("Test All Prowlarr Indexers", systemImage: "checkmark.circle.badge.questionmark")
                }
                .disabled(
                    prowlarrViewModel.isTesting
                        || prowlarrViewModel.isSyncingApplications
                        || prowlarrViewModel.indexers.isEmpty
                )
            }
        }
    }

    @ViewBuilder
    private func addSubmenu(
        title: String,
        systemImage: String,
        profiles: [ArrServiceProfile],
        serviceType: ArrServiceType
    ) -> some View {
        if profiles.count == 1, let profile = profiles.first {
            Button(title, systemImage: systemImage) {
                addDestination = .direct(profileID: profile.id, serviceType: serviceType)
            }
        } else if !profiles.isEmpty {
            Menu(title) {
                ForEach(profiles) { profile in
                    Button(profile.displayName) {
                        addDestination = .direct(profileID: profile.id, serviceType: serviceType)
                    }
                }
            }
        }
    }

    private func subtitle(for item: UnifiedIndexerListItem) -> String {
        var parts: [String] = [item.sourceLabel]

        if let implementationName = item.implementationName, !implementationName.isEmpty {
            parts.append(implementationName)
        }

        if let protocolLabel = item.protocolDisplayName {
            parts.append(protocolLabel)
        }

        return parts.joined(separator: " · ")
    }

    private func delete(
        _ target: UnifiedIndexerDeleteTarget,
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel
    ) async {
        switch target {
        case .prowlarr(let indexer):
            let name = indexer.name ?? "Indexer"
            let deleted = await prowlarrViewModel.deleteIndexer(indexer)
            if let error = prowlarrViewModel.indexerError {
                InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
                prowlarrViewModel.clearIndexerError()
            } else if deleted && !prowlarrViewModel.containsIndexer(id: indexer.id) {
                InAppNotificationCenter.shared.showSuccess(title: "Indexer Deleted", message: "\(name) has been removed from Prowlarr.")
            }

        case .direct(let ownedIndexer):
            let deleted = await directViewModel.deleteIndexer(
                ownedIndexer.indexer,
                for: ownedIndexer.profile.id,
                serviceType: ownedIndexer.serviceType
            )

            if deleted {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Indexer Deleted",
                    message: "\(ownedIndexer.indexer.name ?? "Indexer") has been removed from \(ownedIndexer.profile.displayName)."
                )
            } else if let error = directViewModel.error(for: ownedIndexer.profile.id) {
                InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
            }
        }
    }

    private func reloadData() async {
        if let prowlarrViewModel {
            await prowlarrViewModel.loadIndexers()
        }
        if let directViewModel {
            await directViewModel.loadAllIndexers()
        }
        if let applicationsViewModel, serviceManager.prowlarrConnected {
            await applicationsViewModel.loadApplications()
        }
    }

    private func syncAllProwlarrIndexers(
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel?,
        applicationsViewModel: ProwlarrApplicationsViewModel?
    ) async {
        guard let directViewModel else { return }

        do {
            try await prowlarrViewModel.syncApplications()
            await directViewModel.loadAllIndexers()
            if let applicationsViewModel, serviceManager.prowlarrConnected {
                await applicationsViewModel.loadApplications()
            }
        } catch {
            InAppNotificationCenter.shared.showError(title: "Sync Failed", message: error.localizedDescription)
        }
    }

    private func connectedProfiles(for serviceType: ArrServiceType) -> [ArrServiceProfile] {
        allProfiles
            .filter { $0.resolvedServiceType == serviceType && $0.isEnabled && serviceManager.isConnected(serviceType, profileID: $0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func profile(for id: UUID) -> ArrServiceProfile? {
        allProfiles.first { $0.id == id }
    }

    private func ownerLabel(for profile: ArrServiceProfile) -> String {
        guard let serviceType = profile.resolvedServiceType else { return profile.displayName }
        let count = allProfiles.filter { $0.resolvedServiceType == serviceType && $0.isEnabled }.count
        if count > 1 && serviceType != .prowlarr {
            return "\(serviceType.displayName) · \(profile.displayName)"
        }
        return serviceType.displayName
    }

    private func currentProwlarrProfile() -> ArrServiceProfile? {
        if let activeID = serviceManager.activeProwlarrProfileID,
           let active = allProfiles.first(where: { $0.id == activeID }) {
            return active
        }

        return allProfiles
            .filter { $0.resolvedServiceType == .prowlarr && $0.isEnabled }
            .sorted { $0.dateAdded > $1.dateAdded }
            .first
    }

    private func combinedItems(
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel
    ) -> [UnifiedIndexerListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        var items: [UnifiedIndexerListItem] = []

        if serviceManager.prowlarrConnected {
            let prowlarrItems = prowlarrViewModel.indexers.map { indexer in
                UnifiedIndexerListItem(
                    kind: .prowlarr(indexer),
                    title: indexer.name ?? "Unknown",
                    implementationName: indexer.implementationName ?? indexer.implementation,
                    protocolName: indexer.protocol?.displayName,
                    sourceLabel: "Prowlarr",
                    barColor: color(for: .prowlarr),
                    warningState: indexer.enable ? .connected : .disabled,
                    section: section(for: indexer.protocol?.rawValue)
                )
            }
            items.append(contentsOf: prowlarrItems)
        }

        for profile in connectedProfiles(for: .sonarr) {
            let ownedIndexers = directViewModel.indexers(for: profile.id, serviceType: .sonarr)
                .filter { !shouldHideAsProwlarrMirror($0) }
                .map { indexer in
                let warningState: UnifiedIndexerRowWarningState = indexer.isEnabled ? .connected : .disabled
                return UnifiedIndexerListItem(
                    kind: .direct(OwnedDirectIndexer(indexer: indexer, profile: profile, serviceType: .sonarr)),
                    title: indexer.name ?? "Unknown",
                    implementationName: indexer.implementationName ?? indexer.implementation,
                    protocolName: indexer.protocol?.displayName,
                    sourceLabel: ownerLabel(for: profile),
                    barColor: color(for: .sonarr),
                    warningState: warningState,
                    section: section(for: indexer.protocol?.rawValue)
                )
            }
            items.append(contentsOf: ownedIndexers)
        }

        for profile in connectedProfiles(for: .radarr) {
            let ownedIndexers = directViewModel.indexers(for: profile.id, serviceType: .radarr)
                .filter { !shouldHideAsProwlarrMirror($0) }
                .map { indexer in
                let warningState: UnifiedIndexerRowWarningState = indexer.isEnabled ? .connected : .disabled
                return UnifiedIndexerListItem(
                    kind: .direct(OwnedDirectIndexer(indexer: indexer, profile: profile, serviceType: .radarr)),
                    title: indexer.name ?? "Unknown",
                    implementationName: indexer.implementationName ?? indexer.implementation,
                    protocolName: indexer.protocol?.displayName,
                    sourceLabel: ownerLabel(for: profile),
                    barColor: color(for: .radarr),
                    warningState: warningState,
                    section: section(for: indexer.protocol?.rawValue)
                )
            }
            items.append(contentsOf: ownedIndexers)
        }

        let filteredItems: [UnifiedIndexerListItem]
        if query.isEmpty {
            filteredItems = items
        } else {
            filteredItems = items.filter { item in
                item.title.localizedCaseInsensitiveContains(query)
                    || item.sourceLabel.localizedCaseInsensitiveContains(query)
                    || (item.implementationName?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        return filteredItems.sorted { lhs, rhs in
            if lhs.section == rhs.section {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.section.sortOrder < rhs.section.sortOrder
        }
    }

    private func color(for serviceType: ArrServiceType) -> Color {
        switch serviceType {
        case .prowlarr: .yellow
        case .sonarr: .blue
        case .radarr: .orange
        case .bazarr: .secondary
        }
    }

    private func section(for protocolValue: String?) -> IndexerListSection {
        switch protocolValue {
        case ArrIndexerProtocol.torrent.rawValue, ProwlarrIndexerProtocol.torrent.rawValue:
            .torrent
        case ArrIndexerProtocol.usenet.rawValue, ProwlarrIndexerProtocol.usenet.rawValue:
            .usenet
        default:
            .other
        }
    }

    private func isLoadingInitialData(
        prowlarrViewModel: ProwlarrViewModel,
        directViewModel: ArrIndexerManagementViewModel
    ) -> Bool {
        prowlarrViewModel.isLoadingIndexers || connectedProfiles(for: .sonarr).contains(where: { directViewModel.isLoadingIndexers(for: $0.id) })
            || connectedProfiles(for: .radarr).contains(where: { directViewModel.isLoadingIndexers(for: $0.id) })
    }

    private var unavailableSources: [UnavailableIndexerSource] {
        guard !serviceManager.isInitializing else { return [] }

        var sources: [UnavailableIndexerSource] = []

        for profile in allProfiles where shouldShowUnavailableSource(profile) {
            let error: String?
            switch profile.resolvedServiceType {
            case .prowlarr:
                error = serviceManager.prowlarrConnectionError
            case .sonarr:
                error = serviceManager.sonarrInstances.first(where: { $0.id == profile.id })?.connectionError
            case .radarr:
                error = serviceManager.radarrInstances.first(where: { $0.id == profile.id })?.connectionError
            case .none, .bazarr:
                error = nil
            }

            let source = UnavailableIndexerSource(
                profile: profile,
                error: error ?? "Connection unavailable."
            )
            sources.append(source)
        }

        return sources.sorted {
            $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending
        }
    }

    private func shouldShowUnavailableSource(_ profile: ArrServiceProfile) -> Bool {
        guard let serviceType = profile.resolvedServiceType else { return false }
        guard profile.isEnabled, [.prowlarr, .sonarr, .radarr].contains(serviceType) else { return false }

        switch serviceType {
        case .prowlarr:
            guard !serviceManager.prowlarrIsConnecting, !serviceManager.prowlarrConnected else { return false }
            let resolvedProfile = serviceManager.resolvedProfile(for: .prowlarr, in: allProfiles)
            return resolvedProfile?.id == profile.id
        case .sonarr:
            let isConnecting = serviceManager.sonarrInstances.contains { $0.id == profile.id && $0.isConnecting }
            return !isConnecting && !serviceManager.isConnected(.sonarr, profileID: profile.id)
        case .radarr:
            let isConnecting = serviceManager.radarrInstances.contains { $0.id == profile.id && $0.isConnecting }
            return !isConnecting && !serviceManager.isConnected(.radarr, profileID: profile.id)
        case .bazarr:
            return false
        }
    }

    private func shouldHideAsProwlarrMirror(_ indexer: ArrManagedIndexer) -> Bool {
        guard serviceManager.prowlarrConnected else { return false }

        let lowercasedName = (indexer.name ?? "").lowercased()
        if lowercasedName.contains("(prowlarr)") || lowercasedName.contains("[prowlarr]") {
            return true
        }

        guard let prowlarrProfile = currentProwlarrProfile() else { return false }
        let normalizedProwlarrURL = normalizedMirrorURL(from: prowlarrProfile.hostURL)
        let prowlarrBaseURL = URL(string: prowlarrProfile.hostURL)
        let prowlarrHost = prowlarrBaseURL?.host?.lowercased()
        let prowlarrPort = prowlarrBaseURL?.port
        let prowlarrPath = prowlarrBaseURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.path

        for field in indexer.fields ?? [] {
            guard let fieldName = field.name else { continue }
            guard let rawValue = field.value?.displayString, !rawValue.isEmpty else { continue }

            // Exact match for baseUrl field
            if fieldName.lowercased() == "baseurl" {
                if let normalizedFieldURL = normalizedMirrorURL(from: rawValue),
                   let normalizedProwlarrURL,
                   normalizedFieldURL == normalizedProwlarrURL {
                    return true
                }
            }

            // For other URL-like fields, use stricter URL parsing
            let lowerFieldName = fieldName.lowercased()
            guard lowerFieldName.contains("url") || lowerFieldName.contains("base") || lowerFieldName.contains("api") else { continue }

            // Parse the field value as a URL
            guard let fieldURL = URL(string: rawValue),
                  let fieldHost = fieldURL.host?.lowercased() else { continue }

            // Host AND port must match (services often share a hostname)
            guard let prowlarrHost, fieldHost == prowlarrHost else { continue }
            guard fieldURL.port == prowlarrPort else { continue }

            // Check if the path matches or is a prefix
            let fieldPath = fieldURL.path
            if let prowlarrPath {
                if fieldPath == prowlarrPath {
                    return true
                }
                // Guard against empty/root prowlarrPath: "".hasPrefix("") is always true
                if !prowlarrPath.isEmpty, prowlarrPath != "/", fieldPath.hasPrefix(prowlarrPath) {
                    return true
                }
                // Only treat prowlarrPath as prefix when it is non-trivial
                if !fieldPath.isEmpty, fieldPath != "/", prowlarrPath.hasPrefix(fieldPath) {
                    return true
                }
            }

            // Only the /{n}/api pattern is Prowlarr-specific; drop the broad /api fallback
            if fieldPath.range(of: "/\\d+/api", options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    private func normalizedMirrorURL(from rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func linkedApplication(for profile: ArrServiceProfile, serviceType: ArrServiceType) -> ProwlarrApplication? {
        guard serviceManager.prowlarrConnected,
              let applicationsViewModel else { return nil }

        let expectedType: ProwlarrLinkedAppType
        switch serviceType {
        case .sonarr:
            expectedType = .sonarr
        case .radarr:
            expectedType = .radarr
        case .prowlarr, .bazarr:
            return nil
        }

        let profileURL = normalizedMirrorURL(from: profile.hostURL)
        let profileParsed = URL(string: profile.hostURL)
        let profileHost = profileParsed?.host?.lowercased()
        let profilePort = profileParsed?.port

        return applicationsViewModel.supportedApplications.first { application in
            guard application.linkedAppType == expectedType else { return false }
            guard let baseURL = application.stringFieldValue(named: "baseUrl"), !baseURL.isEmpty else { return false }

            let normalizedBaseURL = normalizedMirrorURL(from: baseURL)
            if let profileURL, let normalizedBaseURL, normalizedBaseURL == profileURL {
                return true
            }

            // Fallback: compare host, port AND path to avoid aliasing across same-host reverse-proxy services
            let baseParsed = URL(string: baseURL)
            let baseHost = baseParsed?.host?.lowercased()
            let basePort = baseParsed?.port
            let profilePath = profileParsed?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let basePath = baseParsed?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if let profileHost, let baseHost, profileHost == baseHost, profilePort == basePort, profilePath == basePath {
                return true
            }

            return false
        }
    }

    @ViewBuilder
    private func unavailableRow(_ source: UnavailableIndexerSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.profile.displayName)
                .font(.body.weight(.medium))

            Text(source.error)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var loadingRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 8, height: 36)

                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 160, height: 14)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 120, height: 11)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Indexers",
            systemImage: "magnifyingglass.circle",
            description: Text("Use the add button to create an indexer in Prowlarr, Sonarr, or Radarr.")
        )
        .listRowBackground(Color.clear)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.yellow.opacity(0.08), Color.blue.opacity(0.06), Color.orange.opacity(0.04), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.yellow.opacity(0.10), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }
}
