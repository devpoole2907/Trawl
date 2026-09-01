import Testing
@testable import Trawl

@Suite("More navigation guidance")
@MainActor
struct MoreNavigationGuidanceTests {
    @Test("SABnzbd guidance follows its canonical More destination")
    func sabnzbdSettingsPath() {
        #expect(MoreDestination.sabnzbdSettings.userFacingPath == "More → Settings → SABnzbd")
    }
}
