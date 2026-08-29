import Foundation
import Testing
@testable import Trawl

// Regression coverage for audit item M-04: share-extension provider failures
// could leave the sheet open indefinitely.
//
// The rules these tests exercise used to live inside `NSItemProvider` callbacks
// in `ShareViewController`, which compiles only into the extension targets and
// is therefore unreachable from `TrawlTests`. They now live in
// `Share/ShareInputResolution.swift`, a Foundation-only file that every target
// compiles - including the `Trawl` app that hosts this test bundle.

/// Stands in for the error an `NSItemProvider` hands back. `LocalizedError`
/// makes `localizedDescription` return `errorDescription`, which is exactly the
/// path the production resolver reads.
private nonisolated struct StubProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// All call sites pass compile-time literals, so a parse failure is a broken
/// test rather than a condition worth surfacing as an expectation.
private nonisolated func fixtureURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        fatalError("test fixture URL should parse: \(string)")
    }
    return url
}

// MARK: - URL provider

@Suite("Share input resolution - URL provider")
struct ShareURLProviderResolutionTests {

    /// Pre-fix: the URL branch bound the error to `_` and called `close()`, so
    /// the request ended but the provider's message was thrown away. The
    /// `.cancel(message:)` assertion below fails against that code.
    @Test("A provider error becomes a cancellation carrying the provider's own message")
    func providerErrorCarriesMessage() {
        let resolution = ShareInputResolver.resolveURL(
            loaded: nil,
            error: StubProviderError(message: "The item could not be loaded.")
        )

        #expect(resolution == .providerFailed(message: "The item could not be loaded."))
        #expect(resolution.termination == .cancel(message: "The item could not be loaded."))
    }

    /// Uses a real `NSError` rather than a Swift stub, because that is what
    /// `NSItemProvider` actually produces.
    @Test("An NSError from the provider carries its localized description through")
    func nsErrorCarriesLocalizedDescription() {
        let underlying = NSError(
            domain: "NSItemProviderErrorDomain",
            code: -1000,
            userInfo: [NSLocalizedDescriptionKey: "The item is unavailable."]
        )

        let resolution = ShareInputResolver.resolveURL(loaded: nil, error: underlying)

        #expect(resolution == .providerFailed(message: "The item is unavailable."))
        #expect(resolution.termination == .cancel(message: "The item is unavailable."))
    }

