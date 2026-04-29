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
        .listStyle(.insetGrouped)
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
                    Task { await prowlarrViewModel.testAllIndexers() }
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
        case .prowlarr:
            .yellow
        case .sonarr:
            .blue
        case .radarr:
            .orange
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
            case .none:
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
        case .prowlarr:
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

            // Fallback: compare host AND port to avoid aliasing across same-host services
            let baseParsed = URL(string: baseURL)
            let baseHost = baseParsed?.host?.lowercased()
            let basePort = baseParsed?.port
            if let profileHost, let baseHost, profileHost == baseHost, profilePort == basePort {
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
                RoundedRectangle(cornerRadius: 6)
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

private enum IndexerListSection: CaseIterable, Identifiable {
    case torrent
    case usenet
    case other

    var id: String { title }
    var title: String {
        switch self {
        case .torrent: "Torrent"
        case .usenet: "Usenet"
        case .other: "Other"
        }
    }

    var sortOrder: Int {
        switch self {
        case .torrent: 0
        case .usenet: 1
        case .other: 2
        }
    }
}

private struct OwnedDirectIndexer: Identifiable {
    let indexer: ArrManagedIndexer
    let profile: ArrServiceProfile
    let serviceType: ArrServiceType

    var id: String { "\(serviceType.rawValue)-\(profile.id.uuidString)-\(indexer.id)" }
}

private enum UnifiedIndexerDeleteTarget {
    case prowlarr(ProwlarrIndexer)
    case direct(OwnedDirectIndexer)

    var deleteMessage: String {
        switch self {
        case .prowlarr(let indexer):
            "This removes \"\(indexer.name ?? "this indexer")\" from Prowlarr."
        case .direct(let ownedIndexer):
            "This removes \"\(ownedIndexer.indexer.name ?? "this indexer")\" from \(ownedIndexer.profile.displayName)."
        }
    }
}

private enum AddIndexerDestination: Identifiable {
    case prowlarr
    case direct(profileID: UUID, serviceType: ArrServiceType)

    var id: String {
        switch self {
        case .prowlarr:
            "prowlarr"
        case .direct(let profileID, let serviceType):
            "\(serviceType.rawValue)-\(profileID.uuidString)"
        }
    }
}

private struct UnavailableIndexerSource: Identifiable {
    let profile: ArrServiceProfile
    let error: String

    var id: UUID { profile.id }
}

private struct UnifiedIndexerListItem: Identifiable {
    enum Kind {
        case prowlarr(ProwlarrIndexer)
        case direct(OwnedDirectIndexer)
    }

    let kind: Kind
    let title: String
    let implementationName: String?
    let protocolName: String?
    let sourceLabel: String
    let barColor: Color
    let warningState: UnifiedIndexerRowWarningState
    let section: IndexerListSection

    var id: String {
        switch kind {
        case .prowlarr(let indexer):
            "prowlarr-\(indexer.id)"
        case .direct(let ownedIndexer):
            ownedIndexer.id
        }
    }

    var protocolDisplayName: String? { protocolName }
}

private enum UnifiedIndexerRowWarningState {
    case connected
    case disabled
}

private struct UnifiedIndexerRowView: View {
    let title: String
    let subtitle: String
    let sourceLabel: String
    let barColor: Color
    let priority: Int?
    let isEnabled: Bool
    let warningState: UnifiedIndexerRowWarningState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(statusColor)
                .frame(width: 4, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isEnabled ? .primary : .secondary)

                    if let priority, priority != 25 {
                        Text("P\(priority)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(barColor.opacity(0.9), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: warningIcon)
                .font(.caption)
                .foregroundStyle(warningIconColor)
        }
        .padding(.vertical, 4)
        .opacity(isEnabled ? 1.0 : 0.65)
    }

    private var statusColor: Color {
        isEnabled ? barColor : .secondary.opacity(0.4)
    }

    private var warningIcon: String {
        switch warningState {
        case .connected:
            "circle.fill"
        case .disabled:
            "circle"
        }
    }

    private var warningIconColor: Color {
        switch warningState {
        case .connected:
            .green
        case .disabled:
            .secondary
        }
    }
}

private struct DirectIndexerSchemaPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: ArrServiceProfile
    let serviceType: ArrServiceType
    let viewModel: ArrIndexerManagementViewModel
    let linkedApplication: ProwlarrApplication?

    @State private var searchText = ""

    private var filteredSchema: [ArrManagedIndexer] {
        let schema = viewModel.schema(for: profile.id)
        guard !searchText.isEmpty else { return schema }
        return schema.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText)
                || ($0.implementationName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ArrSheetShell(title: "Add Indexer") {
            Group {
                if viewModel.isLoadingSchema(for: profile.id) {
                    ProgressView("Loading indexer types…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.schemaError(for: profile.id) {
                    ContentUnavailableView {
                        Label("Failed to Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.loadSchema(for: profile.id, serviceType: serviceType, force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if filteredSchema.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No indexers match \"\(searchText)\".")
                    )
                } else if filteredSchema.isEmpty {
                    ContentUnavailableView(
                        "No Indexers",
                        systemImage: "magnifyingglass",
                        description: Text("No indexer schemas were returned by \(profile.displayName).")
                    )
                } else {
                    List(filteredSchema, id: \.schemaListID) { schema in
                        NavigationLink {
                            DirectIndexerEditorView(
                                profile: profile,
                                serviceType: serviceType,
                                viewModel: viewModel,
                                mode: .add(schema),
                                linkedApplication: linkedApplication,
                                onSaved: { dismiss() }
                            )
                        } label: {
                            schemaRow(schema)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, prompt: "Search indexers")
            .task {
                await viewModel.loadSchema(for: profile.id, serviceType: serviceType)
            }
        }
    }

    private func schemaRow(_ schema: ArrManagedIndexer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(schema.name ?? schema.implementationName ?? "Unknown")
                .font(.body)

            HStack(spacing: 6) {
                if let implementationName = schema.implementationName {
                    Text(implementationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let protocolValue = schema.protocol {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Label(protocolValue.displayName, systemImage: protocolValue.systemImage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DirectIndexerEditorView: View {
    enum Mode {
        case add(ArrManagedIndexer)
        case edit(ArrManagedIndexer)

        var seed: ArrManagedIndexer {
            switch self {
            case .add(let schema), .edit(let schema):
                schema
            }
        }

        var buttonTitle: String {
            switch self {
            case .add:
                "Add"
            case .edit:
                "Save"
            }
        }

        var navigationTitle: String {
            switch self {
            case .add(let schema):
                schema.name ?? "Add Indexer"
            case .edit(let indexer):
                indexer.name ?? "Edit Indexer"
            }
        }
    }

    let profile: ArrServiceProfile
    let serviceType: ArrServiceType
    let viewModel: ArrIndexerManagementViewModel
    let mode: Mode
    let linkedApplication: ProwlarrApplication?
    var onSaved: (() -> Void)?

    @State private var indexerName: String
    @State private var priority: Int
    @State private var enableRss: Bool
    @State private var enableAutomaticSearch: Bool
    @State private var enableInteractiveSearch: Bool
    @State private var showAdvanced = false
    @State private var fieldValues: [String: ArrIndexerFieldValue]
    @State private var isSaving = false

    init(
        profile: ArrServiceProfile,
        serviceType: ArrServiceType,
        viewModel: ArrIndexerManagementViewModel,
        mode: Mode,
        linkedApplication: ProwlarrApplication? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.serviceType = serviceType
        self.viewModel = viewModel
        self.mode = mode
        self.linkedApplication = linkedApplication
        self.onSaved = onSaved

        let seed = mode.seed
        _indexerName = State(initialValue: seed.name ?? "")
        _priority = State(initialValue: seed.priority ?? 25)
        _enableRss = State(initialValue: seed.enableRss)
        _enableAutomaticSearch = State(initialValue: seed.enableAutomaticSearch)
        _enableInteractiveSearch = State(initialValue: seed.enableInteractiveSearch)

        var defaults: [String: ArrIndexerFieldValue] = [:]
        for field in seed.fields ?? [] {
            if let name = field.name, let value = field.value {
                defaults[name] = value
            }
        }
        _fieldValues = State(initialValue: defaults)
    }

    private var visibleFields: [ArrIndexerField] {
        (mode.seed.fields ?? []).filter { field in
            guard field.hidden != "hidden", field.type != "info" else { return false }
            if !showAdvanced && field.advanced == true {
                return false
            }
            return true
        }
    }

    private var infoFields: [ArrIndexerField] {
        (mode.seed.fields ?? []).filter { $0.type == "info" && $0.hidden != "hidden" }
    }

    private var hasAdvancedFields: Bool {
        (mode.seed.fields ?? []).contains { $0.advanced == true && $0.hidden != "hidden" && $0.type != "info" }
    }

    var body: some View {
        Form {
            if let linkedApplication {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Managed by Prowlarr", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text(linkedApplicationWarningText(for: linkedApplication))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                LabeledContent("Name") {
                    TextField("Indexer name", text: $indexerName)
                        .multilineTextAlignment(.trailing)
                }

                Stepper("Priority: \(priority)", value: $priority, in: 1...50)

                Toggle("RSS", isOn: $enableRss)
                Toggle("Automatic Search", isOn: $enableAutomaticSearch)
                Toggle("Interactive Search", isOn: $enableInteractiveSearch)
            } header: {
                Text("General")
            } footer: {
                Text("These switches control how \(profile.displayName) uses this indexer.")
            }

            if !infoFields.isEmpty {
                Section {
                    ForEach(Array(infoFields.enumerated()), id: \.offset) { _, field in
                        if let text = field.value?.displayString {
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !visibleFields.isEmpty {
                Section("Configuration") {
                    ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                        DirectIndexerFieldRow(
                            field: field,
                            fieldValues: $fieldValues
                        )
                    }
                }
            }

            if hasAdvancedFields {
                Section {
                    Toggle("Show Advanced Settings", isOn: $showAdvanced)
                }
            }

            if let error = viewModel.error(for: profile.id) {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(mode.navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(mode.buttonTitle) {
                        Task { await save() }
                    }
                    .disabled(indexerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func linkedApplicationWarningText(for application: ProwlarrApplication) -> String {
        let appName = application.name ?? linkedApplicationDisplayName
        let syncLevel = application.syncLevel?.displayName ?? "Sync"
        return "\(appName) is linked to Prowlarr with \(syncLevel). Local indexer changes in \(profile.displayName) may be overwritten the next time Prowlarr syncs."
    }

    private var linkedApplicationDisplayName: String {
        switch serviceType {
        case .sonarr:
            "Sonarr"
        case .radarr:
            "Radarr"
        case .prowlarr:
            "Prowlarr"
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let updatedFields = (mode.seed.fields ?? []).map { field -> ArrIndexerField in
            guard let name = field.name, let newValue = fieldValues[name] else { return field }
            return ArrIndexerField(
                order: field.order,
                name: field.name,
                label: field.label,
                unit: field.unit,
                helpText: field.helpText,
                helpTextWarning: field.helpTextWarning,
                helpLink: field.helpLink,
                value: newValue,
                type: field.type,
                advanced: field.advanced,
                selectOptions: field.selectOptions,
                selectOptionsProviderAction: field.selectOptionsProviderAction,
                section: field.section,
                hidden: field.hidden,
                placeholder: field.placeholder,
                isFloat: field.isFloat
            )
        }

        let tagsValue: [Int]?
        switch mode {
        case .add:
            tagsValue = []
        case .edit:
            tagsValue = mode.seed.tags
        }

        let candidate = ArrManagedIndexer(
            id: mode.seed.id,
            name: indexerName.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: updatedFields,
            implementationName: mode.seed.implementationName,
            implementation: mode.seed.implementation,
            configContract: mode.seed.configContract,
            infoLink: mode.seed.infoLink,
            message: mode.seed.message,
            tags: tagsValue,
            presets: mode.seed.presets,
            enableRss: enableRss,
            enableAutomaticSearch: enableAutomaticSearch,
            enableInteractiveSearch: enableInteractiveSearch,
            supportsRss: mode.seed.supportsRss,
            supportsSearch: mode.seed.supportsSearch,
            protocol: mode.seed.protocol,
            priority: priority,
            seasonSearchMaximumSingleEpisodeAge: mode.seed.seasonSearchMaximumSingleEpisodeAge,
            downloadClientId: mode.seed.downloadClientId
        )

        let saved: Bool
        switch mode {
        case .add:
            saved = await viewModel.addIndexer(candidate, for: profile.id, serviceType: serviceType)
            if saved {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Indexer Added",
                    message: "\(candidate.name ?? "Indexer") has been added to \(profile.displayName)."
                )
            }
        case .edit:
            saved = await viewModel.updateIndexer(candidate, for: profile.id, serviceType: serviceType)
            if saved {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Indexer Updated",
                    message: "\(candidate.name ?? "Indexer") has been updated in \(profile.displayName)."
                )
            }
        }

        if saved {
            onSaved?()
        }
    }
}

private struct DirectIndexerFieldRow: View {
    let field: ArrIndexerField
    @Binding var fieldValues: [String: ArrIndexerFieldValue]

    var body: some View {
        let label = field.label ?? field.name ?? ""
        let key = field.name ?? ""

        VStack(alignment: .leading, spacing: 6) {
            switch field.type {
            case "checkbox":
                Toggle(label, isOn: boolBinding(for: key))

            case "select":
                if let options = field.selectOptions, !options.isEmpty {
                    Picker(label, selection: intBinding(for: key)) {
                        ForEach(options) { option in
                            Text(option.name ?? "Unknown")
                                .tag(option.value ?? 0)
                        }
                    }
                }

            case "password":
                LabeledContent(label) {
                    SecureField(field.placeholder ?? label, text: stringBinding(for: key))
                        .multilineTextAlignment(.trailing)
                }

            case "number":
                LabeledContent(label) {
                    TextField(field.placeholder ?? label, text: numberStringBinding(for: key, isFloat: field.isFloat == true))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(field.isFloat == true ? .decimalPad : .numberPad)
                        #endif
                }

            default:
                LabeledContent(label) {
                    TextField(field.placeholder ?? label, text: stringBinding(for: key))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            if let helpText = field.helpText?.trawlStrippingHTML, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let value) = fieldValues[key] {
                    return value
                }
                return fieldValues[key]?.displayString ?? ""
            },
            set: { fieldValues[key] = .string($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let value) = fieldValues[key] {
                    return value
                }
                return false
            },
            set: { fieldValues[key] = .bool($0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                fieldValues[key]?.intValue ?? 0
            },
            set: { fieldValues[key] = .int($0) }
        )
    }

    private func numberStringBinding(for key: String, isFloat: Bool) -> Binding<String> {
        Binding(
            get: {
                switch fieldValues[key] {
                case .int(let value):
                    return value == 0 ? "" : String(value)
                case .double(let value):
                    return value == 0 ? "" : String(value)
                case .string(let value):
                    return value
                default:
                    return ""
                }
            },
            set: { value in
                if value.isEmpty {
                    fieldValues[key] = nil
                } else if isFloat {
                    if let parsed = Double(value) {
                        fieldValues[key] = .double(parsed)
                    }
                } else {
                    if let parsed = Int(value) {
                        fieldValues[key] = .int(parsed)
                    }
                }
            }
        )
    }
}

private extension String {
    var trawlStrippingHTML: String {
        var text = self
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</?p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</?div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
