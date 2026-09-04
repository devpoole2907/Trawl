//
//  TrawlTips.swift
//  Trawl
//
//  Feature-discovery tips, configured once at launch.
//
//  Every tip Trawl shows points at something the app already does but does not
//  advertise: a title that is secretly a menu, badges that mean more than they look
//  like, a swipe that saves a round trip into a detail screen. None of them teach a
//  feature the user could not find eventually - they shorten the eventually.
//
//  Because of that, each one is capped at a single appearance (`MaxDisplayCount(1)`)
//  and invalidated the moment the user does the thing it advertises. A tip that keeps
//  explaining a gesture you already use is worse than no tip at all.

import OSLog
import TipKit

/// The stable identifiers Trawl's tips are stored under.
///
/// Explicit and versioned rather than derived from the type name, which is TipKit's
/// default. The default ties persisted state to a Swift type name, so renaming or
/// moving a tip silently resets it for everyone who had already dismissed it - and
/// re-shows a tip they have seen. The `.vN` suffix makes the opposite intentional:
/// bumping it is how you say "this is materially different copy, show it again."
nonisolated enum TrawlTipID {
    static let downloadsSwitchQueues = "trawl.downloads.switch-queues.v1"
    static let arrBlendedLibrary = "trawl.arr.blended-library.v1"
    static let calendarSubscribe = "trawl.calendar.subscribe.v1"
    static let arrLibraryQuickActions = "trawl.arr.library-quick-actions.v1"
}

enum TrawlTips {
    private static let logger = Logger(subsystem: "com.poole.james.Trawl", category: "Tips")

    /// Configures TipKit for this launch.
    ///
    /// Called from `TrawlApp.init()` *before* the DEBUG UI-test branch returns, so the
    /// test path is configured too - it is the path that most needs tips suppressed,
    /// and an unconfigured `Tips` API is what makes `hideAllTipsForTesting` a no-op.
    ///
    /// Failure is logged and swallowed. A datastore that will not open is a reason to
    /// go without tips, not a reason to refuse to launch: nothing in Trawl's actual
    /// function depends on them.
    static func configure() {
        applyTestingOverridesIfNeeded()

        do {
            try Tips.configure([
                // Daily, not immediate: these are discovery hints, and two of them can
                // become eligible on the same screen. One a day keeps a first launch
                // from turning into a tour.
                .displayFrequency(.daily),
                // The app's own datastore. Deliberately not shared with the share or
                // widget extensions and deliberately not CloudKit-backed: a tip is
                // about this app on this device, and syncing "has seen the swipe hint"
                // across devices is state Trawl would have to keep working forever for
                // no user-visible benefit.
                .datastoreLocation(.applicationDefault)
            ])
        } catch {
            logger.error("TipKit configuration failed; continuing without tips: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Suppresses tips for UI tests, unless a test has asked for a specific one.
    ///
    /// Every existing journey suite asserts against screens a tip could cover, and a
    /// popover anchored to a toolbar item swallows the taps aimed at it - so the
    /// default for a UI-test launch is silence. Tests that are *about* a tip opt back
    /// in one at a time through `TRAWL_UITEST_SHOW_TIP`, which TipKit treats as the
    /// higher-priority override, so it wins over the blanket hide above it.
    ///
    /// Neither call touches the real datastore, and neither runs outside DEBUG: an
    /// ordinary launch must never reset or override what the user has already seen.
    private static func applyTestingOverridesIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-TrawlUITestInMemoryStore") else { return }

        // The tip datastore outlives the app install, so a tip shown - or permanently
        // invalidated - by one run stays that way for every run after it, on that
        // simulator, forever. That is not a hypothetical: an unrelated journey routing
        // to Torrents once burned the queue-switch tip, and the test that asserts it
        // appears could never pass again. `-TrawlUITestInMemoryStore` already means
        // "this launch keeps nothing", and the tips are the last thing that did.
        try? Tips.resetDatastore()

        Tips.hideAllTipsForTesting()

        guard let requested = ProcessInfo.processInfo.environment["TRAWL_UITEST_SHOW_TIP"],
              let tip = tipForTesting(id: requested)
        else { return }

        Tips.showTipsForTesting([tip])
        #endif
    }

    #if DEBUG
    /// Maps a stable tip ID to the tip a UI test wants shown.
    ///
    /// Keyed by the same identifier the tip persists under, so a test names the tip
    /// the way the datastore does rather than through a second parallel vocabulary.
    /// Returns the *type*, which is what `showTipsForTesting` takes.
    private static func tipForTesting(id: String) -> (any Tip.Type)? {
        switch id {
        case TrawlTipID.downloadsSwitchQueues: DownloadsQueueSwitchTip.self
        case TrawlTipID.arrBlendedLibrary: ArrBlendedLibraryTip.self
        case TrawlTipID.calendarSubscribe: ArrCalendarSubscribeTip.self
        case TrawlTipID.arrLibraryQuickActions: ArrLibraryQuickActionsTip.self
        default: nil
        }
    }
    #endif
}
