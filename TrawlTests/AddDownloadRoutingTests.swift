//
//  AddDownloadRoutingTests.swift
//  TrawlTests
//
//  One sheet adds downloads to two clients that have nothing in common, and it works
//  out which one to use by looking at what the user pasted. Every way that can go
//  wrong is quiet: an NZB link handed to qBittorrent is a failed add with a confusing
//  message, a magnet handed to SABnzbd is the same, and a stale file left behind by a
//  source switch is an add of something the user did not choose - to a client they did
//  not choose either.
//
//  `AddTorrentViewModel`'s routing is a pure function of what is typed and which
//  clients exist, so all of it is exercised here without a server. The services it
//  holds are real ones pointed at a closed port: nothing under test calls them, and a
//  stub with the right shape would only prove the stub.
//

import Foundation
import Testing
@testable import Trawl

@Suite("Add download routing")
@MainActor
struct AddDownloadRoutingTests {

    // MARK: - Which sources a setup can offer

    @Test("The sources on offer follow the clients that are set up")
    func availableSourcesFollowConfiguredClients() {
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)
        #expect(both.availableSources == [.magnet, .torrentFile, .nzbFile, .url])

        let torrentOnly = makeViewModel(qBittorrent: true, sabnzbd: false)
        #expect(torrentOnly.availableSources == [.magnet, .torrentFile, .url])

        let usenetOnly = makeViewModel(qBittorrent: false, sabnzbd: true)
        #expect(usenetOnly.availableSources == [.nzbFile, .url])

