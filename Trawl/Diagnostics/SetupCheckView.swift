//
//  SetupCheckView.swift
//  Trawl
//
//  Modern 3-column split view for the configuration audit on macOS and iPadOS.
//

import SwiftUI
import SwiftData

struct SetupCheckView: View {
    @Environment(ConfigurationAuditStore.self) private var auditStore
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager: CleanuparrServiceManager?
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(SetupCheckBrowserState.self) private var sharedBrowser: SetupCheckBrowserState?
    @State private var localBrowser = SetupCheckBrowserState()

    private var browser: SetupCheckBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var allIssues: [ConfigurationIssue] {
        auditStore.issues
    }

    private var filteredIssues: [ConfigurationIssue] {
        browser.filter.filter(issues: allIssues)
    }

    private var selectedIssue: ConfigurationIssue? {
        browser.selectedIssueID.flatMap { id in allIssues.first { $0.id == id } }
    }

    /// What an empty result may claim - see `SetupCheckCoverage`. Built from the
    /// same configuration the audit reads, so an all-clear only names services the
    /// audit actually looked at, and an empty setup is never reported as a pass.
    private var coverage: SetupCheckCoverage {
        SetupCheckCoverage(
            arrServices: serviceManager.storedProfiles.compactMap(\.resolvedServiceType),
            hasQBittorrent: !qbittorrentServers.isEmpty,
            hasSABnzbd: !sabnzbdProfiles.isEmpty,
            hasSeerr: seerrServiceManager?.hasConfiguredProfile ?? false,
            hasCleanuparr: cleanuparrServiceManager?.hasConfiguredProfile ?? false
        )
    }

    private var trawlClientHosts: [DownloadClientLinkKind: [String]] {
        ConfigurationAuditInput.trawlClientHosts(
            qbittorrentServers: qbittorrentServers,
            sabnzbdProfiles: sabnzbdProfiles
        )
    }

    private var auditInputRevision: String {
        ConfigurationAuditInput.revision(
            arrServiceManager: serviceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager
        )
    }

    private var navigationSubtitle: String {
        // Ahead of the audit's own state: with nothing configured the audit finishes
        // at once with no findings, and "All Clear" would be the answer.
        if coverage == .nothingConfigured { return "Nothing to Check" }
        guard auditStore.hasCompletedAnAudit else { return "Checking…" }
        let problems = auditStore.problemCount
        if problems > 0 {
            return problems == 1 ? "1 Problem" : "\(problems) Problems"
        }
        if !auditStore.unknowns.isEmpty {
            let count = auditStore.unknowns.count
            return count == 1 ? "1 Unverified" : "\(count) Unverified"
        }
        if !auditStore.notes.isEmpty {
            let count = auditStore.notes.count
            return count == 1 ? "1 Note" : "\(count) Notes"
        }
        return "All Clear"
    }

    var body: some View {
        Group {
            if showsDetailPane {
                TrawlListDetailPanes(title: "Setup Check", subtitle: navigationSubtitle) {
                    issueList
                } detail: {
                    selectedIssueDetail
                }
            } else {
                compactContent
            }
        }
        .refreshesConfigurationAudit()
        .onChange(of: allIssues.map(\.id)) { _, _ in
            browser.reconcileSelection(issues: allIssues)
        }
        .onAppear {
            browser.reconcileSelection(issues: allIssues)
        }
    }

    // MARK: - List Column

