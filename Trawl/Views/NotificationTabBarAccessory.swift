import SwiftUI

#if os(iOS)
struct SetTabChromeHiddenKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var setTabChromeHidden: (Bool) -> Void {
        get { self[SetTabChromeHiddenKey.self] }
        set { self[SetTabChromeHiddenKey.self] = newValue }
    }
}

struct NotificationTabBarAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(SyncService.self) private var syncService

    /// Downloads that need a human, using the exact rule the Downloads Issues
    /// segment renders — see `DownloadsViewModel.attentionItems(…)`.
    private var attentionItems: [DownloadListItem] {
        DownloadsViewModel.attentionItems(
            serviceManager: arrServiceManager,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs
        )
    }

    private var attentionCount: Int { attentionItems.count }

    private var latestNotification: NotificationLogEntry? {
        inAppNotificationCenter.recentNotifications.first
    }

    private var unreadCount: Int {
        inAppNotificationCenter.unreadCount
    }

    private var isInline: Bool {
        placement == .inline
    }

    private var runningImportJobs: [ActiveImportJob] {
        inAppNotificationCenter.activeImportJobs.filter { $0.status == .running }
    }

    private var primaryRunningJob: ActiveImportJob? {
        runningImportJobs.first
    }

    private var headline: String {
        // Failures outrank everything: the pill's whole promise is "something needs
        // you", and a stuck grab needs you more than a healthy import does.
        if attentionCount > 0 {
            return attentionCount == 1
                ? "1 download needs attention"
                : "\(attentionCount) downloads need attention"
        }
        if runningImportJobs.count > 1 {
            return "Importing \(runningImportJobs.count) jobs"
        }
        if let job = primaryRunningJob {
            let fileWord = job.fileCount == 1 ? "file" : "files"
            return "Importing \(job.fileCount) \(fileWord)"
        }
        if let latestNotification {
            return latestNotification.title
        }
        return "Notifications"
    }

    private var subtitle: String {
        if let failure = attentionItems.first {
            return attentionCount == 1
                ? failure.attentionDetail
                : "\(failure.attentionTitle) · and \(attentionCount - 1) more"
        }
        if runningImportJobs.count > 1 {
            let services = Set(runningImportJobs.map(\.serviceTitle)).sorted().joined(separator: " · ")
            return services.isEmpty ? "Imports in progress" : services
        }
        if let job = primaryRunningJob {
            return "\(job.serviceTitle) · \(job.primaryName)"
        }
        if let latestNotification {
            return "\(latestNotification.associatedServiceTitle) · \(latestNotification.timestamp.formatted(date: .abbreviated, time: .shortened))"
        } else if unreadCount == 1 {
            return "1 unread notification"
        } else if unreadCount > 1 {
            return "\(unreadCount) unread notifications"
        } else {
            return "No recent notifications"
        }
    }

    private var notificationAccessibilityValue: String {
        if attentionCount > 0 {
            let word = attentionCount == 1 ? "download needs" : "downloads need"
            return "\(attentionCount) \(word) attention"
        }
        if !runningImportJobs.isEmpty {
            let count = runningImportJobs.count
            let word = count == 1 ? "import" : "imports"
            return "\(count) \(word) in progress"
        }
        if unreadCount == 1 {
            return "1 unread notification"
        } else if unreadCount > 1 {
            return "\(unreadCount) unread notifications"
        } else {
            return "No unread notifications"
        }
    }

    private func presentRecentNotifications() {
        inAppNotificationCenter.showRecentNotifications()
        if inAppNotificationCenter.currentBanner != nil {
            inAppNotificationCenter.dismissCurrentBanner()
        }
    }

    var body: some View {
        Button {
            presentRecentNotifications()
        } label: {
            if isInline {
                inlineContent
            } else {
                expandedContent
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(swipeUpGesture)
        .accessibilityLabel("Notifications")
        .accessibilityValue(notificationAccessibilityValue)
    }

    private var swipeUpGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let verticalDistance = -value.translation.height
                let verticalVelocity = -value.predictedEndTranslation.height + value.translation.height
                if verticalDistance > 24 || verticalVelocity > 80 {
                    presentRecentNotifications()
                }
            }
    }

    private var inlineSummary: String {
        if attentionCount > 0 {
            return attentionCount == 1
                ? "1 download needs attention"
                : "\(attentionCount) downloads need attention"
        }
        if runningImportJobs.count > 1 {
            return "Importing \(runningImportJobs.count) jobs"
        }
        if let job = primaryRunningJob {
            let fileWord = job.fileCount == 1 ? "file" : "files"
            return "Importing \(job.fileCount) \(fileWord) · \(job.serviceTitle)"
        }
        if unreadCount >= 1, let latest = latestNotification {
            let count = unreadCount == 1 ? "1 unread" : "\(unreadCount) unread"
            return "\(count) · \(latest.associatedServiceTitle)"
        } else if unreadCount >= 1 {
            return unreadCount == 1 ? "1 unread" : "\(unreadCount) unread"
        } else if let latestNotification {
            return latestNotification.title
        } else {
            return "Notifications"
        }
    }

    private var inlineContent: some View {
        HStack(spacing: 8) {
            notificationIcon
                .font(.footnote.weight(.semibold))
                .foregroundStyle(iconTint)

            Text(inlineSummary)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Image(systemName: "chevron.up")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }

    private var expandedContent: some View {
        HStack(spacing: 12) {
            notificationIcon
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(iconTint)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Warning orange while something is failing, otherwise the usual accent tint.
    private var iconTint: AnyShapeStyle {
        attentionCount > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint)
    }

    private var notificationIcon: some View {
        Group {
            if attentionCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
            } else if inAppNotificationCenter.hasRunningImportJobs {
                Image(systemName: "tray.and.arrow.down.fill")
                    .symbolRenderingMode(.hierarchical)
            } else {
                Image(systemName: "bell.fill")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .overlay(alignment: .topTrailing) {
            if attentionCount > 0 {
                Text(attentionCount > 99 ? "99+" : "\(attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.orange, in: Capsule())
                    .offset(x: 10, y: -10)
                    .accessibilityHidden(true)
            } else if inAppNotificationCenter.hasRunningImportJobs {
                let count = inAppNotificationCenter.runningImportJobsCount
                Group {
                    if count > 1 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(.blue, in: Capsule())
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .repeat(.continuous))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(.blue, in: Circle())
                    }
                }
                .offset(x: 10, y: -10)
                .accessibilityHidden(true)
            } else if unreadCount > 0 {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.red, in: Capsule())
                    .offset(x: 10, y: -10)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension NotificationLogEntry {
    var associatedServiceTitle: String {
        let blob = "\(title) \(message)".lowercased()
        let tokens = Set(blob.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })

        if tokens.contains("sonarr") { return "Sonarr" }
        if tokens.contains("radarr") { return "Radarr" }
        if tokens.contains("prowlarr") { return "Prowlarr" }
        if tokens.contains("bazarr") { return "Bazarr" }
        if tokens.contains("seerr") || tokens.contains("overseerr") || tokens.contains("jellyseerr") { return "Seerr" }
        if tokens.contains("jellyfin") { return "Jellyfin" }
        if tokens.contains("qbittorrent") || tokens.contains("qbit") || tokens.contains("torrent") { return "qBittorrent" }
        return "Trawl"
    }
}
#endif

// MARK: - Recent Notifications Sheet

/// The two halves of the notification sheet. `activity` is the default and holds
/// the import/notification log; `actions` holds global service commands.
private enum NotificationSheetSection: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case actions = "Actions"

    var id: String { rawValue }

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}

struct RecentNotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(\.navigateToDownloadsTab) private var navigateToDownloadsTab
    /// Optional so the sheet still works anywhere a navigator isn't injected.
    @Environment(DownloadsNavigator.self) private var downloadsNavigator: DownloadsNavigator?
    @State private var selectedSection: NotificationSheetSection = .activity
    @State private var showClearConfirmation = false
    @State private var unreadSinceDate: Date = .distantPast
    @State private var queuedImportCommands: [QueuedImportCommand] = []
    @State private var runningActions: Set<NotificationQuickAction> = []

    private var notificationCount: Int { inAppNotificationCenter.recentNotifications.count }
    private var unreadNotificationCount: Int {
        inAppNotificationCenter.recentNotifications.filter { $0.timestamp > effectiveUnreadSinceDate }.count
    }
    private var effectiveUnreadSinceDate: Date {
        unreadSinceDate == .distantPast ? inAppNotificationCenter.lastReadDate : unreadSinceDate
    }

    private var activeJobs: [ActiveImportJob] {
        inAppNotificationCenter.activeImportJobs
    }

    /// Same list the tab-bar accessory counts, so the pill and this section agree.
    private var attentionItems: [DownloadListItem] {
        DownloadsViewModel.attentionItems(
            serviceManager: arrServiceManager,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs
        )
    }

    private var hasImportActivity: Bool {
        !activeJobs.isEmpty || !displayedImportCommands.isEmpty
    }

    private var displayedImportCommands: [QueuedImportCommand] {
        guard !activeJobs.isEmpty else { return queuedImportCommands }
        return queuedImportCommands.filter(\.isQueued)
    }

    private var subtitleText: String {
        if selectedSection == .actions {
            let count = availableActions.count
            return count == 1 ? "1 action available" : "\(count) actions available"
        }
        let running = inAppNotificationCenter.runningImportJobsCount
        let displayedCommands = displayedImportCommands
        let queued = displayedCommands.filter(\.isQueued).count
        let remoteActive = displayedCommands.count
        let active = running + remoteActive
        if active > 0 {
            let word = active == 1 ? "import" : "imports"
            if queued > 0 {
                return "\(active) \(word) active, \(queued) queued · \(unreadNotificationCount) unread"
            }
            return "\(active) \(word) in progress · \(unreadNotificationCount) unread"
        }
        return "\(unreadNotificationCount) unread"
    }

    var body: some View {
        AppSheetShell(
            title: "Notifications",
            subtitle: subtitleText,
            cancelTitle: "Close",
            cancelSystemImage: "xmark",
            showsCancel: false,
            usesInlineLargeTitle: true,
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Group {
                switch selectedSection {
                case .activity:
                    activityContent
                case .actions:
                    actionsContent
                }
            }
            .safeAreaInset(edge: .top) {
                sectionSegmentBar
            }
            .alert("Clear Notifications?", isPresented: $showClearConfirmation) {
                Button("Clear", role: .destructive) {
                    inAppNotificationCenter.clearRecentNotifications()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("All recent notifications will be removed.")
            }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        NotificationSettingsHubView()
                    } label: {
                        Label("Notification Settings", systemImage: "gearshape")
                    }
                }

                if selectedSection == .activity, notificationCount > 0 {
                    ToolbarSpacer(.flexible, placement: .topBarTrailing)
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Clear") {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            #endif
        }
        .onAppear {
            unreadSinceDate = inAppNotificationCenter.lastReadDate
            inAppNotificationCenter.markAllRead()
        }
        .task {
            await refreshQueuedImportCommands()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refreshQueuedImportCommands()
            }
        }
    }

    /// The default segment. Unchanged from before the Activity/Actions split:
    /// in-flight imports (local jobs plus remote manual-import commands) on top,
    /// then the recent notification log.
    @ViewBuilder
    private var activityContent: some View {
        let failures = attentionItems
        if failures.isEmpty && !hasImportActivity && inAppNotificationCenter.recentNotifications.isEmpty {
            ContentUnavailableView {
                Label("No Notifications Yet", systemImage: "bell.slash")
            } description: {
                Text("Recent in-app and system notifications will appear here.")
            } actions: {
                Button("Open Notification Settings") {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    #endif
                }
            }
        } else {
            List {
                if !failures.isEmpty {
                    Section {
                        ForEach(failures) { item in
                            Button {
                                dismiss()
                                // These rows are the Issues segment's contents, so
                                // land there rather than on the default segment.
                                downloadsNavigator?.show(.issues)
                                navigateToDownloadsTab()
                            } label: {
                                attentionRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Needs Attention")
                    }
                }

                if hasImportActivity {
                    Section {
                        ForEach(activeJobs) { job in
                            Group {
                                if job.fileNames.count > 1 {
                                    NavigationLink {
                                        ImportJobFilesView(job: job)
                                    } label: {
                                        activeImportJobRow(job)
                                    }
                                } else {
                                    activeImportJobRow(job)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: job.status != .running) {
                                if job.status != .running {
                                    Button(role: .destructive) {
                                        inAppNotificationCenter.removeImportJob(id: job.id)
                                    } label: {
                                        Label("Dismiss", systemImage: "xmark")
                                    }
                                }
                            }
                        }

                        ForEach(displayedImportCommands) { command in
                            queuedImportCommandRow(command)
                        }
                    } header: {
                        HStack {
                            Text("Imports")
                            Spacer(minLength: 8)
                            if activeJobs.contains(where: { $0.status != .running }) {
                                Button("Clear Finished") {
                                    inAppNotificationCenter.clearFinishedImportJobs()
                                }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                            }
                        }
                    }
                }

                if !inAppNotificationCenter.recentNotifications.isEmpty {
                    Section {
                        ForEach(inAppNotificationCenter.recentNotifications) { entry in
                            notificationRow(for: entry)
                        }
                    } header: {
                        Text("Recent")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
        }
    }

    private var sectionSegmentBar: some View {
        TrawlSegmentBar(
            "Notifications",
            selection: Binding(
                get: { selectedSection },
                set: { newSection in withAnimation { selectedSection = newSection } }
            ),
            items: NotificationSheetSection.allCases.map(\.segmentBarItem),
            alignment: .center
        )
    }

    // MARK: - Actions Segment

    /// Global service commands — verbs that need no specific object. Each one fans
    /// out to every configured instance of its backing service instead of asking
    /// the user to pick one, and reports a single summary banner when it lands.
    /// Per-item verbs (retry this grab, blocklist this release) belong on the rows
    /// in Downloads, not here.
    @ViewBuilder
    private var actionsContent: some View {
        let actions = availableActions
        if actions.isEmpty {
            ContentUnavailableView {
                Label("No Quick Actions", systemImage: "bolt.slash")
            } description: {
                Text("Connect Sonarr, Radarr, Prowlarr, Jellyfin, or SABnzbd to run service commands from here.")
            }
            .scrollableUnavailableState()
        } else {
            List {
                ForEach(NotificationQuickActionGroup.allCases) { group in
                    let groupActions = actions.filter { $0.group == group }
                    if !groupActions.isEmpty {
                        Section {
                            ForEach(groupActions) { action in
                                quickActionRow(action)
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
        }
    }

    /// Only actions whose backing service is actually connected are offered —
    /// every integration in Trawl is optional, so an unconfigured service simply
    /// drops its row rather than showing a dead-end button.
    private var availableActions: [NotificationQuickAction] {
        var actions: [NotificationQuickAction] = []

        if !sonarrTargets.isEmpty || !radarrTargets.isEmpty {
            actions.append(contentsOf: [.refreshLibrary, .rssSync, .searchAllMissing])
        }
        if arrServiceManager.prowlarrConnected, arrServiceManager.prowlarrClient != nil {
            actions.append(.syncIndexers)
        }
        if jellyfinServiceManager.isConnected, jellyfinServiceManager.activeClient != nil {
            actions.append(.rescanJellyfinLibraries)
        }
        if sabnzbdServiceManager.isConnected, sabnzbdServiceManager.activeClient != nil {
            actions.append(sabnzbdServiceManager.queue?.paused == true ? .resumeUsenetQueue : .pauseUsenetQueue)
        }

        return actions
    }

    /// Connected Sonarr instances. The label falls back to the plain service name
    /// when there's only one instance so summaries read "Refreshed Sonarr" rather
    /// than echoing a profile name the user never had to choose between.
    private var sonarrTargets: [ArrActionTarget<SonarrAPIClient>] {
        let connected = arrServiceManager.sonarrInstances.filter(\.isConnected)
        return connected.compactMap { entry in
            guard let client = entry.client else { return nil }
            let name = connected.count > 1 ? entry.displayName : ServiceIdentity.sonarr.displayName
            return ArrActionTarget(name: name, client: client)
        }
    }

    private var radarrTargets: [ArrActionTarget<RadarrAPIClient>] {
        let connected = arrServiceManager.radarrInstances.filter(\.isConnected)
        return connected.compactMap { entry in
            guard let client = entry.client else { return nil }
            let name = connected.count > 1 ? entry.displayName : ServiceIdentity.radarr.displayName
            return ArrActionTarget(name: name, client: client)
        }
    }

    @ViewBuilder
    private func quickActionRow(_ action: NotificationQuickAction) -> some View {
        let isRunning = runningActions.contains(action)
        let tint = action.tint

        Button {
            perform(action)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(0.15))
                        .frame(width: 38, height: 38)
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        Image(systemName: action.systemImage)
                            .font(.title3)
                            .foregroundStyle(tint)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(isRunning ? "Running…" : action.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .accessibilityLabel(action.title)
        .accessibilityValue(isRunning ? "Running" : "")
    }

    /// Runs an action once, keeping the row spinning and untappable until every
    /// fanned-out call has come back.
    private func perform(_ action: NotificationQuickAction) {
        guard !runningActions.contains(action) else { return }
        runningActions.insert(action)
        Task {
            let outcome = await runOutcome(for: action)
            runningActions.remove(action)
            report(action, outcome: outcome)
        }
    }

    private func runOutcome(for action: NotificationQuickAction) async -> NotificationQuickActionOutcome {
        var outcome = NotificationQuickActionOutcome()

        switch action {
        case .refreshLibrary:
            for target in sonarrTargets {
                let step = await attempt(target.name) { _ = try await target.client.refreshSeries() }
                outcome.append(step)
            }
            for target in radarrTargets {
                let step = await attempt(target.name) { _ = try await target.client.refreshMovie() }
                outcome.append(step)
            }

        case .rssSync:
            for target in sonarrTargets {
                let step = await attempt(target.name) { _ = try await target.client.rssSync() }
                outcome.append(step)
            }
            for target in radarrTargets {
                let step = await attempt(target.name) { _ = try await target.client.rssSync() }
                outcome.append(step)
            }

        case .searchAllMissing:
            for target in sonarrTargets {
                let step = await attempt(target.name) { _ = try await target.client.searchAllMissing() }
                outcome.append(step)
            }
            for target in radarrTargets {
                let step = await attempt(target.name) { _ = try await target.client.searchAllMissing() }
                outcome.append(step)
            }

        case .syncIndexers:
            if let client = arrServiceManager.prowlarrClient {
                let step = await attempt(ServiceIdentity.prowlarr.displayName) {
                    _ = try await client.syncApplications()
                }
                outcome.append(step)
            }

        case .rescanJellyfinLibraries:
            if let client = jellyfinServiceManager.activeClient {
                let step = await attempt(ServiceIdentity.jellyfin.displayName) {
                    try await client.refreshAllLibraries()
                }
                outcome.append(step)
            }

        case .pauseUsenetQueue:
            let paused = await attempt(ServiceIdentity.sabnzbd.displayName) {
                try await sabnzbdServiceManager.pauseAll()
            }
            outcome.append(paused)

        case .resumeUsenetQueue:
            let resumed = await attempt(ServiceIdentity.sabnzbd.displayName) {
                try await sabnzbdServiceManager.resumeAll()
            }
            outcome.append(resumed)
        }

        return outcome
    }

    /// Runs one fanned-out call and turns the throw into a recorded failure so a
    /// single unreachable instance never aborts the rest of the fan-out.
    private func attempt(_ target: String, _ work: () async throws -> Void) async -> NotificationQuickActionStep {
        do {
            try await work()
            return .succeeded(target)
        } catch {
            return .failed(target: target, message: error.localizedDescription)
        }
    }

    /// One summary banner per action rather than one per service — on a partial
    /// failure the successes and the failure reasons share a single line.
    private func report(_ action: NotificationQuickAction, outcome: NotificationQuickActionOutcome) {
        guard !outcome.isEmpty else {
            inAppNotificationCenter.showError(
                title: action.bannerTitle,
                message: "No connected service handled this command."
            )
            return
        }

        var parts: [String] = []
        if !outcome.succeeded.isEmpty {
            parts.append("\(action.successVerb) \(formattedList(outcome.succeeded))")
        }
        parts.append(contentsOf: outcome.failures.map { "\($0.target) failed: \($0.message)" })
        let message = parts.joined(separator: " · ")

        if outcome.failures.isEmpty {
            inAppNotificationCenter.showSuccess(title: action.bannerTitle, message: "\(message).")
        } else {
            inAppNotificationCenter.showError(title: action.bannerTitle, message: message)
        }
    }

    private func formattedList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
        }
    }

    private func icon(for entry: NotificationLogEntry) -> String {
        let blob = "\(entry.title) \(entry.message)".lowercased()
        let tokens = Set(blob.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })

        if tokens.contains("health") || tokens.contains("warning") || tokens.contains("alert") {
            return "heart.text.square.fill"
        }
        if tokens.contains("issue") {
            return "exclamationmark.bubble.fill"
        }
        if tokens.contains("user") {
            return "person.crop.circle.badge.exclamationmark"
        }
        if tokens.contains("download") || tokens.contains("import") {
            return "arrow.down.circle.fill"
        }

        switch entry.style {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .progress: return "arrow.triangle.2.circlepath"
        }
    }

    private func color(for style: InAppBannerStyle) -> Color {
        switch style {
        case .success: .green
        case .error: .red
        case .progress: .blue
        }
    }

    private func serviceContext(for entry: NotificationLogEntry) -> NotificationServiceContext {
        let blob = "\(entry.title) \(entry.message)".lowercased()
        let tokens = Set(blob.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })

        if tokens.contains("sonarr") { return .sonarr }
        if tokens.contains("radarr") { return .radarr }
        if tokens.contains("prowlarr") { return .prowlarr }
        if tokens.contains("bazarr") { return .bazarr }
        if tokens.contains("seerr") || tokens.contains("overseerr") || tokens.contains("jellyseerr") { return .seerr }
        if tokens.contains("sabnzbd") || tokens.contains("usenet") || tokens.contains("nzb") { return .sabnzbd }
        if tokens.contains("qbittorrent") || tokens.contains("qbit") || tokens.contains("torrent") { return .qbittorrent }
        return .trawl
    }

    private enum NotificationServiceContext {
        case qbittorrent
        case sabnzbd
        case sonarr
        case radarr
        case prowlarr
        case bazarr
        case seerr
        case trawl

        var title: String {
            switch self {
            case .qbittorrent: "qBittorrent"
            case .sabnzbd: "SABnzbd"
            case .sonarr: "Sonarr"
            case .radarr: "Radarr"
            case .prowlarr: "Prowlarr"
            case .bazarr: "Bazarr"
            case .seerr: "Seerr"
            case .trawl: "Trawl"
            }
        }

        var systemImage: String {
            switch self {
            case .qbittorrent: ServiceIdentity.qbittorrent.systemImage
            case .sabnzbd: ServiceIdentity.sabnzbd.systemImage
            case .sonarr: ServiceIdentity.sonarr.systemImage
            case .radarr: ServiceIdentity.radarr.systemImage
            case .prowlarr: ServiceIdentity.prowlarr.systemImage
            case .bazarr: ServiceIdentity.bazarr.systemImage
            case .seerr: ServiceIdentity.seerr.systemImage
            case .trawl: "app.badge"
            }
        }
    }

    private static let longMessageThreshold = 140

    private func isLongMessage(_ message: String) -> Bool {
        message.count > Self.longMessageThreshold || message.contains("\n")
    }

    private func tintColor(for tint: ImportJobTint) -> Color {
        switch tint {
        case .sonarr: return ServiceIdentity.sonarr.brandColor
        case .radarr: return ServiceIdentity.radarr.brandColor
        case .generic: return .accentColor
        }
    }

    private func tintColor(for service: QueuedImportCommand.Service) -> Color {
        switch service {
        case .sonarr: return ServiceIdentity.sonarr.brandColor
        case .radarr: return ServiceIdentity.radarr.brandColor
        }
    }

    private func refreshQueuedImportCommands() async {
        var commands: [QueuedImportCommand] = []

        if let client = arrServiceManager.sonarrClient {
            commands.append(contentsOf: await loadQueuedImportCommands(client: client, service: .sonarr))
        }
        if let client = arrServiceManager.radarrClient {
            commands.append(contentsOf: await loadQueuedImportCommands(client: client, service: .radarr))
        }

        queuedImportCommands = commands.sorted {
            ($0.queued ?? "") > ($1.queued ?? "")
        }
    }

    private func loadQueuedImportCommands<Client: SharedArrClient>(
        client: Client,
        service: QueuedImportCommand.Service
    ) async -> [QueuedImportCommand] {
        do {
            return try await client.getCommandQueue()
                .filter { $0.isActiveManualImport }
                .map { QueuedImportCommand(command: $0, service: service) }
        } catch {
            return []
        }
    }

    /// A failing download. Tapping takes the user to Downloads, where the Issues
    /// segment carries the retry/blocklist verbs this sheet deliberately doesn't.
    @ViewBuilder
    private func attentionRow(_ item: DownloadListItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: item.attentionSystemImage)
                    .font(.title3)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.attentionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(item.attentionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func activeImportJobRow(_ job: ActiveImportJob) -> some View {
        let tint = tintColor(for: job.serviceTint)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 38, height: 38)
                switch job.status {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: job.serviceSystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(job.serviceTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(activeImportJobStatusText(job))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(activeImportJobStatusColor(job))
                    Spacer(minLength: 0)
                }

                Text(activeImportJobTitle(job))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(activeImportJobSubtitle(job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let error = job.errorMessage, job.status == .failed {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func activeImportJobStatusText(_ job: ActiveImportJob) -> String {
        switch job.status {
        case .running:
            if let current = job.currentIndex, let total = job.progressTotal {
                return "Importing \(current) of \(total)"
            }
            return "Importing"
        case .succeeded: return "Imported"
        case .failed: return "Failed"
        }
    }

    /// The leading title for the job row. While running with known per-file
    /// progress, this is the file currently being processed by the server;
    /// otherwise it falls back to the batch's representative title.
    private func activeImportJobTitle(_ job: ActiveImportJob) -> String {
        if job.status == .running, let current = job.currentName {
            return current
        }
        return job.primaryName
    }

    private func activeImportJobStatusColor(_ job: ActiveImportJob) -> Color {
        switch job.status {
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private func activeImportJobSubtitle(_ job: ActiveImportJob) -> String {
        let fileWord = job.fileCount == 1 ? "file" : "files"
        let countText = "\(job.fileCount) \(fileWord)"
        let timeText: String
        if let completedAt = job.completedAt {
            timeText = completedAt.formatted(date: .omitted, time: .shortened)
        } else {
            timeText = job.startedAt.formatted(date: .omitted, time: .shortened)
        }
        return "\(countText) · \(job.folderName) · \(timeText)"
    }

    @ViewBuilder
    private func queuedImportCommandRow(_ command: QueuedImportCommand) -> some View {
        let tint = tintColor(for: command.service)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: command.service.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(command.service.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(command.statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                Text(command.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(command.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func notificationRow(for entry: NotificationLogEntry) -> some View {
        let long = isLongMessage(entry.message)
        Group {
            if long {
                NavigationLink {
                    NotificationDetailView(
                        entry: entry,
                        icon: icon(for: entry),
                        tint: color(for: entry.style)
                    )
                } label: {
                    notificationRowBody(entry: entry, truncate: true)
                }
            } else {
                notificationRowBody(entry: entry, truncate: false)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                inAppNotificationCenter.removeNotification(id: entry.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func notificationRowBody(entry: NotificationLogEntry, truncate: Bool) -> some View {
        let service = serviceContext(for: entry)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.timestamp > unreadSinceDate ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                HStack(spacing: 4) {
                    Image(systemName: icon(for: entry))
                        .foregroundStyle(color(for: entry.style))
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Text(service.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !entry.message.isEmpty {
                Text(entry.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
                    .lineLimit(truncate ? 2 : nil)
            }
            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 15)
        }
        .padding(.vertical, 2)
    }
}

private struct QueuedImportCommand: Identifiable, Sendable {
    enum Service: Sendable {
        case sonarr
        case radarr

        var title: String {
            switch self {
            case .sonarr: "Sonarr"
            case .radarr: "Radarr"
            }
        }

        var systemImage: String {
            switch self {
            case .sonarr: ServiceIdentity.sonarr.systemImage
            case .radarr: ServiceIdentity.radarr.systemImage
            }
        }

        var idPrefix: String {
            switch self {
            case .sonarr: "sonarr"
            case .radarr: "radarr"
            }
        }
    }

    let id: String
    let service: Service
    let commandID: Int?
    let queued: String?
    let status: String?

    init(command: ArrCommand, service: Service) {
        self.service = service
        self.commandID = command.id
        self.queued = command.queued
        self.status = command.status
        self.id = "\(service.idPrefix)-\(command.id?.description ?? command.queued ?? UUID().uuidString)"
    }

    var title: String {
        if let commandID {
            return "Manual Import #\(commandID)"
        }
        return "Manual Import"
    }

    var subtitle: String {
        let prefix = isQueued ? "Waiting in command queue" : "Running in \(service.title)"
        guard let queued, !queued.isEmpty else { return prefix }
        return "\(prefix) · \(queued)"
    }

    var isQueued: Bool {
        normalizedStatus == "queued"
    }

    var statusText: String {
        switch normalizedStatus {
        case "queued": return "Queued"
        case "started": return "Importing"
        default: return status?.capitalized ?? "Active"
        }
    }

    private var normalizedStatus: String {
        (status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private extension ArrCommand {
    var isActiveManualImport: Bool {
        let command = (commandName ?? name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedStatus = (status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return command == "manualimport" && !isTerminal && normalizedStatus != "completed"
    }
}

private struct NotificationDetailView: View {
    let entry: NotificationLogEntry
    let icon: String
    let tint: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Label(entry.source.rawValue, systemImage: "tray.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                if entry.message.isEmpty {
                    Text("No additional details.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.message)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle("Notification")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Quick Action Model

/// Section headers for the Actions segment, ordered the way they render.
private enum NotificationQuickActionGroup: String, CaseIterable, Identifiable {
    case library
    case indexers
    case mediaServer
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .indexers: "Indexers"
        case .mediaServer: "Media Server"
        case .downloads: "Downloads"
        }
    }
}

/// A global service verb. Everything here is object-free — it acts on whole
/// services, never on a single queue item, grab, or release.
private enum NotificationQuickAction: String, CaseIterable, Identifiable {
    case refreshLibrary
    case rssSync
    case searchAllMissing
    case syncIndexers
    case rescanJellyfinLibraries
    case pauseUsenetQueue
    case resumeUsenetQueue

    var id: String { rawValue }

    var group: NotificationQuickActionGroup {
        switch self {
        case .refreshLibrary, .rssSync, .searchAllMissing: .library
        case .syncIndexers: .indexers
        case .rescanJellyfinLibraries: .mediaServer
        case .pauseUsenetQueue, .resumeUsenetQueue: .downloads
        }
    }

    var title: String {
        switch self {
        case .refreshLibrary: "Refresh Library"
        case .rssSync: "Check for New Releases"
        case .searchAllMissing: "Search All Missing"
        case .syncIndexers: "Sync Indexers to Apps"
        case .rescanJellyfinLibraries: "Rescan Libraries"
        case .pauseUsenetQueue: "Pause Usenet Queue"
        case .resumeUsenetQueue: "Resume Usenet Queue"
        }
    }

    var subtitle: String {
        switch self {
        case .refreshLibrary: "Rescan every series and movie on disk across Sonarr and Radarr."
        case .rssSync: "Run an RSS sync so monitored items pick up fresh releases."
        case .searchAllMissing: "Start an indexer search for everything still missing."
        case .syncIndexers: "Push Prowlarr's indexers out to its linked applications."
        case .rescanJellyfinLibraries: "Scan every Jellyfin library for new and changed media."
        case .pauseUsenetQueue: "Hold every SABnzbd download until you resume."
        case .resumeUsenetQueue: "Restart the paused SABnzbd queue."
        }
    }

    var systemImage: String {
        switch self {
        case .refreshLibrary: "arrow.clockwise"
        case .rssSync: "dot.radiowaves.up.forward"
        case .searchAllMissing: "magnifyingglass"
        case .syncIndexers: "arrow.triangle.2.circlepath"
        case .rescanJellyfinLibraries: "rectangle.stack.badge.play"
        case .pauseUsenetQueue: "pause.circle"
        case .resumeUsenetQueue: "play.circle"
        }
    }

    var tint: Color {
        switch self {
        case .refreshLibrary, .rssSync, .searchAllMissing: .accentColor
        case .syncIndexers: ServiceIdentity.prowlarr.brandColor
        case .rescanJellyfinLibraries: ServiceIdentity.jellyfin.brandColor
        case .pauseUsenetQueue, .resumeUsenetQueue: ServiceIdentity.sabnzbd.brandColor
        }
    }

    /// Title of the single summary banner posted when the fan-out finishes.
    var bannerTitle: String {
        switch self {
        case .refreshLibrary: "Refresh Library"
        case .rssSync: "RSS Sync"
        case .searchAllMissing: "Search All Missing"
        case .syncIndexers: "Sync Indexers"
        case .rescanJellyfinLibraries: "Rescan Libraries"
        case .pauseUsenetQueue: "Pause Queue"
        case .resumeUsenetQueue: "Resume Queue"
        }
    }

    /// Leads the summary line: "<verb> Sonarr and Radarr".
    var successVerb: String {
        switch self {
        case .refreshLibrary: "Refreshed"
        case .rssSync: "Synced"
        case .searchAllMissing: "Started search on"
        case .syncIndexers: "Synced"
        case .rescanJellyfinLibraries: "Rescanned"
        case .pauseUsenetQueue: "Paused"
        case .resumeUsenetQueue: "Resumed"
        }
    }
}

/// One connected instance an action fans out to, paired with the label used for
/// it in the summary banner.
private struct ArrActionTarget<Client: SharedArrClient> {
    let name: String
    let client: Client
}

private enum NotificationQuickActionStep {
    case succeeded(String)
    case failed(target: String, message: String)
}

/// Collected results of a fan-out, so a partial failure can be reported as one
/// line instead of a stack of per-service banners.
private struct NotificationQuickActionOutcome {
    private(set) var succeeded: [String] = []
    private(set) var failures: [(target: String, message: String)] = []

    var isEmpty: Bool { succeeded.isEmpty && failures.isEmpty }

    mutating func append(_ step: NotificationQuickActionStep) {
        switch step {
        case .succeeded(let name):
            succeeded.append(name)
        case .failed(let target, let message):
            failures.append((target: target, message: message))
        }
    }
}

// MARK: - Failing Download Presentation

/// How a failing download reads in the tab-bar accessory's summary line and in the
/// sheet's Needs Attention rows. Kept here rather than on `DownloadListItem` because
/// it is presentation for this surface only.
private extension DownloadListItem {
    var attentionTitle: String {
        switch self {
        case .torrent(let torrent): torrent.name
        case .arrQueue(let item, _, _, _): item.title ?? "Untitled release"
        case .arrHistory(let item): item.record.sourceTitle ?? "Untitled release"
        case .sab(let job): job.name
        }
    }

    var attentionDetail: String {
        let parts: [String?]
        switch self {
        case .torrent(let torrent):
            parts = [ServiceIdentity.qbittorrent.displayName, torrent.state.displayName]
        case .arrQueue(let item, let source, _, let linkedSABJob):
            parts = [
                source.displayName,
                item.primaryStatusMessage ?? linkedSABJob?.failureMessage ?? item.status
            ]
        case .arrHistory(let item):
            parts = [item.source.displayName, item.record.eventDisplayName]
        case .sab(let job):
            parts = [ServiceIdentity.sabnzbd.displayName, job.failureMessage ?? job.status]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var attentionSystemImage: String {
        switch self {
        case .torrent: ServiceIdentity.qbittorrent.systemImage
        case .arrQueue(_, let source, _, _): source == .radarr
            ? ServiceIdentity.radarr.systemImage
            : ServiceIdentity.sonarr.systemImage
        case .arrHistory(let item): item.source == .radarr
            ? ServiceIdentity.radarr.systemImage
            : ServiceIdentity.sonarr.systemImage
        case .sab: ServiceIdentity.sabnzbd.systemImage
        }
    }
}

#if DEBUG
/// Previews live next to the sheet rather than in `MoreView`, where they used to
/// sit alongside `MorePreviewFixtures`. The sheet reads five service
/// environments, and only `PreviewHost` supplies all of them — so the fixtures
/// are inlined here instead of reaching back into another file's private enum.
private enum NotificationSheetPreviewFixtures {
    static func notificationCenter() -> InAppNotificationCenter {
        InAppNotificationCenter(
            previewNotifications: entries,
            lastReadDate: Date().addingTimeInterval(-3_600)
        )
    }

    static var entries: [NotificationLogEntry] {
        [
            NotificationLogEntry(
                title: "Sonarr Health Warning",
                message: "Indexer sync completed, but one indexer reported a stale certificate.",
                style: .error,
                source: .system,
                timestamp: Date().addingTimeInterval(-240)
            ),
            NotificationLogEntry(
                title: "Download Complete",
                message: "Dune Part Two imported successfully.",
                style: .success,
                source: .inApp,
                timestamp: Date().addingTimeInterval(-1_800)
            ),
            NotificationLogEntry(
                title: "Jellyfin User Import",
                message: "Three Jellyfin users are ready to import into Seerr.",
                style: .progress,
                source: .inApp,
                timestamp: Date().addingTimeInterval(-7_200)
            ),
        ]
    }
}

#Preview("Recent Notifications - Loaded") {
    PreviewHost(notificationCenter: NotificationSheetPreviewFixtures.notificationCenter()) {
        NavigationStack {
            RecentNotificationsSheet()
        }
    }
}

#Preview("Recent Notifications - Empty") {
    PreviewHost(notificationCenter: InAppNotificationCenter(previewNotifications: [])) {
        NavigationStack {
            RecentNotificationsSheet()
        }
    }
}
#endif
