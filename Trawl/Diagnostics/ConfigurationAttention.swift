//
//  ConfigurationAttention.swift
//  Trawl
//
//  Keeping the configuration audit fresh. Its findings are shown in one place: the
//  notifications sheet's Alerts tab (and Setup Check, which it opens).
//

import SwiftUI
import SwiftData

/// Whether passive, screen-level setup notices may render on this launch.
///
/// The setup-attention banners that used to sit above Downloads, Requests,
/// Subtitles, Search and the sidebar are gone: findings live in the notifications
/// sheet's Alerts tab, which already says when the setup needs attention, and a
/// floating card repeating it in the sidebar read as clutter. What this still gates
/// is the queue-collision notice on Downloads and the passive audit refresh.
///
/// The same problem the discovery tips have, for the same reason. Nearly every
/// journey suite in the UI target asserts against a screen a banner could sit above,
/// and a fixture that answers `/downloadclient` with an empty array is - correctly -
/// a server with no download client, so the audit would find something on most of
/// them and push the first row down. The default for a UI-test launch is therefore
/// silence, and a test that is *about* a banner opts back in through
/// `TRAWL_UITEST_SHOW_ATTENTION`.
///
/// Only the contextual banners are gated. The System hub's Setup Check and the
/// notification sheet's attention card are the audit's own surfaces and are
/// unaffected: a test that opens either is asking to see findings.
enum ConfigurationAttention {
    static var isContextuallyVisible: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("-TrawlUITestInMemoryStore") else { return true }
        return process.environment["TRAWL_UITEST_SHOW_ATTENTION"] == "1"
        #else
        return true
        #endif
    }
}

/// Keeps the shared audit fresh for whichever screen is showing its findings.
///
/// The store cannot get two things for itself: the download clients Trawl is
/// connected to, which live in SwiftData, and a revision string that changes when
/// any of that does. Three surfaces need both - the System hub, the notifications
/// sheet, and every contextual banner - and spelling it out per screen is how two
/// of them end up disagreeing about whether the setup is healthy.
///
/// `refreshIfNeeded` does the deciding: a configuration change invalidates
/// immediately, and otherwise the cached result stands, so putting this on a screen
/// that appears often does not fan out across every service each time.
private struct ConfigurationAuditTask: ViewModifier {
    /// True on a screen whose only reason to audit is its contextual banner, which a
    /// UI-test launch suppresses. The audit's own surfaces pass false and always run:
    /// a test that opens Setup Check is asking for findings.
    let isForContextualBanner: Bool

    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(ConfigurationAuditStore.self) private var auditStore: ConfigurationAuditStore?
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager: CleanuparrServiceManager?
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    func body(content: Content) -> some View {
        content.task(id: revision) {
            guard !isForContextualBanner || ConfigurationAttention.isContextuallyVisible else { return }
            guard let auditStore else { return }
            await auditStore.refreshIfNeeded(
                serviceManager: arrServiceManager,
                trawlClients: trawlClientHosts,
                seerrServiceManager: seerrServiceManager,
                cleanuparrServiceManager: cleanuparrServiceManager,
                sabnzbdServiceManager: sabnzbdServiceManager,
                inputRevision: revision
            )
        }
    }

    private var trawlClientHosts: [DownloadClientLinkKind: [String]] {
        ConfigurationAuditInput.trawlClientHosts(
            qbittorrentServers: qbittorrentServers,
            sabnzbdProfiles: sabnzbdProfiles
        )
    }

    private var revision: String {
        ConfigurationAuditInput.revision(
            arrServiceManager: arrServiceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager
        )
    }
}

/// The two derivations every audit call site needs, in one place so they cannot
/// drift apart. Static rather than a view, because the System hub and the
/// notifications sheet also drive an explicit recheck and need the same values.
enum ConfigurationAuditInput {
    static func trawlClientHosts(
        qbittorrentServers: [ServerProfile],
        sabnzbdProfiles: [SABnzbdServiceProfile]
    ) -> [DownloadClientLinkKind: [String]] {
        var hosts: [DownloadClientLinkKind: [String]] = [:]
        let qbittorrentHosts = qbittorrentServers.filter(\.isActive).map(\.hostURL)
        if !qbittorrentHosts.isEmpty { hosts[.qbittorrent] = qbittorrentHosts }
        let sabnzbdHosts = sabnzbdProfiles.filter(\.isEnabled).map(\.hostURL)
        if !sabnzbdHosts.isEmpty { hosts[.sabnzbd] = sabnzbdHosts }
        return hosts
    }

    /// Everything a finding could depend on, folded into one string.
    ///
    /// A `.task(id:)` on this re-runs the audit when a server is added, removed,
    /// reconnected or repointed, and does nothing when the user merely revisits the
    /// screen - which is what keeps a passive surface from re-auditing on every
    /// appearance while still never showing a stale verdict after a repair.
    static func revision(
        arrServiceManager: ArrServiceManager,
        trawlClients: [DownloadClientLinkKind: [String]],
        seerrServiceManager: SeerrServiceManager?,
        cleanuparrServiceManager: CleanuparrServiceManager?
    ) -> String {
        let clients = trawlClients
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value.sorted().joined(separator: ","))" }
            .joined(separator: "|")
        let seerr = seerrServiceManager.map {
            "seerr:\($0.hasConfiguredProfile ? "1" : "0")\($0.isConnected ? "c" : "-")\($0.activeProfileID?.uuidString ?? "")"
        } ?? ""
        let cleanuparr = cleanuparrServiceManager.map {
            "cleanuparr:\($0.hasConfiguredProfile ? "1" : "0")\($0.isConnected ? "c" : "-")\($0.isReady.map { $0 ? "r" : "n" } ?? "?")"
        } ?? ""
        return "\(arrServiceManager.arrConnectionKey)|\(clients)|\(seerr)|\(cleanuparr)"
    }
}

extension View {
    /// Runs the configuration audit for this screen, if the cached result is stale.
    ///
    /// Pass `forContextualBanner: true` for a passive refresh - one that only keeps
    /// the notification bar's summary current, rather than a screen showing findings.
    /// A UI-test launch skips those, so fixture faults do not change the bar's text
    /// under suites that are not about the audit.
    func refreshesConfigurationAudit(forContextualBanner: Bool = false) -> some View {
        modifier(ConfigurationAuditTask(isForContextualBanner: forContextualBanner))
    }
}
