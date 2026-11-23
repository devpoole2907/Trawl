import SwiftUI
import SwiftData

/// Defined on both platforms even though the accessory below is iOS-only.
///
/// `DownloadsView`, `ArrMediaListView` and `ArrCalendarView` all read this
/// unconditionally, so guarding the key itself is what stopped those shared views
/// compiling for macOS. The default is a no-op, which is the correct macOS behaviour
/// rather than a stub: there is no tab chrome there to hide.
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
    var prefersCompactLayout = false
    /// The iPhone bar, which is also Downloads' home there: while anything is
    /// downloading it leads with that, and a tap opens the sheet on Downloads.
    /// Off in the sidebar footer, where Downloads is a row of its own.
    var showsDownloads = false
    @Environment(SyncService.self) private var syncService: SyncService?
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?

    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(ArrServiceManager.self) private var arrServiceManager: ArrServiceManager?
    @Environment(DownloadsNavigator.self) private var downloadsNavigator: DownloadsNavigator?

    /// What the bar leads with. The most urgent thing in the sheet comes first, and
    /// a tap opens the tab that holds it - see `NotificationBarLead`.
    private var lead: NotificationBarLead {
        NotificationBarLead.resolve(
            pendingRequests: pendingApprovalCount,
            failingDownloads: failingDownloads.count,
            isDownloading: downloads != nil,
            hasUnreadEvent: latestNotification != nil,
            isImporting: !runningImportJobs.isEmpty
        )
    }

    /// Failing downloads, on the phone only: there the sheet's Downloads tab is
    /// their home. In the sidebar footer Downloads is a row of its own with its own
    /// count, and the bar stays about notifications.
    private var failingDownloads: [DownloadListItem] {
        guard showsDownloads, let arrServiceManager, let syncService, let sabnzbdServiceManager else { return [] }
        return DownloadsViewModel.attentionItems(
            serviceManager: arrServiceManager,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs
        )
    }

    private var pendingRequestHeadline: String {
        pendingApprovalCount == 1
            ? "1 request awaiting approval"
            : "\(pendingApprovalCount) requests awaiting approval"
    }

    private var failingHeadline: String {
        let count = failingDownloads.count
        return count == 1 ? "1 download needs attention" : "\(count) downloads need attention"
    }

    /// Requests waiting on a decision. Deliberately kept apart from `unreadCount`:
    /// this is standing state, not an event. Folding it into "unread" would leave a
    /// badge that never clears while a request sits there, which reads as broken.
    private var pendingApprovalCount: Int { seerrServiceManager.pendingRequests.count }

    private var latestNotification: NotificationLogEntry? {
        inAppNotificationCenter.recentNotifications.first {
            $0.timestamp > inAppNotificationCenter.lastReadDate
        }
    }

    private var unreadCount: Int {
        inAppNotificationCenter.unreadCount
    }

    private var isInline: Bool {
        if prefersCompactLayout { return true }
        #if os(iOS)
        return placement == .inline
        #else
        return false
        #endif
    }

    private var runningImportJobs: [ActiveImportJob] {
        inAppNotificationCenter.activeImportJobs.filter { $0.status == .running }
    }

    private var primaryRunningJob: ActiveImportJob? {
        runningImportJobs.first
    }

    /// What is downloading, when this bar is showing downloads at all.
    private var downloads: ActiveDownloadsSummary? {
        guard showsDownloads else { return nil }
        return ActiveDownloadsSummary.make(
            torrents: syncService.map { Array($0.torrents.values) } ?? [],
            sabJobs: sabnzbdServiceManager?.unpausedJobs ?? []
        )
    }

    private var headline: String {
        switch lead {
        case .requestsWaiting:
            return pendingRequestHeadline
        case .downloadsFailing:
            return failingHeadline
        case .downloading:
            return downloads?.leadName ?? "Downloads"
        case .latestEvent:
            return latestNotification?.title ?? "Notifications"
        case .importing:
            if runningImportJobs.count > 1 {
                return "Importing \(runningImportJobs.count) jobs"
            }
            let fileCount = primaryRunningJob?.fileCount ?? 0
            return "Importing \(fileCount) \(fileCount == 1 ? "file" : "files")"
        case .idle:
            return "Notifications"
        }
    }

    private var subtitle: String {
        switch lead {
        case .requestsWaiting:
            guard let first = seerrServiceManager.pendingRequests.first else { return "Tap to approve or decline" }
            let title = seerrServiceManager.displayTitle(for: first)
            if let requester = first.requestedBy?.displayName, !requester.isEmpty {
                return "\(title) · \(requester)"
            }
            return title
        case .downloadsFailing:
            return failingDownloads.first?.attentionDetail ?? "Tap to see what failed"
        case .downloading:
            guard let downloads else { return "" }
            let speed = downloads.bytesPerSecond > 0
                ? " · " + ByteCountFormatter.string(fromByteCount: downloads.bytesPerSecond, countStyle: .file) + "/s"
                : ""
            return downloads.detail + speed
        case .latestEvent:
            guard let latestNotification else { return "" }
            return "\(latestNotification.associatedServiceTitle) · \(latestNotification.timestamp.formatted(date: .abbreviated, time: .shortened))"
        case .importing:
            if runningImportJobs.count > 1 {
                let services = Set(runningImportJobs.map(\.serviceTitle)).sorted().joined(separator: " · ")
                return services.isEmpty ? "Imports in progress" : services
            }
            guard let job = primaryRunningJob else { return "Imports in progress" }
            return "\(job.serviceTitle) · \(job.primaryName)"
        case .idle:
            return "No recent notifications"
        }
    }

    private var notificationAccessibilityValue: String {
        switch lead {
        case .requestsWaiting:
            let word = pendingApprovalCount == 1 ? "request is" : "requests are"
            return "\(pendingApprovalCount) \(word) awaiting approval"
        case .downloadsFailing:
            return failingHeadline
        default:
            break
        }
        if let latestNotification {
            if unreadCount == 1 {
                return "\(latestNotification.title), 1 unread notification"
            } else if unreadCount > 1 {
                return "\(latestNotification.title), \(unreadCount) unread notifications"
            }
            return "\(latestNotification.title), no unread notifications"
        }
        if pendingApprovalCount > 0 {
            let word = pendingApprovalCount == 1 ? "request is" : "requests are"
            return "\(pendingApprovalCount) \(word) awaiting approval"
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
        if case .downloadsFailing = lead {
            downloadsNavigator?.show(.issues)
        }
        inAppNotificationCenter.showRecentNotifications(on: lead.tab)
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
        #if os(iOS)
        .simultaneousGesture(swipeUpGesture)
        #endif
        .accessibilityLabel(lead == .downloading ? "Downloads" : "Notifications")
        .accessibilityValue(lead == .downloading ? downloads.map { "\($0.leadName), \($0.detail)" } ?? "" : notificationAccessibilityValue)
        .accessibilityIdentifier("notification-accessory")
        // Restarted when Seerr connects, for the same reason as the bell's loop.
        .task(id: seerrServiceManager.isConnected) {
            // Slow cadence on purpose. Approvals arrive by push, and this is only
            // here so the count is right when the app has been sitting open.
            guard seerrServiceManager.isConnected else { return }
            while !Task.isCancelled {
                await seerrServiceManager.refreshRequestQueue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    #if os(iOS)
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
    #endif

    private var inlineSummary: String {
        switch lead {
        case .downloading:
            guard let downloads else { return headline }
            return "\(downloads.leadName) · \(downloads.detail)"
        case .importing:
            if let job = primaryRunningJob, runningImportJobs.count == 1 {
                return "\(headline) · \(job.serviceTitle)"
            }
            return headline
        case .idle:
            if unreadCount >= 1 {
                return unreadCount == 1 ? "1 unread" : "\(unreadCount) unread"
            }
            return "Notifications"
        default:
            return headline
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
        // Keep an intrinsic height when this compact form is used as a sidebar
        // safe-area inset. `maxHeight: .infinity` is appropriate only when the
        // system tab accessory supplies a finite slot; in a split-view footer it
        // consumes the entire sidebar and leaves the navigation rows off-screen.
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
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
        #if os(macOS)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        #else
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        #endif
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var iconTint: AnyShapeStyle {
        switch lead {
        case .requestsWaiting: AnyShapeStyle(ServiceIdentity.seerr.brandColor)
        case .downloadsFailing: AnyShapeStyle(.orange)
        default: AnyShapeStyle(.tint)
        }
    }

    private var notificationIcon: some View {
        Group {
            switch lead {
            case .requestsWaiting:
                Image(systemName: "checkmark.circle.badge.questionmark.fill")
                    .symbolRenderingMode(.hierarchical)
            case .downloadsFailing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
            case .downloading:
                if let downloads {
                    Gauge(value: downloads.leadProgress) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.5)
                    .frame(width: 24, height: 24)
                    .tint(.blue)
                    .overlay {
                        Image(systemName: "arrow.down")
                            .font(.caption2.weight(.bold))
                    }
                }
            case .importing:
                Image(systemName: "tray.and.arrow.down.fill")
                    .symbolRenderingMode(.hierarchical)
            case .latestEvent, .idle:
                Image(systemName: "bell.fill")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .overlay(alignment: .topTrailing) {
            switch lead {
            case .requestsWaiting(let count):
                countBadge(count, color: ServiceIdentity.seerr.brandColor)
            case .downloadsFailing(let count):
                countBadge(count, color: .orange)
            case .downloading:
                if let downloads, downloads.othersCount > 0 {
                    countBadge(downloads.count, color: .blue)
                }
            case .latestEvent:
                if unreadCount > 0 {
                    countBadge(unreadCount, color: .red)
                }
            case .importing:
                let count = inAppNotificationCenter.runningImportJobsCount
                Group {
                    if count > 1 {
                        countBadge(count, color: .blue, offset: false)
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
            case .idle:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func countBadge(_ count: Int, color: Color, offset: Bool = true) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(color, in: Capsule())
            .offset(x: offset ? 10 : 0, y: offset ? -10 : 0)
            .accessibilityHidden(true)
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

// MARK: - Recent Notifications Sheet

/// The sidebar chrome's way into notifications: a bell in the sidebar's toolbar
/// that opens Alerts and Actions in a popover.
///
/// On the tab chrome the notification bar leads with whatever needs you. Here the
/// rows do that - Requests and Downloads carry their own badges - so the bell only
/// counts what has no row: news since the last look, and setup problems.
struct NotificationBellButton<Panel: View>: View {
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(ConfigurationAuditStore.self) private var configurationAuditStore: ConfigurationAuditStore?

    @ViewBuilder let panel: () -> Panel

    private var unreadCount: Int {
        inAppNotificationCenter.recentNotifications.filter {
            $0.timestamp > inAppNotificationCenter.lastReadDate
        }.count
    }

    private var setupProblemCount: Int {
        configurationAuditStore?.problems.count ?? 0
    }

    private var badgeCount: Int { unreadCount + setupProblemCount }

    var body: some View {
        @Bindable var center = inAppNotificationCenter
        Button {
            inAppNotificationCenter.showRecentNotifications(on: nil)
        } label: {
            Label("Notifications", systemImage: badgeCount > 0 ? "bell.badge" : "bell")
        }
        .badge(badgeCount)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("notification-bell")
        .popover(isPresented: $center.isPresentingRecentNotifications, arrowEdge: .bottom) {
            panel()
                .frame(idealWidth: 420, idealHeight: 620)
                .presentationSizing(.fitted)
        }
        // Restarted when Seerr connects: a pass before the connection exists reads
        // nothing, and the next one would be a minute away.
        .task(id: seerrServiceManager.isConnected) {
            // The sidebar's Requests badge reads this queue, and nothing else in this
            // chrome refreshes it. Slow on purpose: approvals arrive by push.
            guard seerrServiceManager.isConnected else { return }
            while !Task.isCancelled {
                await seerrServiceManager.refreshRequestQueue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if unreadCount > 0 { parts.append("\(unreadCount) new") }
        if setupProblemCount > 0 {
            parts.append(setupProblemCount == 1 ? "1 setup problem" : "\(setupProblemCount) setup problems")
        }
        return parts.joined(separator: ", ")
    }
}

/// The notification sheet: the stack's work in progress.
///
/// Anything moving between "I want this" and "it's in my library" belongs here, in
/// pipeline order - Requests (asked for), Downloads (on the way), Alerts (what
/// happened, and what's broken) - plus Actions, the controls that push the pipeline
/// along. The root tabs hold the two ends: what you might want and what you have.
/// Badges count only what is waiting on the user, so they clear when the thing is
/// dealt with rather than when the sheet is opened.
struct RecentNotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(ConfigurationAuditStore.self) private var configurationAuditStore: ConfigurationAuditStore?
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager: CleanuparrServiceManager?
    @Environment(\.navigateToSeriesTab) private var navigateToSeriesTab
    @Environment(\.navigateToMoviesTab) private var navigateToMoviesTab
    @Environment(\.navigateToDownloadsTab) private var navigateToDownloadsTab
    @Environment(\.navigateToSetupCheck) private var navigateToSetupCheck
    /// Optional so the sheet still works anywhere a navigator isn't injected.
    @Environment(DownloadsNavigator.self) private var downloadsNavigator: DownloadsNavigator?
    @State private var selectedTab: NotificationSheetTab = .alerts
    /// The Downloads screen, built by the root so it carries the same session and
    /// services the tab did. `nil` where Downloads has a home of its own - the
    /// sidebar - and the tab is not offered.
    var downloadsContent: AnyView? = nil

    init(downloadsContent: AnyView? = nil) {
        self.downloadsContent = downloadsContent
    }
    @State private var showClearConfirmation = false
    @State private var unreadSinceDate: Date = .distantPast
    @State private var queuedImportCommands: [QueuedImportCommand] = []
    @State private var showSetupCheck = false
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    private var notificationCount: Int { inAppNotificationCenter.recentNotifications.count }
    private var unreadNotificationCount: Int {
        inAppNotificationCenter.recentNotifications.filter { $0.timestamp > effectiveUnreadSinceDate }.count
    }
    private var effectiveUnreadSinceDate: Date {
        unreadSinceDate == .distantPast ? inAppNotificationCenter.lastReadDate : unreadSinceDate
    }

    /// Requests are offered wherever Seerr is set up - reachable or not, so a server
    /// that is down still has somewhere to say so.
    private var hasSeerr: Bool {
        seerrServiceManager.hasConfiguredProfile || seerrServiceManager.isConnected
    }

    /// Whether this is the tab chrome's sheet. There, Requests and Downloads have no
    /// row of their own to carry a badge, so they live here. In the sidebar chrome
    /// they are sidebar rows, badged there, and the sheet holds only what has no
    /// place: Alerts and Actions. The root hands Downloads in only on the tab chrome,
    /// so its presence is the signal.
    private var placesLiveInSheet: Bool { downloadsContent != nil }

    private var availableTabs: [NotificationSheetTab] {
        NotificationSheetTabs.available(hasSeerr: hasSeerr && placesLiveInSheet, hasDownloads: placesLiveInSheet)
    }

    /// Running imports only. A finished one has already become a log entry - its
    /// "Import Complete" or "Import Failed" - so keeping it here as well said the
    /// same thing twice.
    private var runningJobs: [ActiveImportJob] {
        inAppNotificationCenter.activeImportJobs.filter { $0.status == .running }
    }

    /// Standing download issues. On the phone these are the Downloads tab's badge;
    /// where Downloads isn't in the sheet, Alerts carries one summary row for them.
    private var attentionItems: [DownloadListItem] {
        DownloadsViewModel.attentionItems(
            serviceManager: arrServiceManager,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs
        )
    }

    private var hasImportActivity: Bool {
        !runningJobs.isEmpty || !displayedImportCommands.isEmpty
    }

    private var trawlClientHosts: [DownloadClientLinkKind: [String]] {
        ConfigurationAuditInput.trawlClientHosts(
            qbittorrentServers: qbittorrentServers,
            sabnzbdProfiles: sabnzbdProfiles
        )
    }

    private var auditInputRevision: String {
        ConfigurationAuditInput.revision(
            arrServiceManager: arrServiceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager
        )
    }

    private var hasConfigurationAttention: Bool {
        guard let configurationAuditStore else { return false }
        return (configurationAuditStore.isAuditing && !configurationAuditStore.hasCompletedAnAudit)
            || !configurationAuditStore.problems.isEmpty
            || !configurationAuditStore.unknowns.isEmpty
    }

    private var setupProblemCount: Int {
        configurationAuditStore?.problems.count ?? 0
    }

    private var displayedImportCommands: [QueuedImportCommand] {
        guard !runningJobs.isEmpty else { return queuedImportCommands }
        return queuedImportCommands.filter(\.isQueued)
    }

    private func subtitle(for tab: NotificationSheetTab) -> String {
        switch tab {
        case .requests:
            let waiting = seerrServiceManager.pendingRequests.count
            let onTheWay = seerrServiceManager.inFlightRequests.count
            var parts: [String] = []
            if waiting > 0 { parts.append("\(waiting) waiting") }
            if onTheWay > 0 { parts.append("\(onTheWay) on the way") }
            return parts.isEmpty ? "Nothing in flight" : parts.joined(separator: " · ")
        case .actions:
            let count = availableActions.count
            return count == 1 ? "1 action available" : "\(count) actions available"
        case .alerts, .downloads:
            var parts: [String] = []
            if setupProblemCount > 0 {
                parts.append(setupProblemCount == 1 ? "1 setup problem" : "\(setupProblemCount) setup problems")
            }
            let importing = runningJobs.count + displayedImportCommands.count
            if importing > 0 {
                parts.append(importing == 1 ? "1 import running" : "\(importing) imports running")
            }
            if unreadNotificationCount > 0 { parts.append("\(unreadNotificationCount) new") }
            return parts.isEmpty ? "Nothing new" : parts.joined(separator: " · ")
        }
    }

    var body: some View {
        sectionTabs
        .onAppear {
            selectedTab = NotificationSheetTabs.opening(
                requested: inAppNotificationCenter.requestedSheetTab,
                lastUsed: inAppNotificationCenter.lastSheetTab,
                available: availableTabs
            )
            inAppNotificationCenter.requestedSheetTab = nil
            unreadSinceDate = inAppNotificationCenter.lastReadDate
            inAppNotificationCenter.markAllRead()
        }
        // Anything that arrived while the sheet was open was seen, so it isn't new
        // next time - nor something for the bar to keep advertising.
        .onDisappear {
            inAppNotificationCenter.markAllRead()
        }
        // Asked for while already open - a deep link, or a row that hands over to
        // another tab - switches tab rather than stacking anything.
        .onChange(of: inAppNotificationCenter.requestedSheetTab) { _, requested in
            guard let requested else { return }
            withAnimation {
                selectedTab = NotificationSheetTabs.opening(
                    requested: requested,
                    lastUsed: nil,
                    available: availableTabs
                )
            }
            inAppNotificationCenter.requestedSheetTab = nil
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            inAppNotificationCenter.lastSheetTab = tab
        }
        .task(id: hasSeerr) {
            guard hasSeerr else { return }
            await seerrServiceManager.refreshRequestQueue()
        }
        .task(id: auditInputRevision) {
            await refreshConfigurationAuditIfNeeded()
        }
        .task {
            await refreshQueuedImportCommands()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refreshQueuedImportCommands()
            }
        }
        .sheet(isPresented: $showSetupCheck) {
            SetupCheckSheet()
        }
    }

    /// Alerts: what is broken, what is running, then what happened.
    ///
    /// Setup problems lead because they are standing state - they stay until fixed -
    /// and "All clear" takes their place when there are none, which still answers "is
    /// anything wrong?". Running imports come next. Then the log, from where the user
    /// left off, grouped by day.
    @ViewBuilder
    private var alertsContent: some View {
        let failures = downloadsContent == nil ? attentionItems : []
        let sections = NotificationTimeline.sections(
            inAppNotificationCenter.recentNotifications,
            lastRead: effectiveUnreadSinceDate
        )
        if !hasConfigurationAttention && failures.isEmpty && !hasImportActivity && sections.isEmpty {
            ContentUnavailableView {
                Label("No Notifications Yet", systemImage: "bell.slash")
            } description: {
                Text("Grabs, imports, failed downloads and requests will show up here.")
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
                setupSection(failures: failures)

                if hasImportActivity {
                    Section("Happening Now") {
                        ForEach(runningJobs) { job in
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
                        ForEach(displayedImportCommands) { command in
                            queuedImportCommandRow(command)
                        }
                    }
                }

                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            notificationRow(for: entry)
                        }
                    } header: {
                        timelineHeader(section.kind)
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

    @ViewBuilder
    private func timelineHeader(_ kind: NotificationTimeline.SectionKind) -> some View {
        let title = NotificationTimeline.title(for: kind, now: .now)
        if case .new = kind {
            Text(title)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("notifications-new-since")
        } else {
            Text(title)
        }
    }

    /// The top of Alerts: setup problems, failing downloads where Downloads isn't a
    /// tab of its own, or one "All clear" line when neither has anything to say.
    @ViewBuilder
    private func setupSection(failures: [DownloadListItem]) -> some View {
        if let configurationAuditStore, hasConfigurationAttention || !failures.isEmpty {
            Section {
                if hasConfigurationAttention {
                    Button {
                        // Where the chrome has Setup Check as a destination, go there:
                        // stacking the wizard's sheet on top of this one buries the
                        // screen the user is already looking at. The compact chrome has
                        // nowhere to send them, so it still presents the sheet.
                        if let navigateToSetupCheck {
                            dismiss()
                            navigateToSetupCheck()
                        } else {
                            showSetupCheck = true
                        }
                    } label: {
                        attentionLabel(
                            systemImage: configurationAuditStore.isAuditing ? "checklist" : "exclamationmark.triangle.fill",
                            tint: configurationAuditStore.isAuditing ? .secondary : .orange,
                            title: configurationAttentionTitle(configurationAuditStore),
                            detail: configurationAttentionDetail(configurationAuditStore)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(configurationAuditStore.isAuditing && !configurationAuditStore.hasCompletedAnAudit)
                    .accessibilityIdentifier("notifications-setup-attention")
                    .swipeActions(edge: .trailing) {
                        Button("Check Again", systemImage: "arrow.clockwise") {
                            checkSetupAgain(configurationAuditStore)
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button("Check Again", systemImage: "arrow.clockwise") {
                            checkSetupAgain(configurationAuditStore)
                        }
                    }
                }

                if !failures.isEmpty {
                    Button {
                        dismiss()
                        // These are the Issues filter's contents, so land there rather
                        // than on the default segment.
                        downloadsNavigator?.show(.issues)
                        navigateToDownloadsTab()
                    } label: {
                        attentionLabel(
                            systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                            tint: .red,
                            title: failures.count == 1 ? "1 download failing" : "\(failures.count) downloads failing",
                            detail: failures.first?.attentionTitle ?? ""
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notifications-failing-downloads")
                }
            }
        } else if configurationAuditStore?.hasCompletedAnAudit == true {
            Section {
                attentionLabel(
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    title: "All clear",
                    detail: "Setup checks pass and nothing is failing.",
                    showsChevron: false
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notifications-all-clear")
            }
        }
    }

    private func attentionLabel(
        systemImage: String,
        tint: Color,
        title: String,
        detail: String,
        showsChevron: Bool = true
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func checkSetupAgain(_ store: ConfigurationAuditStore) {
        Task {
            await store.refresh(
                serviceManager: arrServiceManager,
                trawlClients: trawlClientHosts,
                inputRevision: auditInputRevision
            )
        }
    }

    private func configurationAttentionTitle(_ store: ConfigurationAuditStore) -> String {
        if store.isAuditing && !store.hasCompletedAnAudit { return "Checking your setup…" }
        if let first = store.problems.first { return first.title }
        return "Setup check incomplete"
    }

    private func configurationAttentionDetail(_ store: ConfigurationAuditStore) -> String {
        if store.isAuditing && !store.hasCompletedAnAudit {
            return "Trawl is checking how your services are connected."
        }
        let otherProblems = max(store.problems.count - 1, 0)
        var parts: [String] = []
        if otherProblems > 0 {
            parts.append(otherProblems == 1 ? "and 1 other setup problem" : "and \(otherProblems) other setup problems")
        }
        if !store.unknowns.isEmpty {
            let count = store.unknowns.count
            parts.append(count == 1 ? "1 check could not be completed" : "\(count) checks could not be completed")
        }
        if parts.isEmpty {
            return store.problems.isEmpty ? "Review the affected connections and check again." : "Open Setup Check to fix it."
        }
        return parts.joined(separator: " · ")
    }

    private func refreshConfigurationAuditIfNeeded() async {
        guard let configurationAuditStore else { return }
        await configurationAuditStore.refreshIfNeeded(
            serviceManager: arrServiceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager,
            sabnzbdServiceManager: sabnzbdServiceManager,
            inputRevision: auditInputRevision
        )
    }

    /// The sheet's own tab bar, in pipeline order.
    ///
    /// A tab bar rather than a segmented control: Downloads brings its own filter
    /// bar, and a second segmented row stacked on the sheet's read as two competing
    /// switches.
    @ViewBuilder
    private var sectionTabs: some View {
        TabView(selection: $selectedTab) {
            if availableTabs.contains(.requests) {
                Tab(NotificationSheetTab.requests.rawValue, systemImage: NotificationSheetTab.requests.systemImage, value: NotificationSheetTab.requests) {
                    sectionShell(.requests)
                }
                .badge(seerrServiceManager.pendingRequests.count)
            }
            if let downloadsContent {
                Tab(NotificationSheetTab.downloads.rawValue, systemImage: NotificationSheetTab.downloads.systemImage, value: NotificationSheetTab.downloads) {
                    NavigationStack {
                        downloadsContent
                    }
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    #endif
                }
                .badge(attentionItems.count)
            }
            Tab(NotificationSheetTab.alerts.rawValue, systemImage: NotificationSheetTab.alerts.systemImage, value: NotificationSheetTab.alerts) {
                sectionShell(.alerts)
            }
            .badge(setupProblemCount)
            Tab(NotificationSheetTab.actions.rawValue, systemImage: NotificationSheetTab.actions.systemImage, value: NotificationSheetTab.actions) {
                sectionShell(.actions)
            }
        }
        .accessibilityIdentifier("notification-sheet-tabs")
    }

    private func sectionShell(_ tab: NotificationSheetTab) -> some View {
        #if os(macOS)
        let showsClose = true
        #else
        let showsClose = false
        #endif

        return AppSheetShell(
            title: tab.rawValue,
            subtitle: subtitle(for: tab),
            cancelTitle: "Close",
            cancelSystemImage: {
                #if os(macOS)
                nil
                #else
                "xmark"
                #endif
            }(),
            showsCancel: showsClose,
            usesInlineLargeTitle: true,
            minContentHeight: 520,
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Group {
                switch tab {
                case .requests:
                    NotificationRequestsTab()
                case .alerts:
                    alertsContent
                case .actions:
                    actionsContent
                case .downloads:
                    EmptyView()
                }
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

                if tab == .alerts, notificationCount > 0 {
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
    }

    // MARK: - Actions Segment

    /// Global service commands - verbs that need no specific object. Each one fans
    /// out to every configured instance of its backing service instead of asking
    /// the user to pick one, and reports a single summary banner when it lands.
    /// Per-item verbs (retry this grab, blocklist this release) belong on the rows
    /// in Downloads, not here.
    @ViewBuilder
    private var actionsContent: some View {
        let actions = availableActions
        if actions.isEmpty {
            ConnectionStatusCard(
                title: "No Quick Actions",
                message: "Connect Sonarr, Radarr, Prowlarr, Jellyfin, or SABnzbd to run service commands from here.",
                presentation: .embedded,
                systemImage: "bolt.slash",
                showsRetryCountdown: false
            )
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

    /// Only actions whose backing service is actually connected are offered -
    /// every integration in Trawl is optional, so an unconfigured service simply
    /// drops its row rather than showing a dead-end button.
    private var availableActions: [NotificationQuickAction] {
        var actions: [NotificationQuickAction] = []

        let hasSonarr = arrServiceManager.sonarrInstances.contains { $0.isConnected && $0.client != nil }
        let hasRadarr = arrServiceManager.radarrInstances.contains { $0.isConnected && $0.client != nil }
        if hasSonarr || hasRadarr {
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
        if syncService.serverState != nil {
            actions.append(contentsOf: [.pauseQBittorrent, .resumeQBittorrent])
        }

        return actions
    }

    @ViewBuilder
    private func quickActionRow(_ action: NotificationQuickAction) -> some View {
        let isRunning = inAppNotificationCenter.runningQuickActions.contains(action)
        let tint = action.tint

        Button {
            NotificationCenter.default.post(name: .trawlQuickAction, object: action.rawValue)
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
                    if !isRunning, let run = inAppNotificationCenter.lastQuickActionRuns[action.rawValue] {
                        Text(lastRunText(run))
                            .font(.caption2)
                            .foregroundStyle(run.succeeded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                            .accessibilityIdentifier("quick-action-last-run-\(action.rawValue)")
                    }
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

    /// "Last run 22:04 · 3 instances", or "Last run 22:04 · failed".
    private func lastRunText(_ run: QuickActionRunRecord) -> String {
        let time = run.date.formatted(date: .omitted, time: .shortened)
        if !run.succeeded { return "Last run \(time) · failed" }
        if run.targetCount > 1 { return "Last run \(time) · \(run.targetCount) instances" }
        return "Last run \(time)"
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
        if tokens.contains("jellyfin") { return .jellyfin }
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
        case jellyfin
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
            case .jellyfin: "Jellyfin"
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
            case .jellyfin: ServiceIdentity.jellyfin.systemImage
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
            if entry.destination != nil {
                Button {
                    openNotificationDestination(entry)
                } label: {
                    notificationRowBody(entry: entry, truncate: long)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    NotificationDetailView(
                        entry: entry,
                        icon: icon(for: entry),
                        tint: color(for: entry.style)
                    )
                } label: {
                    notificationRowBody(entry: entry, truncate: long)
                }
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

    private func openNotificationDestination(_ entry: NotificationLogEntry) {
        guard let destination = entry.destination else { return }
        dismiss()
        switch destination {
        case .series:
            navigateToSeriesTab()
        case .movies:
            navigateToMoviesTab()
        }
    }

    /// Two lines: what happened, then where and what. The time sits on the right as
    /// "4m" or "21:58"; the full date is on the detail screen, not repeated per row.
    @ViewBuilder
    private func notificationRowBody(entry: NotificationLogEntry, truncate: Bool) -> some View {
        let service = serviceContext(for: entry)
        let isNew = entry.timestamp > effectiveUnreadSinceDate

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(for: entry))
                .font(.subheadline)
                .foregroundStyle(color(for: entry.style))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(isNew ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(service.title)
                        .foregroundStyle(.tertiary)
                    if !entry.message.isEmpty {
                        Text(entry.message)
                            .foregroundStyle(.secondary)
                            .lineLimit(truncate ? 2 : 3)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            Text(NotificationTimeline.timeText(for: entry.timestamp, now: .now))
                .font(.caption)
                .foregroundStyle(isNew ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
        .padding(.vertical, 1)
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

// MARK: - Failing Download Presentation

/// How a failing download reads in the tab-bar accessory's summary line and in the
/// sheet's Needs Attention rows. Kept here rather than on `DownloadListItem` because
/// it is presentation for this surface only.
private extension DownloadListItem {
    var attentionTitle: String {
        switch self {
        case .torrent(let torrent): torrent.name
        case .arrQueue(let item, _, _, _, _): item.title ?? "Untitled release"
        case .arrHistory(let item): item.record.sourceTitle ?? "Untitled release"
        case .sab(let job): job.name
        }
    }

    var attentionDetail: String {
        let parts: [String?]
        switch self {
        case .torrent(let torrent):
            parts = [ServiceIdentity.qbittorrent.displayName, torrent.state.displayName]
        case .arrQueue(let item, let source, _, let linkedSABJob, _):
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
        case .arrQueue(_, let source, _, _, _): source == .radarr
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
/// environments, and only `PreviewHost` supplies all of them - so the fixtures
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
