//
//  SetupCheckView.swift
//  Trawl
//
//  The configuration audit's one screen, on every chrome.
//

import SwiftUI
import SwiftData

/// Setup Check: what the configuration audit found, and the way to each fix.
///
/// One screen everywhere. Beside a detail column (iPad, the open iPhone Duo, Mac) a
/// row selects its finding into the pane; at compact width it pushes the same
/// `SetupCheckFindingView`. The phone used to get a separate step-by-step wizard
/// instead, presented as a sheet from the System hub and pushed from search, so the
/// same feature looked and behaved differently depending on how you reached it.
struct SetupCheckView: View {
    /// Opened *about* one finding - from the Indexers nudge, say - rather than about
    /// the setup as a whole. That finding comes up first: selected beside a detail
    /// column, pushed on a phone with the rest of the check one Back away.
    var focusedKind: ConfigurationIssueKind? = nil

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
    /// The finding pushed at compact width. A binding rather than destination-closure
    /// links so a focused opening can push it programmatically too.
    @State private var pushedIssueID: String?
    @State private var hasAppliedFocus = false

    private var browser: SetupCheckBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var allIssues: [ConfigurationIssue] { auditStore.issues }

    private var filteredIssues: [ConfigurationIssue] {
        browser.filter.filter(issues: allIssues)
    }

