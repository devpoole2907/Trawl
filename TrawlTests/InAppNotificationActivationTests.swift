import Testing
@testable import Trawl

/// What happens when a user taps an in-app notification.
///
/// Trawl presents banners two ways — the Dynamic Island toast on devices that have
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
