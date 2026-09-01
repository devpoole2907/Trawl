import Testing
@testable import Trawl

@Suite("Arr library filter naming")
struct ArrLibraryFilterNamingTests {
    @Test("Radarr explains the narrower wanted state in plain language")
    func radarrWantedLabel() {
        #expect(RadarrFilter.wanted.rawValue == "Missing & Available")
    }
}
