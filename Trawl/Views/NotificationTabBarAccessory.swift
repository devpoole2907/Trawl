#if os(iOS)
import SwiftUI

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
                .foregroundStyle(.tint)

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
                .foregroundStyle(.tint)

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

    private var notificationIcon: some View {
        Group {
            if inAppNotificationCenter.hasRunningImportJobs {
                Image(systemName: "tray.and.arrow.down.fill")
                    .symbolRenderingMode(.hierarchical)
            } else {
                Image(systemName: "bell.fill")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .overlay(alignment: .topTrailing) {
            if inAppNotificationCenter.hasRunningImportJobs {
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
