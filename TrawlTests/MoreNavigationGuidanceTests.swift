import Testing
@testable import Trawl

@Suite("More navigation guidance")
@MainActor
struct MoreNavigationGuidanceTests {
    @Test("SABnzbd guidance names the destination, not the container it sits in")
    func sabnzbdSettingsPath() {
        #expect(MoreDestination.sabnzbdSettings.userFacingPath == "Settings → SABnzbd")
    }

    /// The prefix is the point of this test. These strings are read by someone who is
    /// looking at the screen, and "More" is not on every screen: the iPad sidebar
    /// promotes Settings to a top-level destination and drops More entirely. A
    /// breadcrumb that starts there is wrong for those users, so it starts at the
    /// destination instead - which is true in the sidebar, in the iPad tab bar, and
    /// on iPhone alike.
    @Test("Guidance never sends anyone to a More that may not exist")
    func guidanceDoesNotAssumeMore() {
        let paths = [
            MoreDestination.settings,
            MoreDestination.sabnzbdSettings,
            MoreDestination.health,
            MoreDestination.systemHub
        ].map(\.userFacingPath)

        for path in paths {
            #expect(!path.contains("More"), "\(path) names More, which the iPad sidebar does not show.")
        }
    }
}