    @ViewBuilder
    private var issueList: some View {
        @Bindable var browser = self.browser
        VStack(spacing: 0) {
            if !allIssues.isEmpty {
                filterBar
                    .padding(.vertical, 4)
            }

            if coverage == .nothingConfigured {
                nothingToCheck
            } else if auditStore.isAuditing && allIssues.isEmpty {
                ProgressView("Auditing configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allIssues.isEmpty && auditStore.hasCompletedAnAudit {
                allClearListSummary
            } else if filteredIssues.isEmpty {
                ContentUnavailableView(
                    "No Findings",
                    systemImage: "checkmark.circle",
                    description: Text("No items match the '\(browser.filter.rawValue)' filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $browser.selectedIssueID) {
                    let problems = filteredIssues.filter { $0.severity == .problem }
                    if !problems.isEmpty {
                        Section("Problems (\(problems.count))") {
                            ForEach(problems) { issue in
                                issueRow(issue)
                                    .tag(issue.id)
                            }
                        }
                    }

                    let unknowns = filteredIssues.filter { $0.severity == .unknown }
                    if !unknowns.isEmpty {
                        Section("Could Not Verify (\(unknowns.count))") {
                            ForEach(unknowns) { issue in
                                issueRow(issue)
                                    .tag(issue.id)
                            }
                        }
                    }

                    let notes = filteredIssues.filter { $0.severity == .note }
                    if !notes.isEmpty {
                        Section("Worth Knowing (\(notes.count))") {
                            ForEach(notes) { issue in
                                issueRow(issue)
                                    .tag(issue.id)
                            }
                        }
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .moreDestinationBackground(.systemHub)
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button {
                    Task { await refreshAudit() }
                } label: {
                    if auditStore.isAuditing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(auditStore.isAuditing)
                .accessibilityIdentifier("configuration-wizard-recheck")
            }
        }
    }

    /// Sits above whatever the list shows - "No Findings" included - rather than
    /// riding on the list itself. `SeerrIssueListView` insets its bar on the `List`,
    /// but a filter that matches nothing here swaps the list for a placeholder, and a
    /// bar attached to the list would leave with it: the user stranded on a filter
    /// they could no longer change.
    private var filterBar: some View {
        TrawlSegmentBar(
            "Filter",
            selection: Binding(
                get: { browser.filter },
                set: { newFilter in
                    withAnimation {
                        browser.filter = newFilter
                        browser.reconcileSelection(issues: allIssues)
                    }
                }
            ),
            items: SetupCheckFilter.allCases.map { TrawlSegmentBarItem(filterTitle(for: $0), value: $0) }
        )
    }

    private func filterTitle(for filter: SetupCheckFilter) -> String {
        switch filter {
        case .all:
            "All (\(allIssues.count))"
        case .problems:
            "Problems (\(auditStore.problems.count))"
        case .unverified:
            "Unverified (\(auditStore.unknowns.count))"
        case .notes:
            "Notes (\(auditStore.notes.count))"
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: ConfigurationIssue) -> some View {
        Button {
            browser.selectedIssueID = issue.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                severityIcon(for: issue)
                    .font(.system(size: 20))
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(issue.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        if let serviceType = issue.subject.serviceType {
                            Text(serviceType.displayName)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(serviceType.serviceIdentity.brandColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(serviceType.serviceIdentity.brandColor)
                        } else {
                            Text(issue.subject.displayName)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(issue.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            browser.selectedIssueID == issue.id
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configuration-issue-\(issue.kind.rawValue)")
        .contextMenu {
            Button("Ignore This Finding", systemImage: "eye.slash", role: .destructive) {
                auditStore.dismiss(issue)
                browser.reconcileSelection(issues: allIssues)
            }
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await refreshAudit() }
            }
        }
    }

    @ViewBuilder
    private func severityIcon(for issue: ConfigurationIssue) -> some View {
        switch issue.severity {
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "questionmark.diamond.fill")
                .foregroundStyle(.orange)
        case .note:
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var allClearListSummary: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.green)
                    Text("Everything Is Wired Up")
                        .font(.headline.weight(.semibold))
                    Text("Trawl could not find anything wrong with how your services are pointed at each other.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            // Names what the audit read, and nothing else. This section used to show
            // four hard-coded ticks - download clients, root folders, indexer sync,
            // categories - whatever was actually configured.
            if let summary = coverage.auditedSummary {
                Section("Checked") {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
    }

    /// An empty setup, which is not the same thing as a clean one. List column only:
    /// the detail column keeps its placeholder, as every other screen's does when its
    /// service is not set up.
    private var nothingToCheck: some View {
        ServiceSetupView(
            title: "Nothing to Check Yet",
            message: "Setup Check audits how your services are wired together. Add a server in Settings and it will be checked here.",
            systemImage: "checklist"
        )
        .scrollableUnavailableState()
    }

    // MARK: - Detail Column

    @ViewBuilder
    private var selectedIssueDetail: some View {
        if let issue = selectedIssue {
            SetupCheckDetailPane(
                issue: issue,
                onDismiss: {
                    auditStore.dismiss(issue)
                    browser.reconcileSelection(issues: allIssues)
                },
                onRecheck: { await refreshAudit() }
            )
            .id(issue.id)
            .environment(serviceManager)
            .environment(sabnzbdServiceManager)
            .environment(seerrServiceManager)
        } else if coverage != .nothingConfigured && allIssues.isEmpty && auditStore.hasCompletedAnAudit {
            allClearDetailPane
        } else {
            listDetailPlaceholder("Select a Finding", systemImage: "checklist")
        }
    }

    private var allClearDetailPane: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)

                    Text("Everything Is Wired Up")
                        .font(.title2.weight(.bold))

                    // The compact wizard's sentence. This one used to list download
                    // clients, indexer sync, categories and remote paths as checked,
                    // whatever was actually configured.
                    Text("Trawl could not find anything wrong with how your services are pointed at each other.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .padding(.vertical, 24)

                // What was audited, in place of two badges asserting every service was
                // operational - which the audit never measures.
                if let summary = coverage.auditedSummary {
                    Label("Checked \(summary)", systemImage: "checklist")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                Button {
                    Task { await refreshAudit() }
                } label: {
                    Label("Run Check Again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 12)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .moreDestinationBackground(.systemHub)
        .navigationTitle("Audit Summary")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Compact Mode (iPhone)

    /// The phone keeps the wizard, except when there is nothing to audit: the
    /// wizard's own terminal state for "no findings" is "Everything Is Wired Up",
    /// which is exactly the claim an empty setup must not make.
    @ViewBuilder
    private var compactContent: some View {
        if coverage == .nothingConfigured {
            nothingToCheck
                .moreDestinationBackground(.systemHub)
                .navigationTitle("Setup Check")
        } else {
            ConfigurationWizardView(
                issues: auditStore.issues,
                onDismissIssue: { auditStore.dismiss($0) },
                onRecheck: { await refreshAudit() },
                presentation: .screen
            )
            .environment(serviceManager)
        }
    }

    private func refreshAudit() async {
        await auditStore.refresh(
            serviceManager: serviceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager,
            sabnzbdServiceManager: sabnzbdServiceManager,
            inputRevision: auditInputRevision
        )
        browser.reconcileSelection(issues: allIssues)
    }
}

// MARK: - Detail Pane Component

private struct SetupCheckDetailPane: View {
    let issue: ConfigurationIssue
    let onDismiss: () -> Void
    let onRecheck: () async -> Void

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?

    @State private var isApplyingAction = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                descriptionCard
                recommendedActionCard
                actionsCard
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .moreDestinationBackground(.systemHub)
        .navigationTitle("Finding Details")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button(role: .destructive, action: onDismiss) {
                    Label("Ignore", systemImage: "eye.slash")
                }
                Button {
                    Task { await onRecheck() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    Image(systemName: issue.systemImage)
                        .font(.title)
                        .foregroundStyle(severityColor)
                        .frame(width: 48, height: 48)
                        .background(severityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(severityLabel)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(severityColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(severityColor)

                            if let serviceType = issue.subject.serviceType {
                                Text(serviceType.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(serviceType.serviceIdentity.brandColor.opacity(0.18), in: Capsule())
                                    .foregroundStyle(serviceType.serviceIdentity.brandColor)
                            }
                        }

                        Text(issue.subject.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            Text(issue.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Diagnostic Information", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(issue.detail)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if let discriminator = issue.discriminator {
                HStack(spacing: 4) {
                    Text("Target:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(discriminator)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var recommendedActionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recommended Resolution", systemImage: "wand.and.sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let repair = issue.fix.guidedRepair, let actionTitle = issue.fix.actionTitle {
                NavigationLink {
                    ConfigurationCategoryRepairView(repair: repair, onApplied: onRecheck)
                        .environment(serviceManager)
                        .environment(sabnzbdServiceManager)
                } label: {
                    HStack {
                        Image(systemName: "wand.and.sparkles")
                        Text(actionTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
                .accessibilityIdentifier("configuration-wizard-guided-fix")

                if let destination = issue.fix.destination {
                    NavigationLink {
                        fixDestination(destination)
                    } label: {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("Change It Myself")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("configuration-wizard-fix")
                }
            } else if let destination = issue.fix.destination, let actionTitle = issue.fix.actionTitle {
                NavigationLink {
                    fixDestination(destination)
                } label: {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver")
                        Text(actionTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("configuration-wizard-fix")
            }

            if !issue.fix.guidance.isEmpty {
                Text(issue.fix.guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Triage", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 12) {
                Button(role: .destructive, action: onDismiss) {
                    Label("Ignore This Finding", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await onRecheck() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("configuration-wizard-recheck")
            }

            Text("Ignoring hides this finding until Trawl is restarted. It does not alter server settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var severityColor: Color {
        switch issue.severity {
        case .problem: .orange
        case .unknown: .orange
        case .note: .blue
        }
    }

    private var severityLabel: String {
        switch issue.severity {
        case .problem: "PROBLEM"
        case .unknown: "COULD NOT VERIFY"
        case .note: "WORTH KNOWING"
        }
    }

    @ViewBuilder
    private func fixDestination(_ destination: ConfigurationFixDestination) -> some View {
        switch destination {
        case .downloadClientsManagement:
            ArrDownloadClientListView(serviceType: .sonarr)
                .environment(serviceManager)
        case .arrDownloadClients(let serviceType, let instanceID):
            ArrDownloadClientListView(serviceType: serviceType, initialInstanceID: instanceID)
                .environment(serviceManager)
        case .rootFolders(let instanceID):
            ArrRootFoldersView(initialInstanceID: instanceID)
                .environment(serviceManager)
        case .prowlarrIndexers:
            ProwlarrIndexerListView()
                .environment(serviceManager)
        case .prowlarrApplications:
            ProwlarrApplicationsListView()
                .environment(serviceManager)
        case .bazarrLinkedApplications(let instanceID):
            BazarrLinkedApplicationsListView(initialInstanceID: instanceID)
                .environment(serviceManager)
        case .bazarrLanguageProfiles:
            BazarrLanguageProfilesView()
                .environment(serviceManager)
        case .bazarrProviders:
            BazarrProvidersView()
                .environment(serviceManager)
        case .serviceSettings(let serviceType, let instanceID):
            ArrServiceSettingsView(serviceType: serviceType, initialProfileID: instanceID)
                .environment(serviceManager)
        case .arrRemotePathMappings:
            ArrRemotePathMappingListView()
                .environment(serviceManager)
        case .arrHealth:
            ArrHealthView()
                .environment(serviceManager)
        case .seerrLinkedApplications:
            if let client = seerrServiceManager?.activeClient {
                SeerrLinkedApplicationsView(apiClient: client)
            } else {
                ServiceErrorView(
                    title: "Seerr is not connected",
                    message: "Reconnect Seerr from Settings, then run the setup check again.",
                    systemImage: "network.slash"
                )
            }
        case .cleanuparr:
            CleanuparrDashboardView()
        case .sabnzbdCategories:
            if let sabnzbdServiceManager {
                SABnzbdCategoriesView()
                    .environment(sabnzbdServiceManager)
            } else {
                ServiceErrorView(
                    title: "SABnzbd is not connected",
                    message: "Reconnect SABnzbd from Settings, then run the setup check again.",
                    systemImage: "network.slash"
                )
            }
        }
    }
}