    private func issue(withID id: String) -> (issue: ConfigurationIssue, isIgnored: Bool)? {
        if let found = allIssues.first(where: { $0.id == id }) { return (found, false) }
        if let ignored = auditStore.ignoredIssues.first(where: { $0.id == id }) { return (ignored, true) }
        return nil
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

    private var summary: SetupCheckSummary {
        SetupCheckSummary(
            coverage: coverage,
            hasCompletedAnAudit: auditStore.hasCompletedAnAudit,
            problems: auditStore.problems.count,
            unknowns: auditStore.unknowns.count,
            notes: auditStore.notes.count
        )
    }

    var body: some View {
        Group {
            if showsDetailPane {
                TrawlListDetailPanes(title: "Setup Check", subtitle: summary.subtitle) {
                    listColumn
                } detail: {
                    selectedIssueDetail
                }
            } else {
                listColumn
                    .navigationTitle("Setup Check")
                    .navigationSubtitle(summary.subtitle)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationDestination(item: $pushedIssueID) { id in
                        pushedFinding(id: id)
                    }
            }
        }
        .refreshesConfigurationAudit()
        .onChange(of: allIssues.map(\.id)) { _, _ in
            browser.reconcileSelection(issues: allIssues)
            applyFocusIfNeeded()
        }
        .onAppear {
            browser.reconcileSelection(issues: allIssues)
            applyFocusIfNeeded()
        }
    }

    /// Brings the finding the caller asked about forward, once. Waits for the audit
    /// if it has not found it yet, so a sheet opened before the first audit finishes
    /// still lands on it.
    private func applyFocusIfNeeded() {
        guard !hasAppliedFocus, let focusedKind,
              let focused = allIssues.first(where: { $0.kind == focusedKind }) else { return }
        hasAppliedFocus = true
        browser.filter = .all
        if showsDetailPane {
            browser.selectedIssueID = focused.id
        } else {
            pushedIssueID = focused.id
        }
    }

    // MARK: - List Column

    @ViewBuilder
    private var listColumn: some View {
        listContent
            // All of this column's header chrome in one top inset, the way Series,
            // Movies and Downloads do it. Attached to the container and not the
            // `List`, so a filter that matches nothing cannot take the bar with it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if SetupCheckFilter.available(for: allIssues).count > 1 {
                    filterBar
                        .padding(.vertical, 4)
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
                    .accessibilityIdentifier("setup-check-toolbar-recheck")
                }
            }
    }

    @ViewBuilder
    private var listContent: some View {
        if coverage == .nothingConfigured {
            nothingToCheck
        } else if auditStore.isAuditing && !auditStore.hasCompletedAnAudit {
            TrawlInitialLoadingView(label: "Checking your setup")
        } else {
            // Selection only beside a detail column. An unguarded `List(selection:)`
            // on a phone swallows row taps, so compact gets a plain list whose rows
            // push instead.
            if showsDetailPane {
                @Bindable var browser = self.browser
                List(selection: $browser.selectedIssueID) { sections }
                    .scrollContentBackground(.hidden)
            } else {
                List { sections }
                    .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            SetupCheckSummaryHeader(
                summary: summary,
                lastChecked: auditStore.lastAuditDate,
                isAuditing: auditStore.isAuditing,
                onRecheck: { await refreshAudit() }
            )
        }
        .listRowBackground(Color.clear)

        if filteredIssues.isEmpty && !allIssues.isEmpty {
            Section {
                Text("Nothing matches the \(browser.filter.rawValue) filter.")
                    .foregroundStyle(.secondary)
            }
        }

        severitySection(.problem, title: "Problems")
        severitySection(.unknown, title: "Could Not Verify")
        severitySection(.note, title: "Worth Knowing")

        if !auditStore.ignoredIssues.isEmpty {
            ignoredSection
        }
    }

    @ViewBuilder
    private func severitySection(_ severity: ConfigurationIssueSeverity, title: String) -> some View {
        let issues = filteredIssues.filter { $0.severity == severity }
        if !issues.isEmpty {
            Section("\(title) (\(issues.count))") {
                ForEach(issues) { issue in
                    row(for: issue, isIgnored: false)
                }
            }
        }
    }

    /// Ignored findings, listed rather than lost. They used to drop out of the audit
    /// for the rest of the session with no way to see them or take the decision back.
    private var ignoredSection: some View {
        Section {
            ForEach(auditStore.ignoredIssues) { issue in
                row(for: issue, isIgnored: true)
            }
            Button("Stop Ignoring All") {
                withAnimation { auditStore.restoreDismissed() }
            }
            .accessibilityIdentifier("setup-check-restore-all")
        } header: {
            Text("Ignored (\(auditStore.ignoredIssues.count))")
        }
    }

    @ViewBuilder
    private func row(for issue: ConfigurationIssue, isIgnored: Bool) -> some View {
        let label = SetupCheckFindingRow(issue: issue, isIgnored: isIgnored)
        if showsDetailPane {
            label
                .tag(issue.id)
                .contextMenu { rowActions(for: issue, isIgnored: isIgnored) }
        } else {
            Button {
                pushedIssueID = issue.id
            } label: {
                HStack {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { rowActions(for: issue, isIgnored: isIgnored) }
        }
    }

    @ViewBuilder
    private func rowActions(for issue: ConfigurationIssue, isIgnored: Bool) -> some View {
        if isIgnored {
            Button("Stop Ignoring", systemImage: "eye") { restore(issue) }
        } else {
            Button("Ignore This Finding", systemImage: "eye.slash", role: .destructive) { ignore(issue) }
        }
        Button("Check Again", systemImage: "arrow.clockwise") {
            Task { await refreshAudit() }
        }
    }

    /// Sits above whatever the column shows. Only severities with something in them
    /// are offered: a segment that can only show an empty list is not a choice.
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
            items: SetupCheckFilter.available(for: allIssues).map {
                TrawlSegmentBarItem(filterTitle(for: $0), value: $0)
            }
        )
    }

    private func filterTitle(for filter: SetupCheckFilter) -> String {
        "\(filter.rawValue) (\(filter.filter(issues: allIssues).count))"
    }

    /// An empty setup, which is not the same thing as a clean one.
    private var nothingToCheck: some View {
        ServiceSetupView(
            title: "Nothing to Check Yet",
            message: "Setup Check audits how your services are wired together. Add a server in Settings and it will be checked here.",
            systemImage: "checklist"
        )
        .scrollableUnavailableState()
    }

    // MARK: - Finding

    @ViewBuilder
    private var selectedIssueDetail: some View {
        if let id = browser.selectedIssueID, let match = issue(withID: id) {
            finding(match.issue, isIgnored: match.isIgnored)
                .id(match.issue.id)
        } else if coverage != .nothingConfigured && allIssues.isEmpty && auditStore.hasCompletedAnAudit {
            allClearDetail
        } else {
            listDetailPlaceholder("Select a Finding", systemImage: "checklist")
        }
    }

    @ViewBuilder
    private func pushedFinding(id: String) -> some View {
        if let match = issue(withID: id) {
            finding(match.issue, isIgnored: match.isIgnored)
        } else {
            // Fixed and re-checked while it was open: say so instead of showing a
            // finding the audit no longer reports.
            ContentUnavailableView(
                "Fixed",
                systemImage: "checkmark.circle",
                description: Text("The last check no longer found this.")
            )
        }
    }

    private func finding(_ issue: ConfigurationIssue, isIgnored: Bool) -> some View {
        SetupCheckFindingView(
            issue: issue,
            isIgnored: isIgnored,
            lastChecked: auditStore.lastAuditDate,
            onIgnore: { ignore(issue) },
            onRestore: { restore(issue) },
            onRecheck: { await refreshAudit() }
        )
        .environment(serviceManager)
        .environment(sabnzbdServiceManager)
        .environment(seerrServiceManager)
    }

    private var allClearDetail: some View {
        ContentUnavailableView {
            Label("Everything Is Wired Up", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } description: {
            if let audited = coverage.auditedSummary {
                Text("Trawl checked \(audited) and found nothing wrong with how they are pointed at each other.")
            }
        } actions: {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await refreshAudit() }
            }
            .buttonStyle(.bordered)
        }
        .moreDestinationBackground(.systemHub)
    }

    // MARK: - Actions

    private func ignore(_ issue: ConfigurationIssue) {
        withAnimation {
            auditStore.dismiss(issue)
            browser.reconcileSelection(issues: allIssues)
        }
    }

    private func restore(_ issue: ConfigurationIssue) {
        withAnimation {
            auditStore.restore(issue)
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

// MARK: - Sheet

/// Setup Check opened from somewhere that is not its own row: a contextual banner,
/// the notifications card, the Indexers nudge. The same screen as the System row
/// pushes, in a stack of its own with a Done button.
struct SetupCheckSheet: View {
    var focusedKind: ConfigurationIssueKind? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SetupCheckView(focusedKind: focusedKind)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(platformReadOnlySheetDismissTitle) { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480)
        #endif
    }
}

// MARK: - Summary

/// The state of the whole check in one value, so the header, the subtitle and the
/// System hub row cannot disagree about it.
struct SetupCheckSummary: Equatable {
    let coverage: SetupCheckCoverage
    let hasCompletedAnAudit: Bool
    let problems: Int
    let unknowns: Int
    let notes: Int

    enum Status: Equatable {
        case nothingConfigured
        case checking
        case problems
        case incomplete
        case clear
    }

    var status: Status {
        // Ahead of the audit's own state: with nothing configured the audit finishes
        // at once with no findings, and "all clear" would be the answer.
        if coverage == .nothingConfigured { return .nothingConfigured }
        guard hasCompletedAnAudit else { return .checking }
        if problems > 0 { return .problems }
        // A check that could not be run is not a check that passed.
        if unknowns > 0 { return .incomplete }
        return .clear
    }

    var subtitle: String {
        switch status {
        case .nothingConfigured: "Nothing to Check"
        case .checking: "Checking…"
        case .problems: problems == 1 ? "1 Problem" : "\(problems) Problems"
        case .incomplete: unknowns == 1 ? "1 Unverified" : "\(unknowns) Unverified"
        case .clear: notes == 0 ? "All Clear" : (notes == 1 ? "1 Note" : "\(notes) Notes")
        }
    }

    var headline: String {
        switch status {
        case .nothingConfigured: "Nothing to Check Yet"
        case .checking: "Checking Your Setup"
        case .problems: problems == 1 ? "1 Problem Needs Fixing" : "\(problems) Problems Need Fixing"
        case .incomplete: "Setup Check Incomplete"
        case .clear: "Everything Is Wired Up"
        }
    }

    var message: String {
        switch status {
        case .nothingConfigured:
            "Add a server in Settings and it will be checked here."
        case .checking:
            "Reading how your services are pointed at each other."
        case .problems:
            "Each one stops something working. Open it to see why and where to fix it."
        case .incomplete:
            "Trawl could not read every service, so this is not a pass yet. Restore the connections below and check again."
        case .clear:
            if let audited = coverage.auditedSummary {
                "Trawl checked \(audited) and found nothing wrong with how they are pointed at each other."
            } else {
                "Trawl could not find anything wrong with how your services are pointed at each other."
            }
        }
    }

    var systemImage: String {
        switch status {
        case .nothingConfigured: "checklist"
        case .checking: "stethoscope"
        case .problems: "exclamationmark.triangle.fill"
        case .incomplete: "questionmark.diamond.fill"
        case .clear: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch status {
        case .nothingConfigured, .checking: .secondary
        case .problems: .orange
        case .incomplete: .yellow
        case .clear: .green
        }
    }
}

/// The top of the list: where the check stands, what it covered, when it ran, and
/// the button to run it again. The summary used to appear only when there was
/// nothing wrong, so a list of findings never said what had been checked or when.
private struct SetupCheckSummaryHeader: View {
    let summary: SetupCheckSummary
    let lastChecked: Date?
    let isAuditing: Bool
    let onRecheck: () async -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: summary.systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(summary.tint)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))

            Text(summary.headline)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(summary.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if let lastChecked {
                    Text("Checked \(lastChecked, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await onRecheck() }
                } label: {
                    if isAuditing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Checking…")
                        }
                    } else {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAuditing)
                .accessibilityIdentifier("setup-check-recheck")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-check-summary")
    }
}

// MARK: - Row

/// One finding in the list. Names the server it is about - "Bazarr 4K", not just
/// "Bazarr" - since with a pair configured that is the part that says where to look.
struct SetupCheckFindingRow: View {
    let issue: ConfigurationIssue
    var isIgnored = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.severity.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(isIgnored ? Color.secondary : issue.severity.tint)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(issue.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isIgnored ? .secondary : .primary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    serverBadge
                }

                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configuration-issue-\(issue.kind.rawValue)")
    }

    private var serverBadge: some View {
        let color = issue.subject.serviceType?.serviceIdentity.brandColor ?? .secondary
        return Text(issue.subject.displayName)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
