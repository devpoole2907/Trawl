import SwiftUI

/// Section headers for the Actions segment and Tools menu, ordered the way they render.
enum NotificationQuickActionGroup: String, CaseIterable, Identifiable, Sendable {
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

/// A global service verb. Everything here is object-free - it acts on whole
/// services, never on a single queue item, grab, or release.
enum NotificationQuickAction: String, CaseIterable, Identifiable, Sendable {
    case refreshLibrary
    case rssSync
    case searchAllMissing
    case syncIndexers
    case rescanJellyfinLibraries
    case pauseUsenetQueue
    case resumeUsenetQueue
    case pauseQBittorrent
    case resumeQBittorrent

    var id: String { rawValue }

    var group: NotificationQuickActionGroup {
        switch self {
        case .refreshLibrary, .rssSync, .searchAllMissing: .library
        case .syncIndexers: .indexers
        case .rescanJellyfinLibraries: .mediaServer
        case .pauseUsenetQueue, .resumeUsenetQueue, .pauseQBittorrent, .resumeQBittorrent: .downloads
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
        case .pauseQBittorrent: "Pause All Torrents"
        case .resumeQBittorrent: "Resume All Torrents"
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
        case .pauseQBittorrent: "Pause every torrent in qBittorrent."
        case .resumeQBittorrent: "Resume every torrent in qBittorrent."
        }
    }

    var systemImage: String {
        switch self {
        case .refreshLibrary: "arrow.clockwise"
        case .rssSync: "dot.radiowaves.up.forward"
        case .searchAllMissing: "magnifyingglass"
        case .syncIndexers: "arrow.triangle.2.circlepath"
        case .rescanJellyfinLibraries: "rectangle.stack.badge.play"
        case .pauseUsenetQueue, .pauseQBittorrent: "pause.circle"
        case .resumeUsenetQueue, .resumeQBittorrent: "play.circle"
        }
    }

    var tint: Color {
        switch self {
        case .refreshLibrary, .rssSync, .searchAllMissing: .accentColor
        case .syncIndexers: ServiceIdentity.prowlarr.brandColor
        case .rescanJellyfinLibraries: ServiceIdentity.jellyfin.brandColor
        case .pauseUsenetQueue, .resumeUsenetQueue: ServiceIdentity.sabnzbd.brandColor
        case .pauseQBittorrent, .resumeQBittorrent: ServiceIdentity.qbittorrent.brandColor
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
        case .pauseQBittorrent: "Pause Torrents"
        case .resumeQBittorrent: "Resume Torrents"
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
        case .pauseUsenetQueue, .pauseQBittorrent: "Paused"
        case .resumeUsenetQueue, .resumeQBittorrent: "Resumed"
        }
    }
}

/// One connected instance an action fans out to, paired with the label used for
/// it in the summary banner.
struct ArrActionTarget<Client: SharedArrClient>: Sendable {
    let name: String
    let client: Client
}

enum NotificationQuickActionStep: Sendable {
    case succeeded(String)
    case failed(target: String, message: String)
}

/// Collected results of a fan-out, so a partial failure can be reported as one
/// line instead of a stack of per-service banners.
struct NotificationQuickActionOutcome: Sendable {
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

extension InAppNotificationCenter {
    var runningQuickActions: Set<NotificationQuickAction> {
        get {
            Set(runningQuickActionIDs.compactMap { NotificationQuickAction(rawValue: $0) })
        }
        set {
            runningQuickActionIDs = Set(newValue.map(\.rawValue))
        }
    }
}

@MainActor
struct QuickActionRunner {
    let arrServiceManager: ArrServiceManager
    let jellyfinServiceManager: JellyfinServiceManager
    let sabnzbdServiceManager: SABnzbdServiceManager
    let torrentService: TorrentService
    let inAppNotificationCenter: InAppNotificationCenter

    /// Connected Sonarr instances. The label falls back to the plain service name
    /// when there's only one instance so summaries read "Refreshed Sonarr" rather
    /// than echoing a profile name the user never had to choose between.
    var sonarrTargets: [ArrActionTarget<SonarrAPIClient>] {
        let connected = arrServiceManager.sonarrInstances.filter(\.isConnected)
        return connected.compactMap { entry in
            guard let client = entry.client else { return nil }
            let name = connected.count > 1 ? entry.displayName : ServiceIdentity.sonarr.displayName
            return ArrActionTarget(name: name, client: client)
        }
    }

    var radarrTargets: [ArrActionTarget<RadarrAPIClient>] {
        let connected = arrServiceManager.radarrInstances.filter(\.isConnected)
        return connected.compactMap { entry in
            guard let client = entry.client else { return nil }
            let name = connected.count > 1 ? entry.displayName : ServiceIdentity.radarr.displayName
            return ArrActionTarget(name: name, client: client)
        }
    }

    /// Runs an action once, keeping the row spinning and untappable until every
    /// fanned-out call has come back.
    func perform(_ action: NotificationQuickAction) {
        guard !inAppNotificationCenter.runningQuickActions.contains(action) else { return }
        inAppNotificationCenter.runningQuickActions.insert(action)
        Task {
            let outcome = await runOutcome(for: action)
            inAppNotificationCenter.runningQuickActions.remove(action)
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

        case .pauseQBittorrent:
            let paused = await attempt(ServiceIdentity.qbittorrent.displayName) {
                try await torrentService.pauseTorrents(hashes: ["all"])
            }
            outcome.append(paused)

        case .resumeQBittorrent:
            let resumed = await attempt(ServiceIdentity.qbittorrent.displayName) {
                try await torrentService.resumeTorrents(hashes: ["all"])
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

    /// One summary banner per action rather than one per service - on a partial
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
}
