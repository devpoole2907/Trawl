//
//  ConfigurationIssue.swift
//  Trawl
//
//  One finding about how the user's services are wired to each other.
//

import Foundation

/// What kind of discrepancy this is. Stable identities rather than free text, so a
/// surface can filter, count, or deep-link a specific check without string matching.
enum ConfigurationIssueKind: String, Hashable, Sendable, CaseIterable {
    case serviceUnreachable
    case configurationUnavailable
    case noDownloadClient
    case downloadClientsAllDisabled
    case downloadClientElsewhere
    case downloadClientUnused
    case noRootFolder
    case rootFolderInaccessible
    case rootFolderShared
    case noIndexers
    case noAutomaticIndexer
    case missingProwlarrApplication
    case prowlarrSyncDisabled
    case prowlarrDetectedButNotConnected
    case bazarrAppNotLinked
    case bazarrPointsElsewhere
    case bazarrNoLanguageProfile
    case bazarrNoProvider
    case downloadClientCategoryShared
    case remotePathMappingMissing
    case serviceHealthError
    case serviceHealthWarning
    case seerrNotInitialized
    case seerrMissingDVR
    case seerrNoDefaultDVR
    case seerrDVRIncomplete
    case cleanuparrNotReady
}

/// Which part of the app a finding is about.
///
/// Derived from the kind rather than stored, so a new check cannot forget to declare
/// one. It exists for the contextual banners: the Downloads screen shows what stops
/// downloads working and nothing else, and asking it to know which of fifteen kinds
/// those are would put the audit's taxonomy into every screen that reads it.
enum ConfigurationIssueTopic: String, Hashable, Sendable, CaseIterable {
    case connection
    case downloads
    case library
    case search
    case subtitles
    case requests
    case maintenance
}

/// How much this matters.
///
/// The split exists because several of these are legitimately fine: a Docker
/// hostname and a LAN IP are the same box, and a second server may be deliberately
/// bare while it is being set up. A note says "this looked odd"; a problem says
/// "something you expect to work cannot".
enum ConfigurationIssueSeverity: Int, Hashable, Sendable, Comparable {
    case note = 0
    /// Trawl could not prove whether this part of the setup is healthy.
    case unknown = 1
    case problem = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the issue is about, so a surface can group by server without re-deriving it.
struct ConfigurationIssueSubject: Hashable, Sendable {
    let instanceID: UUID?
    let serviceType: ArrServiceType?
    let displayName: String

    init(instanceID: UUID? = nil, serviceType: ArrServiceType? = nil, displayName: String) {
        self.instanceID = instanceID
        self.serviceType = serviceType
        self.displayName = displayName
    }
}

/// Where in Trawl an issue gets fixed.
///
/// Deliberately not `MoreDestination`: the audit is a model, and binding it to the
/// navigation enum would stop it being usable from anywhere that isn't the More
/// tab's navigation stack. Surfaces map this to whatever routing they have.
enum ConfigurationFixDestination: Hashable, Sendable {
    case downloadClientsManagement
    case arrDownloadClients(ArrServiceType, instanceID: UUID)
    case rootFolders(instanceID: UUID)
    case prowlarrIndexers
    case prowlarrApplications
    case bazarrLinkedApplications(instanceID: UUID)
    case bazarrLanguageProfiles(instanceID: UUID)
    case bazarrProviders(instanceID: UUID)
    case serviceSettings(ArrServiceType, instanceID: UUID?)
    case arrRemotePathMappings
    case arrHealth
    case seerrLinkedApplications
    case cleanuparr
}

/// What can be done about an issue.
enum ConfigurationIssueFix: Hashable, Sendable {
    /// Trawl cannot make this change; the guidance says where it is made instead.
    case manual(guidance: String)
    /// A screen in Trawl resolves it. `actionTitle` labels the button that goes there.
    case open(ConfigurationFixDestination, actionTitle: String, guidance: String)

    var guidance: String {
        switch self {
        case .manual(let guidance): guidance
        case .open(_, _, let guidance): guidance
        }
    }

    var destination: ConfigurationFixDestination? {
        switch self {
        case .manual: nil
        case .open(let destination, _, _): destination
        }
    }

    var actionTitle: String? {
        switch self {
        case .manual: nil
        case .open(_, let title, _): title
        }
    }
}

/// A single finding. Values only - no view, no client - so the same audit can drive
/// a badge, a settings row, a wizard page, or a test.
struct ConfigurationIssue: Identifiable, Hashable, Sendable {
    let kind: ConfigurationIssueKind
    let severity: ConfigurationIssueSeverity
    let subject: ConfigurationIssueSubject
    let title: String
    let detail: String
    let fix: ConfigurationIssueFix
    /// Distinguishes two findings of the same kind on the same subject, such as a
    /// Bazarr missing both Sonarr and Radarr or two shared root-folder paths.
    let discriminator: String?