    /// Pre-fix this path did terminate (`close()`), so this test guards against a
    /// regression rather than reproducing the hang. The hang lived on the file
    /// and plain-text branches, covered below.
    @Test("Data where a URL was promised is not usable, and completes")
    func dataInsteadOfURLCompletes() {
        let resolution = ShareInputResolver.resolveURL(
            loaded: Data("not a url".utf8),
            error: nil
        )

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    @Test("A magnet URL resolves to a magnet link and does not terminate")
    func magnetURLResolves() {
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example"
        let resolution = ShareInputResolver.resolveURL(loaded: fixtureURL(magnet), error: nil)

        #expect(resolution == .magnetLink(magnet))
        #expect(resolution.termination == nil)
    }

    @Test("A magnet URL arriving as a bridged NSURL still resolves")
    func bridgedNSURLResolves() throws {
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        let bridged = try #require(NSURL(string: magnet))

        let resolution = ShareInputResolver.resolveURL(loaded: bridged, error: nil)

        #expect(resolution == .magnetLink(magnet))
    }

    @Test("An uppercase magnet scheme still resolves, preserving the original text")
    func uppercaseMagnetSchemeResolves() {
        let magnet = "MAGNET:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567"
        let resolution = ShareInputResolver.resolveURL(loaded: fixtureURL(magnet), error: nil)

        #expect(resolution == .magnetLink(magnet))
    }

    @Test("An https link whose path ends in .nzb resolves to an NZB link")
    func httpsNZBLinkResolves() {
        let link = "https://indexer.example/getnzb/Example.Release.nzb?apikey=secret"
        let resolution = ShareInputResolver.resolveURL(loaded: fixtureURL(link), error: nil)

        #expect(resolution == .nzbLink(link))
        #expect(resolution.termination == nil)
    }

    /// The `.nzb` has to be in the path. An indexer link that only mentions one
    /// in its query string is an ordinary web link, and completing quietly is
    /// the honest outcome - pinning it so the path rule cannot loosen silently.
    @Test("An https link with .nzb only in its query string is not an NZB link")
    func nzbInQueryStringOnlyCompletes() {
        let link = "https://indexer.example/api?t=get&id=99/Example.Release.nzb"
        let resolution = ShareInputResolver.resolveURL(loaded: fixtureURL(link), error: nil)

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    @Test("An http link ending in .nzb.gz resolves to an NZB link")
    func httpGzippedNZBLinkResolves() {
        let link = "http://indexer.example/get/Example.Release.nzb.gz"
        let resolution = ShareInputResolver.resolveURL(loaded: fixtureURL(link), error: nil)

        #expect(resolution == .nzbLink(link))
    }

    @Test("An .nzb link on a non-http scheme is not usable, and completes")
    func nonHTTPNZBLinkCompletes() {
        let resolution = ShareInputResolver.resolveURL(
            loaded: fixtureURL("ftp://indexer.example/get/Example.Release.nzb"),
            error: nil
        )

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    @Test("An ordinary shared web link is not treated as a torrent")
    func ordinaryWebLinkCompletes() {
        let resolution = ShareInputResolver.resolveURL(
            loaded: fixtureURL("https://example.com/some/article"),
            error: nil
        )

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }
}

// MARK: - File providers

@Suite("Share input resolution - file providers")
struct ShareFileProviderResolutionTests {

    /// M-04 scenario 1. Pre-fix the NZB branch was
    /// `guard let url = item as? URL else { return }` - a bare `return` that
    /// never called `close()`, so the share sheet stayed on screen forever.
    /// Every assertion here fails against that code: there was no resolution
    /// value at all, and nothing terminated.
    @Test("An NZB provider that errors cancels with the provider's message")
    func nzbProviderErrorCarriesMessage() {
        let resolution = ShareInputResolver.resolveNZBFile(
            loaded: nil,
            error: StubProviderError(message: "NZB attachment failed to load.")
        )

        #expect(resolution == .providerFailed(message: "NZB attachment failed to load."))
        #expect(resolution.termination == .cancel(message: "NZB attachment failed to load."))
    }

    /// M-04 scenario 2. Pre-fix: same bare `return`, so a host handing back raw
    /// `Data` instead of a file URL stranded the sheet.
    @Test("An NZB provider handing back Data instead of a URL completes")
    func nzbProviderDataInsteadOfURLCompletes() {
        let resolution = ShareInputResolver.resolveNZBFile(
            loaded: Data("<nzb xmlns=\"http://www.newzbin.com/DTD/2003/nzb\"/>".utf8),
            error: nil
        )

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    /// Pre-fix: the torrent branch had the identical bare `return`.
    @Test("A torrent provider that errors cancels with the provider's message")
    func torrentProviderErrorCarriesMessage() {
        let resolution = ShareInputResolver.resolveTorrentFile(
            loaded: nil,
            error: StubProviderError(message: "Torrent attachment failed to load.")
        )

        #expect(resolution == .providerFailed(message: "Torrent attachment failed to load."))
        #expect(resolution.termination == .cancel(message: "Torrent attachment failed to load."))
    }

    /// Pre-fix: bare `return` - hang.
    @Test("A torrent provider handing back Data instead of a URL completes")
    func torrentProviderDataInsteadOfURLCompletes() {
        let resolution = ShareInputResolver.resolveTorrentFile(
            loaded: Data([0x64, 0x38, 0x3A]),
            error: nil
        )

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    @Test("An NZB file URL is carried forward for reading, tagged with the NZB branch")
    func nzbFileURLIsCarriedForward() {
        let fileURL = fixtureURL("file:///tmp/Example.Release.nzb")
        let resolution = ShareInputResolver.resolveNZBFile(loaded: fileURL, error: nil)

        #expect(resolution == .fileToRead(fileURL, branch: .nzb))
        #expect(resolution.termination == nil)
    }

    @Test("A torrent file URL is carried forward for reading, tagged with the torrent branch")
    func torrentFileURLIsCarriedForward() {
        let fileURL = fixtureURL("file:///tmp/Example.Release.torrent")
        let resolution = ShareInputResolver.resolveTorrentFile(loaded: fileURL, error: nil)

        #expect(resolution == .fileToRead(fileURL, branch: .torrent))
        #expect(resolution.termination == nil)
    }
}

// MARK: - Plain text

@Suite("Share input resolution - plain text")
struct SharePlainTextResolutionTests {

    /// M-04 scenario 3. Pre-fix the plain-text branch was a bare `if` with no
    /// `else` at all: non-magnet text did literally nothing and the sheet hung.
    @Test("Text that is not a magnet link completes rather than hanging")
    func nonMagnetTextCompletes() {
        let resolution = ShareInputResolver.resolvePlainText(
            loaded: "Have a look at this release when you get a chance",
            error: nil
        )

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    @Test("Empty text completes rather than hanging")
    func emptyTextCompletes() {
        let resolution = ShareInputResolver.resolvePlainText(loaded: "", error: nil)

        #expect(resolution == .nothingUsable)
        #expect(resolution.termination == .complete)
    }

    /// Pre-fix: the error was bound to `_` and the `if` failed, so nothing ran.
    @Test("A plain-text provider error cancels with the provider's message")
    func providerErrorCarriesMessage() {
        let resolution = ShareInputResolver.resolvePlainText(
            loaded: nil,
            error: StubProviderError(message: "Text attachment failed to load.")
        )

        #expect(resolution == .providerFailed(message: "Text attachment failed to load."))
        #expect(resolution.termination == .cancel(message: "Text attachment failed to load."))
    }

    /// M-04 scenario 4 - the happy path, which passed before the fix and must
    /// keep passing after it.
    @Test("A pasted magnet link resolves and does not terminate")
    func magnetTextResolves() {
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example"
        let resolution = ShareInputResolver.resolvePlainText(loaded: magnet, error: nil)

        #expect(resolution == .magnetLink(magnet))
        #expect(resolution.termination == nil)
    }

    @Test("An uppercase magnet prefix resolves, preserving the original text")
    func uppercaseMagnetTextResolves() {
        let magnet = "MAGNET:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567"
        let resolution = ShareInputResolver.resolvePlainText(loaded: magnet, error: nil)

        #expect(resolution == .magnetLink(magnet))
    }

    @Test("A shared web link arriving as text is not mistaken for a magnet")
    func webLinkTextCompletes() {
        let resolution = ShareInputResolver.resolvePlainText(
            loaded: "https://example.com/magnet-guide",
            error: nil
        )

        #expect(resolution == .nothingUsable)
    }
}

// MARK: - Filename rules

@Suite("Share input file classification")
struct ShareFileClassificationTests {

    @Test(
        "NZB filenames are recognised case-insensitively, gzipped or not",
        arguments: [
            ("Example.Release.nzb", true),
            ("EXAMPLE.RELEASE.NZB", true),
            ("Example.Release.nzb.gz", true),
            ("EXAMPLE.RELEASE.NZB.GZ", true),
            ("Example.Release.torrent", false),
            ("Example.Release.nzb.zip", false),
            ("nzb", false),
            ("", false)
        ]
    )
    func isNZBFileName(_ fileName: String, expected: Bool) {
        #expect(ShareInputResolver.isNZBFileName(fileName) == expected)
    }

    @Test("The NZB branch accepts an NZB-named file")
    func nzbBranchAcceptsNZBName() {
        #expect(ShareInputResolver.classify(fileName: "Example.nzb", advertisedAs: .nzb) == .nzb)
        #expect(ShareInputResolver.classify(fileName: "Example.nzb.gz", advertisedAs: .nzb) == .nzb)
    }

    /// The NZB branch asked for a specific type, so anything else is a dead end
    /// - and a dead end has to complete the request, not fall through.
    @Test("The NZB branch rejects a file that is not named like an NZB")
    func nzbBranchRejectsOtherNames() {
        #expect(ShareInputResolver.classify(fileName: "Example.torrent", advertisedAs: .nzb) == .unusable)
        #expect(ShareInputResolver.classify(fileName: "Example.xml", advertisedAs: .nzb) == .unusable)
    }

    /// The torrent branch's UTType falls back to `.data`, so hosts that describe
    /// an NZB only as generic data land here. The filename settles it.
    @Test("The torrent branch still recognises an NZB by filename")
    func torrentBranchRecognisesNZB() {
        #expect(ShareInputResolver.classify(fileName: "Example.nzb", advertisedAs: .torrent) == .nzb)
        #expect(ShareInputResolver.classify(fileName: "Example.nzb.gz", advertisedAs: .torrent) == .nzb)
    }

    @Test("The torrent branch treats anything else as a torrent")
    func torrentBranchTreatsOtherNamesAsTorrent() {
        #expect(ShareInputResolver.classify(fileName: "Example.torrent", advertisedAs: .torrent) == .torrent)
    }
}

// MARK: - Termination gate

@Suite("Share extension termination gate")
struct ShareTerminationGateTests {

    /// Drives a sequence of claims and reports every termination that would
    /// actually have been performed on the extension context.
    private func performed(_ claims: [ShareTermination]) -> [ShareTermination] {
        var gate = ShareTerminationGate()
        return claims.compactMap { gate.claim($0) }
    }

    @Test("A fresh gate has not finished; claiming once flips it")
    func gateStartsUnclaimed() {
        var gate = ShareTerminationGate()
        #expect(gate.hasFinished == false)

        // `claim` is mutating, and the `#expect` macro rewrites its receiver as
        // immutable, so every claim is taken into a local first.
        let firstClaim = gate.claim(.complete)

        #expect(firstClaim == .complete)
        #expect(gate.hasFinished == true)
    }

    @Test("The first claim yields the termination and every later claim yields nothing")
    func onlyTheFirstClaimYields() {
        var gate = ShareTerminationGate()

        let firstClaim = gate.claim(.complete)
        let secondClaim = gate.claim(.complete)
        let thirdClaim = gate.claim(.cancel(message: "later"))
        let fourthClaim = gate.claim(.complete)

        #expect(firstClaim == .complete)
        #expect(secondClaim == nil)
        #expect(thirdClaim == nil)
        #expect(fourthClaim == nil)
    }

    /// M-04 scenario 5. `NSItemProvider` makes no promise that a completion
    /// handler runs once. Pre-fix, `close()` had no guard, so a provider firing
    /// twice called `completeRequest` twice - a UIKit programmer error. The
    /// `count == 1` assertion fails against that code.
    @Test("A provider that fires its completion handler twice terminates exactly once")
    func providerFiringTwiceTerminatesOnce() {
        let terminations = performed([.complete, .complete])

        #expect(terminations.count == 1)
        #expect(terminations == [.complete])
    }

    /// The same guard covers two providers on one extension item both resolving.
    /// The first decision wins, message and all; the second is dropped.
    @Test("Two providers both resolving terminate exactly once, and the first wins")
    func twoProvidersTerminateOnce() {
        let terminations = performed([
            .cancel(message: "Attachment failed to load."),
            .complete
        ])

        #expect(terminations.count == 1)
        #expect(terminations == [.cancel(message: "Attachment failed to load.")])
    }

    @Test("A cancellation keeps its message intact through the gate")
    func cancelMessageSurvivesTheGate() throws {
        var gate = ShareTerminationGate()

        let result = gate.claim(.cancel(message: "The item is unavailable."))
        let claimed = try #require(result)

        #expect(claimed == .cancel(message: "The item is unavailable."))
    }

    @Test("A late success cannot re-open a request that already cancelled")
    func lateSuccessCannotReopen() {
        let terminations = performed([
            .cancel(message: "Attachment failed to load."),
            .complete,
            .complete,
            .cancel(message: "something else")
        ])

        #expect(terminations.count == 1)
    }
}

// MARK: - End-to-end sweep

@Suite("Every share-extension provider outcome terminates exactly once")
struct ShareInputTerminationSweepTests {

    private enum Branch {
        case url, nzbFile, torrentFile, plainText
    }

    private struct Case {
        let name: String
        let branch: Branch
        let loaded: Any?
        let error: (any Error)?
        /// `nil` means the flow legitimately carries on (present the sheet, or
        /// read a file) rather than ending the request here.
        let expected: ShareTermination?
    }

    private func resolve(_ testCase: Case) -> ShareInputResolution {
        switch testCase.branch {
        case .url:
            return ShareInputResolver.resolveURL(loaded: testCase.loaded, error: testCase.error)
        case .nzbFile:
            return ShareInputResolver.resolveNZBFile(loaded: testCase.loaded, error: testCase.error)
        case .torrentFile:
            return ShareInputResolver.resolveTorrentFile(loaded: testCase.loaded, error: testCase.error)
        case .plainText:
            return ShareInputResolver.resolvePlainText(loaded: testCase.loaded, error: testCase.error)
        }
    }

    /// Walks every shape a provider callback can take through the real
    /// resolvers and the real gate, and asserts each one lands on exactly one
    /// terminal decision - or is explicitly a carry-on case.
    ///
    /// Against the pre-fix code, six of these produced no termination at all
    /// (both file branches × error and × `Data`, plus plain text × non-magnet
    /// and × error), so the `count == 1` assertion fails six times over.
    @Test("Each provider outcome produces exactly one termination, or carries the flow on")
    func everyOutcomeTerminatesOnce() {
        let failure = StubProviderError(message: "Attachment failed to load.")
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        let nzbLink = fixtureURL("https://indexer.example/get/Example.nzb")
        let fileURL = fixtureURL("file:///tmp/Example.torrent")
        let webLink = fixtureURL("https://example.com/article")

        let cases: [Case] = [
            Case(name: "URL provider error", branch: .url, loaded: nil, error: failure,
                 expected: .cancel(message: failure.message)),
            Case(name: "URL provider returns Data", branch: .url, loaded: Data("x".utf8), error: nil,
                 expected: .complete),
            Case(name: "URL provider returns a non-magnet web link", branch: .url, loaded: webLink, error: nil,
                 expected: .complete),
            Case(name: "URL provider returns a magnet", branch: .url, loaded: fixtureURL(magnet), error: nil,
                 expected: nil),
            Case(name: "URL provider returns an NZB link", branch: .url, loaded: nzbLink, error: nil,
                 expected: nil),

            Case(name: "NZB provider error", branch: .nzbFile, loaded: nil, error: failure,
                 expected: .cancel(message: failure.message)),
            Case(name: "NZB provider returns Data", branch: .nzbFile, loaded: Data("x".utf8), error: nil,
                 expected: .complete),
            Case(name: "NZB provider returns a file URL", branch: .nzbFile, loaded: fileURL, error: nil,
                 expected: nil),

            Case(name: "Torrent provider error", branch: .torrentFile, loaded: nil, error: failure,
                 expected: .cancel(message: failure.message)),
            Case(name: "Torrent provider returns Data", branch: .torrentFile, loaded: Data("x".utf8), error: nil,
                 expected: .complete),
            Case(name: "Torrent provider returns a file URL", branch: .torrentFile, loaded: fileURL, error: nil,
                 expected: nil),

            Case(name: "Text provider error", branch: .plainText, loaded: nil, error: failure,
                 expected: .cancel(message: failure.message)),
            Case(name: "Text provider returns non-magnet text", branch: .plainText, loaded: "hello", error: nil,
                 expected: .complete),
            Case(name: "Text provider returns nothing at all", branch: .plainText, loaded: nil, error: nil,
                 expected: .complete),
            Case(name: "Text provider returns a magnet", branch: .plainText, loaded: magnet, error: nil,
                 expected: nil)
        ]

        for testCase in cases {
            var gate = ShareTerminationGate()
            let resolution = resolve(testCase)

            // Mirrors the view controller: perform the termination if there is
            // one, otherwise the resolution carries the flow forward.
            var performed: [ShareTermination] = []
            if let termination = resolution.termination, let claimed = gate.claim(termination) {
                performed.append(claimed)
            }

            if let expected = testCase.expected {
                #expect(performed.count == 1, "\(testCase.name) should terminate exactly once")
                #expect(performed.first == expected, "\(testCase.name) terminated the wrong way")
            } else {
                #expect(performed.isEmpty, "\(testCase.name) should carry the flow on, not terminate")
                #expect(gate.hasFinished == false, "\(testCase.name) should leave the gate unclaimed")
            }
        }
    }
}
