import Foundation
import Testing
@testable import Trawl

/// The Naming preview. None of it reaches the server directly, but all of it shapes
/// the format a person confirms - a preview that renders a token it does not support
/// is how a wrong format gets saved on purpose.
@Suite("Naming format editing")
@MainActor
struct ArrNamingFormatTests {
    private let standardGroups = ArrNamingTokenCatalog.sonarrEpisodeGroups(includeDaily: false, includeAbsolute: false)
    private let dailyGroups = ArrNamingTokenCatalog.sonarrEpisodeGroups(includeDaily: true, includeAbsolute: false)

    // MARK: Preview

    @Test("An empty or blank format says so instead of rendering nothing")
    func blankFormatPreview() {
        #expect(ArrNamingFormatPreview.preview(for: "", groups: standardGroups) == "No format yet")
        #expect(ArrNamingFormatPreview.preview(for: "  \n", groups: standardGroups) == "No format yet")
    }

    @Test("A standard episode format renders every token with its sample")
    func standardFormatPreview() {
        let format = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full}"
        #expect(
            ArrNamingFormatPreview.preview(for: format, groups: standardGroups)
                == "Example Show (2026) - S02E03 - Pilot WEBDL-1080p Proper"
        )
    }

    @Test("A token's case sets the case of its value: a lowercase token writes a lowercase value")
    func previewIsCaseInsensitive() {
        // Upstream FileNameBuilder matches tokens ignoring case, then lowercases the value for an all-lowercase token.
        #expect(ArrNamingFormatPreview.preview(for: "{series titleyear}", groups: standardGroups) == "example show (2026)")
    }

    @Test("A token the catalog does not know is left visible rather than dropped")
    func unknownTokenStaysLiteral() {
        #expect(
            ArrNamingFormatPreview.preview(for: "{Series Title} {Not A Token}", groups: standardGroups)
                == "Example Show {Not A Token}"
        )
    }

    @Test("Daily tokens only render for formats whose catalog offers them")
    func dailyTokensAreScopedToTheirFormat() {
        let format = "{Series TitleYear} - {Air-Date}"
        #expect(ArrNamingFormatPreview.preview(for: format, groups: dailyGroups) == "Example Show (2026) - 2026-05-17")
        #expect(
            ArrNamingFormatPreview.preview(for: format, groups: standardGroups) == "Example Show (2026) - {Air-Date}",
            "The standard format has no air date; previewing one would promise a file name Sonarr will not produce."
        )
    }
}