    init(
        kind: ConfigurationIssueKind,
        severity: ConfigurationIssueSeverity,
        subject: ConfigurationIssueSubject,
        title: String,
        detail: String,
        fix: ConfigurationIssueFix,
        discriminator: String? = nil
    ) {
        self.kind = kind
        self.severity = severity
        self.subject = subject
        self.title = title
        self.detail = detail
        self.fix = fix
        self.discriminator = discriminator
    }

    /// Stable across refreshes, so a list can animate and a dismissal can stick:
    /// the same fault on the same server keeps the same id.
    var id: String {
        let scope = subject.instanceID?.uuidString
            ?? subject.serviceType?.rawValue
            ?? subject.displayName
        return [kind.rawValue, scope, discriminator]
            .compactMap { $0 }
            .joined(separator: "-")
    }

    var systemImage: String {
        switch kind {
        case .serviceUnreachable:
            "network.slash"
        case .configurationUnavailable:
            "questionmark.diamond"
        case .noDownloadClient, .downloadClientsAllDisabled, .downloadClientElsewhere, .downloadClientUnused:
            "arrow.down.circle"
        case .noRootFolder, .rootFolderInaccessible, .rootFolderShared:
            "folder"
        case .noIndexers, .noAutomaticIndexer:
            "magnifyingglass"
        case .missingProwlarrApplication, .prowlarrSyncDisabled,
             .bazarrAppNotLinked, .bazarrPointsElsewhere:
            "link"
        case .prowlarrDetectedButNotConnected:
            "sparkle.magnifyingglass"
        case .bazarrNoLanguageProfile:
            "globe.badge.chevron.backward"
        case .bazarrNoProvider:
            "captions.bubble"
        case .downloadClientCategoryShared:
            "tray.2"
        case .remotePathMappingMissing:
            "arrow.triangle.branch"
        case .serviceHealthError, .serviceHealthWarning:
            "stethoscope"
        case .seerrNotInitialized, .seerrMissingDVR, .seerrNoDefaultDVR, .seerrDVRIncomplete:
            "person.crop.circle.badge.questionmark"
        case .cleanuparrNotReady:
            "sparkles"
        }
    }

    var topic: ConfigurationIssueTopic { kind.topic }
}

extension ConfigurationIssueKind {
    /// A connection or health fault is `.connection` wherever it was raised: it is
    /// the reason every other check on that server is unknown, so a screen that
    /// filters to its own topic would otherwise show nothing at all while the server
    /// it depends on is unreachable. `contextualTopics` below is what a screen uses.
    var topic: ConfigurationIssueTopic {
        switch self {
        case .serviceUnreachable, .configurationUnavailable,
             .serviceHealthError, .serviceHealthWarning:
            .connection
        case .noDownloadClient, .downloadClientsAllDisabled, .downloadClientElsewhere,
             .downloadClientUnused, .downloadClientCategoryShared, .remotePathMappingMissing:
            .downloads
        case .noRootFolder, .rootFolderInaccessible, .rootFolderShared:
            .library
        case .noIndexers, .noAutomaticIndexer, .missingProwlarrApplication,
             .prowlarrSyncDisabled, .prowlarrDetectedButNotConnected:
            .search
        case .bazarrAppNotLinked, .bazarrPointsElsewhere,
             .bazarrNoLanguageProfile, .bazarrNoProvider:
            .subtitles
        case .seerrNotInitialized, .seerrMissingDVR, .seerrNoDefaultDVR, .seerrDVRIncomplete:
            .requests
        case .cleanuparrNotReady:
            .maintenance
        }
    }
}

extension Array where Element == ConfigurationIssue {
    var problems: [ConfigurationIssue] { filter { $0.severity == .problem } }

    /// The findings a screen about `topic` should show.
    ///
    /// Connection and health faults come along with every topic on purpose: they are
    /// the reason that topic's own checks could not be run, so a Downloads screen
    /// filtering them out would give a clean bill of health for a server it cannot
    /// reach - the exact failure the unknown severity exists to prevent.
    func concerning(_ topic: ConfigurationIssueTopic) -> [ConfigurationIssue] {
        filter { $0.topic == topic || $0.topic == .connection }
    }

    var unknowns: [ConfigurationIssue] { filter { $0.severity == .unknown } }
    var notes: [ConfigurationIssue] { filter { $0.severity == .note } }

    /// Problems first, then grouped by the server they concern, so a list reads as
    /// "what is broken, and where" rather than in check order.
    var displayOrdered: [ConfigurationIssue] {
        sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.subject.displayName != rhs.subject.displayName {
                return lhs.subject.displayName.localizedCaseInsensitiveCompare(rhs.subject.displayName) == .orderedAscending
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }
}
