import Testing
@testable import Trawl

@Suite("Arr library filter naming")
struct ArrLibraryFilterNamingTests {
    @Test("Radarr explains the narrower wanted state in plain language")
    func radarrWantedLabel() {
        #expect(RadarrFilter.wanted.rawValue == "Released & Missing")
    }

    @Test("Bazarr does not expose wanted jargon")
    func bazarrWantedActionLabel() {
        #expect(BazarrSeriesAction.searchWanted.displayName == "Search Missing Subtitles")
    }
}
