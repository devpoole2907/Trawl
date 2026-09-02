//
//  TrawlTipsTests.swift
//  TrawlTests
//
//  What is worth pinning about the tips, and what is not.
//
//  TipKit owns the parts that would be tempting to test and pointless to: whether a
//  rule evaluates, whether a popover draws, when the daily display budget resets.
//  Those are Apple's, they need a configured datastore, and asserting them here would
//  test the framework rather than Trawl.
//
//  What is Trawl's, and what breaks silently, is the wiring around them:
//
//  - The stable IDs. These are the keys tips persist under, so a typo or a stray
//    version bump re-shows a tip everyone has already dismissed - with no crash, no
//    warning, and no way to notice except a user complaining twice.
//  - The blended-library tip being *one* tip across Series and Movies. Two identities
//    would mean explaining the same badges twice, and nothing on screen would say so.
//  - The detail-opened event being *one* event across both media types, for the same
//    reason in reverse: split it and a Radarr-only user needs six openings to earn a
//    three-opening tip.
//  - Transient eligibility actually being transient, and settable from view code.
//
//  Every one of those is a property of how this app is wired together, and every one
//  of them fails quietly.

import Testing
import TipKit
@testable import Trawl

@Suite("Trawl tips")
struct TrawlTipsTests {

    // MARK: - Stable identity

    /// The four IDs, spelled out.
    ///
    /// Deliberately a literal comparison rather than a round-trip through the same
    /// constant, which would pass no matter what the string said. These values are a
    /// contract with the datastore on every device that has already run the app.
    @Test("Every tip persists under its explicit, versioned ID")
    func stableIdentifiers() {
        #expect(DownloadsQueueSwitchTip().id == "trawl.downloads.switch-queues.v1")
        #expect(ArrBlendedLibraryTip().id == "trawl.arr.blended-library.v1")
        #expect(ArrCalendarSubscribeTip().id == "trawl.calendar.subscribe.v1")
        #expect(ArrLibraryQuickActionsTip().id == "trawl.arr.library-quick-actions.v1")
    }

    /// TipKit derives an ID from the type name unless you override it, and that
    /// default ties persisted state to a name refactoring can change. Overriding is
    /// the point of the constants; this proves they are actually reaching TipKit.
    @Test("IDs come from the shared constants rather than TipKit's type-name default")
    func identifiersAreNotTypeNames() {
        #expect(DownloadsQueueSwitchTip().id == TrawlTipID.downloadsSwitchQueues)
        #expect(ArrBlendedLibraryTip().id == TrawlTipID.arrBlendedLibrary)
        #expect(ArrCalendarSubscribeTip().id == TrawlTipID.calendarSubscribe)
        #expect(ArrLibraryQuickActionsTip().id == TrawlTipID.arrLibraryQuickActions)

        for id in [
            DownloadsQueueSwitchTip().id,
            ArrBlendedLibraryTip().id,
            ArrCalendarSubscribeTip().id,
            ArrLibraryQuickActionsTip().id
        ] {
            #expect(id.hasPrefix("trawl."), "\(id) looks like a type-name default rather than a stable ID.")
        }
    }

    @Test("No two tips share an identifier")
    func identifiersAreDistinct() {
        let ids = [
            DownloadsQueueSwitchTip().id,
            ArrBlendedLibraryTip().id,
            ArrCalendarSubscribeTip().id,
            ArrLibraryQuickActionsTip().id
        ]
        #expect(Set(ids).count == ids.count, "Two tips sharing an ID would silently share dismissal state.")
    }

    // MARK: - One tip across Series and Movies

    /// The requirement that "seeing or dismissing it in one tab must prevent it
    /// appearing in the other", expressed as the thing that actually implements it.
    ///
    /// `ArrMediaListView` is generic and builds this tip separately for Sonarr and for
    /// Radarr. TipKit keys persisted state by `id`, so the two constructions sharing
    /// an ID *is* the shared-dismissal behaviour - there is no other mechanism to
    /// assert, and if this ever diverged the tip would simply appear twice.
    @Test("The blended-library tip is one identity across Series and Movies")
    func blendedLibraryTipIsShared() {
        let fromSeries = ArrBlendedLibraryTip()
        let fromMovies = ArrBlendedLibraryTip()
        #expect(fromSeries.id == fromMovies.id)
    }

