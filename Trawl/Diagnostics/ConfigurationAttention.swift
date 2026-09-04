//
//  ConfigurationAttention.swift
//  Trawl
//
//  The audit's findings, put in front of the person on the screen they affect.
//

import SwiftUI
import SwiftData

/// Whether the contextual banners may render on this launch.
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
    /// Pass `forContextualBanner: true` on a screen that only wants the audit in
    /// order to draw a `ConfigurationAttentionBanner`, so that a UI-test launch -
    /// which hides those banners - does not fan out across every service to build
    /// findings nothing will render.
    func refreshesConfigurationAudit(forContextualBanner: Bool = false) -> some View {
        modifier(ConfigurationAuditTask(isForContextualBanner: forContextualBanner))
    }
}

/// A short line about the setup, on the screen it stops working.
///
/// Deliberately not the wizard, and not a modal. The wizard is the place to walk
/// every finding; this is the place to notice one - so it names the first, counts the
/// rest, opens the wizard, and gets out of the way. It renders nothing at all when
/// the topic is clear, which is why `configurationAttention(_:)` can be applied
/// unconditionally.
///
/// Notes are excluded on purpose. "These two hostnames differ" is worth reading once
/// in the wizard and is not worth a standing banner on the Downloads screen: a banner
/// people learn to ignore is worse than no banner.
struct ConfigurationAttentionBanner: View {
    let topic: ConfigurationIssueTopic
    let action: () -> Void

    @Environment(ConfigurationAuditStore.self) private var auditStore: ConfigurationAuditStore?

    var body: some View {
        if let headline = relevant.first {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: headline.severity == .problem ? "exclamationmark.triangle.fill" : "questionmark.diamond.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // An inset card, not a slab of chrome. This used to be edge-to-edge
                // with `.background(.bar)` and a `Divider()` under it, which reads
                // correctly on iPhone - it tucks under an opaque navigation bar and
                // looks like part of it. On iPadOS the bar is translucent and the
                // inset's content is laid out into the bar's own region, so the slab
                // painted up behind the toolbar and stopped partway across the row,
                // leaving a hard seam with the chevron floating outside it. The
                // button's frame reaching the top of the window is the same fact seen
                // from the test side.
                //
                // Matching `TrawlInlineCallout` rather than inventing a third style:
                // this is the same kind of notice - one sentence about the user's own
                // setup, with one thing to do about it.
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("configuration-attention-\(topic.rawValue)")
        }
    }

    private var relevant: [ConfigurationIssue] {
        guard ConfigurationAttention.isContextuallyVisible else { return [] }
        guard let auditStore, auditStore.hasCompletedAnAudit else { return [] }
        return auditStore.issues.concerning(topic).filter { $0.severity != .note }
    }

    private var summary: String {
        let remaining = relevant.count - 1
        guard remaining > 0 else { return "Open the setup check to fix this." }
        return remaining == 1
            ? "And 1 other thing needs attention."
            : "And \(remaining) other things need attention."
    }
}

/// Owns the banner, the wizard it opens, and the audit that feeds both.
///
/// The sheet lives here rather than on the banner itself: a `.sheet` attached inside
/// a `safeAreaInset`'s content does not present, so the button only reports the tap
/// and the screen it decorates does the presenting.
private struct ConfigurationAttentionInset: ViewModifier {
    let topic: ConfigurationIssueTopic

    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(ConfigurationAuditStore.self) private var auditStore: ConfigurationAuditStore?
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager: CleanuparrServiceManager?
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @State private var showSetupCheck = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                ConfigurationAttentionBanner(topic: topic) { showSetupCheck = true }
            }
            .refreshesConfigurationAudit(forContextualBanner: true)
            .sheet(isPresented: $showSetupCheck) {
                if let auditStore {
                    ConfigurationWizardView(
                        issues: auditStore.issues,
                        onDismissIssue: { auditStore.dismiss($0) },
                        onRecheck: { await recheck(auditStore) }
                    )
                    .environment(arrServiceManager)
                }
            }
    }

    private func recheck(_ auditStore: ConfigurationAuditStore) async {
        let clients = ConfigurationAuditInput.trawlClientHosts(
            qbittorrentServers: qbittorrentServers,
            sabnzbdProfiles: sabnzbdProfiles
        )
        await auditStore.refresh(
            serviceManager: arrServiceManager,
            trawlClients: clients,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager,
            inputRevision: ConfigurationAuditInput.revision(
                arrServiceManager: arrServiceManager,
                trawlClients: clients,
                seerrServiceManager: seerrServiceManager,
                cleanuparrServiceManager: cleanuparrServiceManager
            )
        )
    }
}

extension View {
    /// Shows the setup-attention banner for `topic` above this screen, and keeps the
    /// audit fresh for it.
    ///
    /// A top safe-area inset rather than a row in each screen's list: the four
    /// screens that carry one are a `List`, a search results view, a dashboard and a
    /// browser, and threading a row into each means knowing the shape of all four.
    /// It is chrome, not content, and it occupies no height at all when there is
    /// nothing to say.
    func configurationAttention(_ topic: ConfigurationIssueTopic) -> some View {
        modifier(ConfigurationAttentionInset(topic: topic))
    }
}
