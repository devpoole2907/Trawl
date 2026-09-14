import Foundation
import Testing
@testable import Trawl

/// The Naming editor's live preview, token search and token insertion. None of it
/// reaches the server directly, but all of it shapes the format a person confirms -
/// a preview that renders a token it does not support, or an insertion that glues
/// two tokens together, is how a wrong format gets saved on purpose.
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

    @Test("Tokens match regardless of case, as Sonarr's own parser does")
    func previewIsCaseInsensitive() {
        #expect(ArrNamingFormatPreview.preview(for: "{series titleyear}", groups: standardGroups) == "Example Show (2026)")
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

    // MARK: Token search

    @Test("Search matches a token's title, value or sample, ignoring case")
    func tokenSearchFields() {
        let token = ArrNamingToken(title: "Air-Date", value: "{Air-Date}", sample: "2026-05-17", systemImage: "calendar")
        #expect(token.matches("air"))
        #expect(token.matches("{AIR-DATE}"))
        #expect(token.matches("05-17"))
        #expect(!token.matches("episode"))
    }

    // MARK: Insertion

    @Test("A token becomes the whole format when the format is empty")
    func insertIntoEmptyFormat() {
        #expect(ArrNamingFormatInsertion.appending("{Series Title}", to: "") == "{Series Title}")
    }

    @Test("A token after a word or another token is separated by one space")
    func insertAfterTokenAddsSpace() {
        #expect(ArrNamingFormatInsertion.appending("{Series Year}", to: "{Series Title}") == "{Series Title} {Series Year}")
    }

    @Test("A token attaches directly after a separator instead of adding a space", arguments: [
        ("Season ", "Season {season:00}"),
        ("{Series CleanTitle}.", "{Series CleanTitle}.{season:00}"),
        ("{Series Title} -", "{Series Title} -{season:00}"),
        ("Specials_", "Specials_{season:00}"),
        ("{Series TitleYear}/", "{Series TitleYear}/{season:00}"),
        ("[", "[{season:00}"),
        ("(", "({season:00}")
    ])
    func insertAfterSeparator(format: String, expected: String) {
        #expect(ArrNamingFormatInsertion.appending("{season:00}", to: format) == expected)
    }
}