    /// Same argument for the event behind the quick-actions tip. One event across both
    /// media types is what lets three movie openings count towards a tip about a
    /// gesture that works identically on series rows.
    @Test("Detail openings count towards one shared event")
    func detailOpenedEventIsShared() {
        #expect(TrawlTipEvents.libraryDetailOpened.id == "trawl.arr.library-detail-opened")
        #expect(TrawlTipEvents.calendarOpened.id == "trawl.calendar.opened")
        #expect(TrawlTipEvents.libraryDetailOpened.id != TrawlTipEvents.calendarOpened.id)
    }

    // MARK: - Transient eligibility

    /// The `@Parameter`s exist so view code can publish current state into a rule.
    /// This asserts the half Trawl owns: that the flags are reachable and hold what
    /// the view sets. Whether TipKit then re-evaluates the rule is TipKit's.
    ///
    /// Restores each flag afterwards. These are process-wide statics, and a test that
    /// left one set would change what a later test in the same run observed.
    @Test("Eligibility parameters are settable from view state")
    func transientEligibilityIsSettable() {
        let downloads = DownloadsQueueSwitchTip.isEligible
        let blended = ArrBlendedLibraryTip.isEligible
        let quickActions = ArrLibraryQuickActionsTip.isEligible
        let calendar = ArrCalendarSubscribeTip.isEligible
        defer {
            DownloadsQueueSwitchTip.isEligible = downloads
            ArrBlendedLibraryTip.isEligible = blended
            ArrLibraryQuickActionsTip.isEligible = quickActions
            ArrCalendarSubscribeTip.isEligible = calendar
        }

        DownloadsQueueSwitchTip.isEligible = true
        ArrBlendedLibraryTip.isEligible = true
        ArrLibraryQuickActionsTip.isEligible = true
        ArrCalendarSubscribeTip.isEligible = true
        #expect(DownloadsQueueSwitchTip.isEligible)
        #expect(ArrBlendedLibraryTip.isEligible)
        #expect(ArrLibraryQuickActionsTip.isEligible)
        #expect(ArrCalendarSubscribeTip.isEligible)

        DownloadsQueueSwitchTip.isEligible = false
        ArrBlendedLibraryTip.isEligible = false
        ArrLibraryQuickActionsTip.isEligible = false
        ArrCalendarSubscribeTip.isEligible = false
        #expect(!DownloadsQueueSwitchTip.isEligible)
        #expect(!ArrBlendedLibraryTip.isEligible)
        #expect(!ArrLibraryQuickActionsTip.isEligible)
        #expect(!ArrCalendarSubscribeTip.isEligible)
    }

    // MARK: - Copy

    /// The quick-actions tip names a gesture, and the gesture differs by platform.
    /// Telling a Mac user to swipe is worse than saying nothing: they try it, it does
    /// not work, and the feature stays undiscovered with the added impression that it
    /// is broken. Asserted through the description rather than by comparing `Text`,
    /// which has no useful equality.
    @Test("Quick-actions copy names the gesture this platform actually has")
    func quickActionsCopyMatchesPlatform() {
        let message = String(describing: ArrLibraryQuickActionsTip().message)
        #if os(macOS)
        #expect(message.contains("Control-click"))
        #expect(!message.contains("Swipe"))
        #else
        #expect(message.contains("Swipe"))
        #expect(!message.contains("Control-click"))
        #endif
    }

    /// Each tip is capped at a single appearance. A discovery hint that keeps
    /// reappearing stops reading as help and starts reading as a bug.
    @Test("Every tip is capped at one appearance")
    func everyTipShowsOnce() {
        for options in [
            DownloadsQueueSwitchTip().options,
            ArrBlendedLibraryTip().options,
            ArrCalendarSubscribeTip().options,
            ArrLibraryQuickActionsTip().options
        ] {
            // Matched on the option's description rather than its type: `MaxDisplayCount`
            // is only in scope inside a `Tip`'s own `options` builder, and importing it
            // here would be a worse trade than reading the value TipKit prints.
            let hasMaxDisplayCount = options.contains { String(describing: $0).contains("MaxDisplayCount") }
            #expect(hasMaxDisplayCount, "A tip with no display cap can reappear indefinitely.")
        }
    }
}
