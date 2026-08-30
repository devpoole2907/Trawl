import Testing
@testable import Trawl

/// What happens when a user taps an in-app notification.
///
/// Trawl presents banners two ways - the Dynamic Island toast on devices that have
/// one, and the legacy top banner everywhere else. Both must navigate identically:
/// a banner carrying an action performs it, and a banner without one opens the
/// notification history. The two presentations previously each held their own copy
/// of that decision, so they could drift; both now route through
/// `activateCurrentBanner()`, and these tests pin its behaviour.
@Suite("In-app notification activation", .serialized)
@MainActor
struct InAppNotificationActivationTests {
    @Test("Tapping a banner with an action performs it and clears the banner")
    func actionBannerNavigates() async {
        let center = InAppNotificationCenter()
        var performedCount = 0

        center.showSuccess(
            title: "Download Complete",
            message: "Ubuntu 26.04 finished.",
            action: InAppBannerAction(label: "View") { performedCount += 1 }
        )
        #expect(center.currentBanner != nil)
        #expect(center.currentBannerHasAction)

        center.activateCurrentBanner()

        #expect(performedCount == 1, "Tapping an actionable banner must navigate")
        #expect(center.currentBanner == nil, "The banner must be dismissed by the tap")
        #expect(
            center.isPresentingRecentNotifications == false,
            "An actionable banner navigates to its destination, not to the history sheet"
        )
    }

    @Test("Tapping a banner with no action opens the notification history")
    func plainBannerOpensHistory() async {
        let center = InAppNotificationCenter()

        center.showSuccess(title: "File Deleted", message: "Episode file removed.")
        #expect(center.currentBanner != nil)
        #expect(center.currentBannerHasAction == false)

        center.activateCurrentBanner()

        #expect(
            center.isPresentingRecentNotifications,
            "A banner with nowhere specific to go must open the history sheet"
        )
        #expect(center.currentBanner == nil)
    }

    @Test("Tapping when no banner is showing does nothing")
    func noBannerIsInert() async {
        let center = InAppNotificationCenter()

        center.activateCurrentBanner()

        #expect(center.isPresentingRecentNotifications == false)
        #expect(center.currentBanner == nil)
    }

    @Test("The action runs after the banner is torn down, not before")
    func actionSeesADismissedBanner() async {
        let center = InAppNotificationCenter()
        var bannerDuringHandler: InAppBannerItem?

        center.showSuccess(
            title: "Import Finished",
            message: "3 files added.",
            action: InAppBannerAction(label: "Show") { [weak center] in
                bannerDuringHandler = center?.currentBanner
            }
        )

        center.activateCurrentBanner()

        // Navigation frequently presents a sheet. If the banner were still live at
        // that moment it would sit above the destination it just opened.
        #expect(bannerDuringHandler == nil)
    }
}

// MARK: - Banner coalescing

/// Ten movies finishing an import produced ten banners, each replacing the last, so
/// the user watched a slot machine and could read none of them. A run of the same
/// event within a short window is now one banner with a count.
@Suite("In-app notification coalescing")
@MainActor
struct InAppNotificationCoalescingTests {

    private func center() -> InAppNotificationCenter {
        let center = InAppNotificationCenter()
        center.dismissCurrentBanner()
        return center
    }

    @Test("A burst of the same success becomes one banner with a count")
    func burstCollapsesIntoOneBanner() {
        let center = center()
        center.showSuccess(title: "Import Complete", message: "Us (2019)")
        for index in 2...10 {
            center.showSuccess(title: "Import Complete", message: "Movie \(index)")
        }

        let banner = center.currentBanner
        #expect(banner?.coalescedCount == 10)
        #expect(banner?.title == "Import Complete")
        #expect(banner?.message == "Us (2019) and 9 others")
        #expect(center.queuedBannerCountForTesting == 0, "A run must not leave nine more banners waiting to be shown.")
    }

    /// The summary is rebuilt from the first message each time, not from the previous
    /// summary - otherwise it reads "Us and 2 others and 3 others".
    @Test("Folding in more events does not compound the summary text")
    func summaryDoesNotCompound() {
        let center = center()
        center.showSuccess(title: "Import Complete", message: "Us (2019)")
        center.showSuccess(title: "Import Complete", message: "Heat (1995)")
        #expect(center.currentBanner?.message == "Us (2019) and 1 other")

        center.showSuccess(title: "Import Complete", message: "Alien (1979)")
        #expect(center.currentBanner?.message == "Us (2019) and 2 others")
    }

    @Test("Different events stay separate")
    func differentTitlesDoNotMerge() {
        let center = center()
        center.showSuccess(title: "Import Complete", message: "Us (2019)")
        center.showSuccess(title: "Download Complete", message: "Heat (1995)")

        #expect(center.currentBanner?.coalescedCount == 1)
        #expect(center.queuedBannerCountForTesting == 1, "A different event is a second banner, not a bigger count.")
    }

    /// Style is part of the grouping: a failure in the middle of a run of successes
    /// is the one the user most needs to see, so it must not be absorbed.
    @Test("An error is never folded into a run of successes")
    func errorsDoNotMergeIntoSuccesses() {
        let center = center()
        center.showSuccess(title: "Import Complete", message: "Us (2019)")
        center.showError(title: "Import Complete", message: "Heat (1995) failed")

        #expect(center.currentBanner?.coalescedCount == 1)
        #expect(center.queuedBannerCountForTesting == 1)
    }

    @Test("A single notification is untouched")
    func singleNotificationIsNotSummarised() {
        let center = center()
        center.showSuccess(title: "Import Complete", message: "Us (2019)")

        #expect(center.currentBanner?.coalescedCount == 1)
        #expect(center.currentBanner?.message == "Us (2019)")
    }

    /// Coalescing is a presentation decision. The history is an audit trail, so every
    /// event stays in it individually even when one banner spoke for all of them.
    @Test("Every event is still recorded in history")
    func historyKeepsEveryEvent() {
        let center = center()
        let before = center.recentNotifications.count
        for index in 1...10 {
            center.showSuccess(title: "Import Complete", message: "Movie \(index)")
        }

        #expect(center.recentNotifications.count == before + 10)
    }
}