        let neither = makeViewModel(qBittorrent: false, sabnzbd: false)
        #expect(neither.availableSources.isEmpty)
        #expect(neither.hasAnyClient == false)
    }

    /// The sheet opens on `.magnet`. A SABnzbd-only user has no magnet source to land
    /// on, so the selection has to move by itself rather than presenting a field that
    /// can never be submitted.
    @Test("A source no client can serve moves to one that can, and takes its input with it")
    func sourceNormalizesToAnAvailableClient() {
        let usenetOnly = makeViewModel(qBittorrent: false, sabnzbd: true)
        usenetOnly.magnetLink = "magnet:?xt=urn:btih:abc"

        usenetOnly.normalizeSourceForAvailableClients()

        #expect(usenetOnly.source == .nzbFile)
        #expect(usenetOnly.magnetLink.isEmpty, "The magnet typed before the move must not survive it.")

        // A setup that can serve the current source is left alone.
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)
        both.magnetLink = "magnet:?xt=urn:btih:abc"
        both.normalizeSourceForAvailableClients()
        #expect(both.source == .magnet)
        #expect(both.magnetLink == "magnet:?xt=urn:btih:abc")

        // With nothing configured there is nowhere to move to, and the sheet says so
        // elsewhere rather than picking a source at random.
        let neither = makeViewModel(qBittorrent: false, sabnzbd: false)
        neither.normalizeSourceForAvailableClients()
        #expect(neither.source == .magnet)
    }

    // MARK: - Where an add goes

    @Test("A file or magnet goes to the client that handles it, or nowhere")
    func fileSourcesRouteToTheirOwnClient() {
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)
        both.source = .magnet
        #expect(both.destination == .qBittorrent)
        both.source = .torrentFile
        #expect(both.destination == .qBittorrent)
        both.source = .nzbFile
        #expect(both.destination == .sabnzbd)

        // The client for this kind of add is missing: no destination, rather than the
        // other client as a consolation prize.
        let usenetOnly = makeViewModel(qBittorrent: false, sabnzbd: true)
        usenetOnly.source = .magnet
        #expect(usenetOnly.destination == nil)

        let torrentOnly = makeViewModel(qBittorrent: true, sabnzbd: false)
        torrentOnly.source = .nzbFile
        #expect(torrentOnly.destination == nil)
    }

    /// Indexers hand out `.nzb.gz` as often as `.nzb`, and a magnet can arrive in the
    /// URL field as easily as in its own. The classifier is what keeps those adds off
    /// the wrong client.
    @Test("A pasted link is classified by what it looks like")
    func linkKindReadsTheLink() {
        #expect(AddTorrentViewModel.linkKind(for: "magnet:?xt=urn:btih:abc") == .magnet)
        #expect(AddTorrentViewModel.linkKind(for: "MAGNET:?xt=urn:btih:abc") == .magnet)
        #expect(AddTorrentViewModel.linkKind(for: "https://tracker.test/file.torrent") == .torrent)
        #expect(AddTorrentViewModel.linkKind(for: "https://indexer.test/get/123.nzb") == .nzb)
        #expect(AddTorrentViewModel.linkKind(for: "https://indexer.test/get/123.nzb.gz") == .nzb)
        #expect(AddTorrentViewModel.linkKind(for: "https://indexer.test/api?t=get&id=123") == .unknown)
        #expect(AddTorrentViewModel.linkKind(for: "   ") == .unknown)
        #expect(AddTorrentViewModel.linkKind(for: "  https://tracker.test/file.torrent  ") == .torrent)
    }

    @Test("A link that names its kind is routed by it, whatever the preference says")
    func recognisedLinksIgnoreThePreference() {
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)
        both.source = .url
        both.preferredURLDestination = .sabnzbd

        both.linkURL = "https://tracker.test/file.torrent"
        #expect(both.destination == .qBittorrent)
        #expect(both.needsURLDestinationChoice == false)

        both.linkURL = "magnet:?xt=urn:btih:abc"
        #expect(both.destination == .qBittorrent)

        both.preferredURLDestination = .qBittorrent
        both.linkURL = "https://indexer.test/get/123.nzb"
        #expect(both.destination == .sabnzbd)
    }

    /// The one case the app refuses to guess: an opaque link and two clients that
    /// could both take it.
    @Test("An opaque link asks where it should go, but only when both clients exist")
    func opaqueLinksAskOnlyWhenAmbiguous() {
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)
        both.source = .url
        both.linkURL = "https://indexer.test/api?t=get&id=123"

        #expect(both.needsURLDestinationChoice)
        both.preferredURLDestination = .sabnzbd
        #expect(both.destination == .sabnzbd)
        both.preferredURLDestination = .qBittorrent
        #expect(both.destination == .qBittorrent)

        // With one client there is nothing to ask about.
        let torrentOnly = makeViewModel(qBittorrent: true, sabnzbd: false)
        torrentOnly.source = .url
        torrentOnly.linkURL = "https://indexer.test/api?t=get&id=123"
        #expect(torrentOnly.needsURLDestinationChoice == false)
        #expect(torrentOnly.destination == .qBittorrent)

        let usenetOnly = makeViewModel(qBittorrent: false, sabnzbd: true)
        usenetOnly.source = .url
        usenetOnly.linkURL = "https://indexer.test/api?t=get&id=123"
        #expect(usenetOnly.needsURLDestinationChoice == false)
        #expect(usenetOnly.destination == .sabnzbd)
    }

    @Test("A link for a client that is not set up says which client is missing")
    func routingWarningNamesTheMissingClient() {
        let usenetOnly = makeViewModel(qBittorrent: false, sabnzbd: true)
        usenetOnly.source = .url
        usenetOnly.linkURL = "https://tracker.test/file.torrent"
        #expect(usenetOnly.routingWarning == "This looks like a torrent link, but qBittorrent isn't set up.")

        let torrentOnly = makeViewModel(qBittorrent: true, sabnzbd: false)
        torrentOnly.source = .url
        torrentOnly.linkURL = "https://indexer.test/get/123.nzb"
        #expect(torrentOnly.routingWarning == "This looks like an NZB link, but SABnzbd isn't set up.")

        let neither = makeViewModel(qBittorrent: false, sabnzbd: false)
        neither.source = .url
        neither.linkURL = "https://indexer.test/api?t=get&id=123"
        #expect(neither.routingWarning == "No download client is set up.")

        // Nothing typed yet is not a fault to warn about.
        neither.linkURL = "   "
        #expect(neither.routingWarning == nil)

        // A link that routes fine is silent.
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)
        both.source = .url
        both.linkURL = "https://tracker.test/file.torrent"
        #expect(both.routingWarning == nil)
    }

    // MARK: - When Add can be pressed

    @Test("Add stays disabled until this source has something to send, and while sending")
    func submissionIsGatedBySourceAndDestination() {
        let both = makeViewModel(qBittorrent: true, sabnzbd: true)

        both.source = .magnet
        #expect(both.canSubmit == false)
        both.magnetLink = "   "
        #expect(both.canSubmit == false, "Whitespace is not a magnet link.")
        both.magnetLink = "magnet:?xt=urn:btih:abc"
        #expect(both.canSubmit)

        both.isSubmitting = true
        #expect(both.canSubmit == false, "A second press while the first add is in flight would add it twice.")
        both.isSubmitting = false

        both.source = .torrentFile
        #expect(both.canSubmit == false)
        both.torrentFileData = Data("d8:announce".utf8)
        #expect(both.canSubmit)

        both.source = .nzbFile
        #expect(both.canSubmit == false)
        both.nzbFileData = Data("<?xml version=\"1.0\"?>".utf8)
        #expect(both.canSubmit)

        both.source = .url
        both.linkURL = "https://tracker.test/file.torrent"
        #expect(both.canSubmit)

        // Routable input, but no client to route it to.
        let usenetOnly = makeViewModel(qBittorrent: false, sabnzbd: true)
        usenetOnly.source = .url
        usenetOnly.linkURL = "https://tracker.test/file.torrent"
        #expect(usenetOnly.canSubmit == false)
    }

    /// The data-safety half of the sheet. Switching source has to drop what the other
    /// sources were holding, or a torrent file picked a minute ago rides along with an
    /// NZB add and lands on whichever client the *new* source routes to.
    @Test("Switching source drops every other source's input")
    func switchingSourceClearsTheRest() {
        let model = makeViewModel(qBittorrent: true, sabnzbd: true)
        model.magnetLink = "magnet:?xt=urn:btih:abc"
        model.linkURL = "https://indexer.test/get/123.nzb"
        model.torrentFileData = Data("torrent".utf8)
        model.torrentFileName = "Example.torrent"
        model.nzbFileData = Data("nzb".utf8)
        model.nzbFileName = "Example.nzb"

        model.source = .nzbFile
        model.clearInputOtherThanCurrentSource()

        #expect(model.nzbFileData != nil, "The current source keeps what it was given.")
        #expect(model.nzbFileName == "Example.nzb")
        #expect(model.magnetLink.isEmpty)
        #expect(model.linkURL.isEmpty)
        #expect(model.torrentFileData == nil)
        #expect(model.torrentFileName == nil)
    }

    // MARK: - Helpers

    /// Real services pointed at a closed loopback port. The routing under test never
    /// calls them; giving it the real types keeps the view model in the shape the app
    /// builds it in.
    private func makeViewModel(qBittorrent: Bool, sabnzbd: Bool) -> AddTorrentViewModel {
        let client = QBittorrentAPIClient(
            baseURL: "http://127.0.0.1:1",
            authService: AuthService(serverProfileID: UUID())
        )
        let model = AddTorrentViewModel(
            torrentService: TorrentService(apiClient: client),
            syncService: SyncService(apiClient: client),
            sabnzbdManager: nil
        )
        model.hasQBittorrent = qBittorrent
        model.hasSABnzbd = sabnzbd
        return model
    }
}
