import Testing
@testable import Trawl

@Suite("More navigation guidance")
@MainActor
struct MoreNavigationGuidanceTests {
    @Test("Import search results land on their own sidebar rows rather than Root Folders")
    func manualImportSidebarOwner() {
        #expect(RootTab.owningSidebarDestination(for: .manualImport, category: "Library Management") == .manualImport)
        #expect(RootTab.owningSidebarDestination(for: .libraryImport, category: "Library Management") == .libraryImport)
        #expect(RootTab.owningSidebarDestination(for: .rootFolders, category: "Library Management") == .rootFolders)
    }

    /// Manual Import was reachable on iPad and Mac only through search, while its
    /// sibling Library Import had a row. Pinned as a row of its own, directly below
    /// Library Import, opening its own screen rather than Library Import's.
    @Test("Manual Import is a Management sidebar row directly below Library Import")
    func manualImportSidebarRow() throws {
        let rows = SidebarSection.management.rows
        let library = try #require(rows.firstIndex(of: .libraryImport))
        #expect(rows.firstIndex(of: .manualImport) == library + 1)
        #expect(SidebarSection.allCases.flatMap(\.rows).filter { $0 == .manualImport }.count == 1)

        #expect(RootTab.manualImport.moreRoot == .manualImport)
        #expect(RootTab.manualImport.moreRoot != RootTab.libraryImport.moreRoot)
        #expect(RootTab.manualImport.displayName == "Manual Import")
        #expect(RootTab.manualImport.navigationIdentifier == "nav.manualImport")
        #expect(RootTab.manualImport.systemImage != RootTab.libraryImport.systemImage)
        #expect(RootTab.manualImport.isSidebarOnly)
        #expect(!RootTab.startupChoices.contains(.manualImport))
    }

    /// Every sidebar row must own a distinct screen, or search's exact match picks
    /// whichever row `allCases` lists first and the other can never be reached.
    @Test("Every sidebar row roots a distinct screen")
    func sidebarRowsRootDistinctScreens() {
        let roots = SidebarSection.allCases.flatMap(\.rows).compactMap(\.moreRoot)
        #expect(Set(roots).count == roots.count)
    }

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
