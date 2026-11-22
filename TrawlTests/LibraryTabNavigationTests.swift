import Testing
import Foundation
@testable import Trawl

/// The routing behind the iPhone tab bar: Library in place of Series and Movies,
/// Calendar promoted, Downloads moved to the bar above the tabs.
@MainActor
struct LibraryTabNavigationTests {
    @Test func phoneTabsAreLibraryCalendarMoreAndSearch() {
        #expect(RootTab.compactTabs == [.library, .calendar, .more, .search])
        #expect(RootTab.startupChoices == [.library, .calendar, .more])
    }

    @Test func seriesAndMoviesBecomeLibraryScopes() {
        #expect(RootTab.compactTab(for: .series)?.tab == .library)
        #expect(RootTab.compactTab(for: .series)?.scope == .series)
        #expect(RootTab.compactTab(for: .movies)?.scope == .movies)
        #expect(RootTab.compactTab(for: .calendar)?.tab == .calendar)
        #expect(RootTab.compactTab(for: .calendar)?.scope == nil)
    }

    @Test func downloadsAndMoreScreensAreNotTabs() {
        #expect(RootTab.compactTab(for: .downloads) == nil)
        #expect(RootTab.compactTab(for: .health) == nil)
        #expect(RootTab.compactTab(for: .blocklist) == nil)
    }

    @Test func libraryOpensSeriesInTheSidebar() {
        #expect(RootTab.library.sidebarDestination == .series)
        #expect(RootTab.health.sidebarDestination == .health)
    }

    /// The sidebar has no More row. A startup tab of More on an unfolded Duo used to
    /// select it anyway and show the phone's More list beside the sidebar.
    @Test func moreIsNeverASidebarSelection() {
        #expect(!RootTab.sidebarDestinations.contains(.more))
        #expect(RootTab.more.sidebarDestination == .series)
        var scope = LibraryScope.all
        #expect(ContentView.startupSelection(stored: "More", isCompact: false, scope: &scope) == .series)
        #expect(ContentView.startupSelection(stored: "More", isCompact: true, scope: &scope) == .more)
        // Unfolding on a screen More had pushed keeps that screen.
        #expect(RootTab.sidebarDestination(forMoreRoot: .health) == .health)
        #expect(RootTab.sidebarDestination(forMoreRoot: .setupCheck) == .setupCheck)
        // Every compact startup choice lands on a row the sidebar actually lists.
        for tab in RootTab.startupChoices {
            #expect(RootTab.sidebarDestinations.contains(tab.sidebarDestination), "\(tab) has no sidebar row")
        }
    }

    @Test func storedStartupTabsMapToThePhoneTabs() {
        var scope = LibraryScope.all
        #expect(ContentView.startupSelection(stored: "Downloads", isCompact: true, scope: &scope) == .library)
        #expect(scope == .all)
        #expect(ContentView.startupSelection(stored: "Torrents", isCompact: true, scope: &scope) == .library)
        #expect(ContentView.startupSelection(stored: "Movies", isCompact: true, scope: &scope) == .library)
        #expect(scope == .movies)
        #expect(ContentView.startupSelection(stored: "Calendar", isCompact: true, scope: &scope) == .calendar)
        #expect(ContentView.startupSelection(stored: "Library", isCompact: false, scope: &scope) == .series)
        #expect(ContentView.startupSelection(stored: "Downloads", isCompact: false, scope: &scope) == .downloads)
    }

    /// Every host the widgets and the push worker send.
    @Test func deepLinkHostsResolve() {
        #expect(ContentView.deepLinkTarget(host: "downloads") == .downloads)
        #expect(ContentView.deepLinkTarget(host: "torrents") == .downloads)
        #expect(ContentView.deepLinkTarget(host: "calendar") == .calendar)
        #expect(ContentView.deepLinkTarget(host: "health") == .health)
        #expect(ContentView.deepLinkTarget(host: "seerr-issue") == .issues)
        #expect(ContentView.deepLinkTarget(host: "seerr-requests") == .requests)
        #expect(ContentView.deepLinkTarget(host: "nonsense") == nil)
    }

    @Test func moreListsTheSidebarSectionsWithoutTheTabs() {
        let rows = SidebarSection.allCases.flatMap(MoreView.moreRows(in:))
        #expect(!rows.contains(.calendar))
        #expect(!rows.contains(.search))
        #expect(!rows.contains(.series))
        #expect(!rows.contains(.movies))
        #expect(rows.contains(.downloads))
        #expect(rows.contains(.requests))
        #expect(rows.contains(.health))
        #expect(rows.contains(.settings))
    }

    @Test func countSummaryReadsMoviesFirstAndDropsEmptyKinds() {
        #expect(LibraryScope.countSummary(series: 3, movies: 37) == "37 movies, 3 series")
        #expect(LibraryScope.countSummary(series: 1, movies: 1) == "1 movie, 1 series")
        #expect(LibraryScope.countSummary(series: 2, movies: 0) == "2 series")
        #expect(LibraryScope.countSummary(series: 0, movies: 0) == "No titles")
    }

    @Test func libraryFiltersMapToBothServices() {
        for filter in LibraryAllFilter.allCases {
            #expect(filter.seriesFilter.rawValue == filter.rawValue)
            #expect(filter.moviesFilter.rawValue == filter.rawValue)
        }
        for sort in LibraryAllSort.allCases {
            #expect(sort.seriesSort.rawValue == sort.rawValue)
            #expect(sort.moviesSort.rawValue == sort.rawValue)
        }
    }
}

/// What the bar above the iPhone tabs says while something is downloading.
@MainActor
struct ActiveDownloadsSummaryTests {
    @Test func nothingDownloadingLeavesTheBarToNotifications() {
        #expect(ActiveDownloadsSummary.make(torrents: [], sabJobs: []) == nil)
        #expect(ActiveDownloadsSummary.make(torrents: [.previewSeeding], sabJobs: []) == nil)
    }

    @Test func namesTheDownloadNearestToDone() throws {
        let summary = try #require(ActiveDownloadsSummary.make(
            torrents: [.previewStalled, .previewDownloading, .previewSeeding],
            sabJobs: []
        ))
        #expect(summary.leadName == Torrent.previewDownloading.name)
        #expect(summary.count == 2)
        #expect(summary.detail == "42% · 1 more")
        #expect(summary.bytesPerSecond == Torrent.previewDownloading.dlspeed + Torrent.previewStalled.dlspeed)
    }

    @Test func aSingleDownloadShowsOnlyItsProgress() throws {
        let summary = try #require(ActiveDownloadsSummary.make(torrents: [.previewDownloading], sabJobs: []))
        #expect(summary.detail == "42%")
        #expect(summary.othersCount == 0)
    }
}
