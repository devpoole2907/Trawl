import CoreGraphics
import Foundation
import Testing
@testable import Trawl

/// Shared, deterministic inputs for the naming block builder's model tests. Formats are
/// the servers' own defaults, the app's presets, or deliberately awkward custom strings;
/// every arrangement is produced by parsing them through the real field catalog.
@MainActor
private enum NamingBlockFixtures {
    /// Sonarr's upstream standard episode default, which mixes ` - ` and ` ` joins.
    static let standardDefault = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}"

    static let allTargets: [ArrNamingFormatEditorTarget] = [
        .sonarr(.standardEpisode), .sonarr(.dailyEpisode), .sonarr(.animeEpisode),
        .sonarr(.seriesFolder), .sonarr(.seasonFolder), .sonarr(.specialsFolder),
        .radarr(.standardMovie), .radarr(.movieFolder)
    ]

    static func target(_ id: String) -> ArrNamingFormatEditorTarget {
        guard let target = allTargets.first(where: { $0.id == id }) else {
            preconditionFailure("No naming target \(id)")
        }
        return target
    }

    static func session(_ target: ArrNamingFormatEditorTarget = .sonarr(.standardEpisode), format: String) -> ArrNamingEditorSession {
        ArrNamingEditorSession(
            scope: ArrNamingEditorScope(instanceID: UUID(), target: target),
            serverName: target.serviceType == .radarr ? "Radarr" : "Sonarr",
            serverFormat: format
        )
    }

    static func parse(_ format: String, _ targetID: String = "sonarr-standardEpisode") -> ArrNamingArrangement {
        ArrNamingArrangement.parse(format, catalog: ArrNamingBlockCatalog(target: target(targetID)))
    }
}

/// Every value `perform` was handed, in order.
@MainActor
private final class SubmissionRecorder {
    private(set) var submissions: [String] = []

    func record(_ submitted: String) {
        submissions.append(submitted)
    }
}

/// Holds a save inside `perform` until the test releases it: an explicit barrier, so
/// "a save is in flight" is a fact the test waits for rather than a timing guess.
@MainActor
private final class SaveBarrier {
    private(set) var submissions: [String] = []
    private var release: CheckedContinuation<String?, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func perform(_ submitted: String) async -> String? {
        submissions.append(submitted)
        return await withCheckedContinuation { continuation in
            release = continuation
            arrivals.forEach { $0.resume() }
            arrivals.removeAll()
        }
    }

    func waitForSubmission() async {
        guard release == nil else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func resume(returning accepted: String?) {
        release?.resume(returning: accepted)
        release = nil
    }
}

// MARK: - Syntax

/// The lossless layer everything else stands on: an untouched server format must come
/// back character for character, and friendly grouping must never respell syntax.
@Suite("Naming syntax round trip")
@MainActor
struct ArrNamingSyntaxRoundTripTests {
    @Test("Every preset of every Sonarr and Radarr field serializes back exactly")
    func presetsRoundTrip() {
        var checked = 0
        for target in NamingBlockFixtures.allTargets {
            let catalog = ArrNamingBlockCatalog(target: target)
            for preset in target.presets {
                #expect(
                    ArrNamingArrangement.parse(preset.format, catalog: catalog).serialized == preset.format,
                    "\(target.id) preset \(preset.title)"
                )
                checked += 1
            }
        }
        #expect(checked >= NamingBlockFixtures.allTargets.count, "Every field offers at least one preset to check.")
    }

    @Test("Server defaults and difficult custom formats serialize back exactly", arguments: [
        // Upstream defaults.
        ("sonarr-standardEpisode", "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}"),
        ("sonarr-dailyEpisode", "{Series Title} - {Air-Date} - {Episode Title} {Quality Full}"),
        ("sonarr-seasonFolder", "Season {season}"),
        ("sonarr-specialsFolder", "Specials"),
        ("radarr-standardMovie", "{Movie Title} ({Release Year}) {Quality Full}"),
        ("radarr-movieFolder", "{Movie Title} ({Release Year})"),
        // Mixed separators and a re-separated token.
        ("sonarr-standardEpisode", "{Series.CleanTitle}.S{season:00}E{episode:00}_{Episode CleanTitle} - {Quality Full}"),
        // Optional release-group punctuation and brackets.
        ("sonarr-standardEpisode", "{Quality Full}{-Release Group}"),
        ("sonarr-standardEpisode", "[{Quality Full}]"),
        // Repeated tokens are valid on the server and must survive.
        ("sonarr-standardEpisode", "{Series Title} - {Series Title} {Quality Full} {Quality Full}"),
        // Unknown tokens.
        ("sonarr-standardEpisode", "{Series CleanTitleYear} {Fancy Token}"),
        // Sonarr brace escapes and Radarr nested tags.
        ("sonarr-standardEpisode", "{{literal}} {Series Title}"),
        ("radarr-standardMovie", "{Movie Title} {imdb-{ImdbId}} {edition-{Edition Tags}}"),
        // Folder paths.
        ("sonarr-seriesFolder", "{Series TitleFirstCharacter}/{Series TitleYear}"),
        // Leading and trailing whitespace, doubled joins and odd casing.
        ("sonarr-standardEpisode", "  {series title}  -  S{Season:00}E{Episode:00}  "),
        // Not a token at all, only separators, and nothing.
        ("sonarr-standardEpisode", "{Series Title"),
        ("sonarr-standardEpisode", " - "),
        ("sonarr-standardEpisode", "")
    ])
    func customFormatsRoundTrip(targetID: String, format: String) {
        #expect(NamingBlockFixtures.parse(format, targetID).serialized == format)
    }

    @Test("Compound episode numbering is one Episode number block with its own spelling", arguments: [
        "S{season:00}E{episode:00}",
        "{season}x{episode:00}",
        "S{Season:00}E{Episode:00}"
    ])
    func episodeNumberingIsOneBlock(numbering: String) {
        let arrangement = NamingBlockFixtures.parse("{Series Title} - \(numbering) - {Episode Title}")
        #expect(arrangement.blocks.map(\.spelling) == ["{Series Title}", numbering, "{Episode Title}"])
        #expect(arrangement.blocks[1].kind == .element(definitionID: "episodeNumber"))
        #expect(arrangement.joins == [" - ", " - "])
    }

    @Test("Radarr's parenthesised year is one Year block")
    func radarrYearIsOneBlock() {
        let arrangement = NamingBlockFixtures.parse("{Movie Title} ({Release Year}) {Quality Full}", "radarr-standardMovie")
        #expect(arrangement.blocks.map(\.spelling) == ["{Movie Title}", "({Release Year})", "{Quality Full}"])
        #expect(arrangement.blocks.map(\.kind) == [
            .element(definitionID: "movieName"), .element(definitionID: "year"), .element(definitionID: "quality")
        ])
    }

    @Test("Unknown tokens and Radarr tags stay whole custom blocks with their exact spelling")
    func unknownTokensAndTagsStayWhole() {
        let sonarr = NamingBlockFixtures.parse("{Series CleanTitleYear} {Fancy Token}")
        #expect(sonarr.blocks.map(\.spelling) == ["{Series CleanTitleYear}", "{Fancy Token}"])
        #expect(sonarr.blocks.map(\.kind) == [.unknownToken, .unknownToken])

        let radarr = NamingBlockFixtures.parse("{Movie Title} {imdb-{ImdbId}} {edition-{Edition Tags}}", "radarr-standardMovie")
        #expect(radarr.blocks.map(\.spelling) == ["{Movie Title}", "{imdb-{ImdbId}}", "{edition-{Edition Tags}}"])
        #expect(radarr.blocks.map(\.kind) == [.element(definitionID: "movieName"), .unknownToken, .unknownToken])
        #expect(radarr.joins == [" ", " "])
    }

    @Test("Literal words, escaped braces and folder breaks become text blocks, not joins")
    func literalsBecomeTextBlocks() {
        let extras = NamingBlockFixtures.parse("{Series Title} - Extras - S{season:00}E{episode:00}")
        #expect(extras.blocks.map(\.spelling) == ["{Series Title}", "Extras", "S{season:00}E{episode:00}"])
        #expect(extras.blocks[1].kind == .text)
        #expect(extras.joins == [" - ", " - "])

        let specials = NamingBlockFixtures.parse("Specials", "sonarr-specialsFolder")
        #expect(specials.blocks.map(\.kind) == [.text])
        #expect(specials.blocks.map(\.spelling) == ["Specials"])

        let catalog = ArrNamingBlockCatalog(target: .sonarr(.standardEpisode))
        let escaped = ArrNamingArrangement.parse("{{literal}} {Series Title}", catalog: catalog)
        #expect(escaped.blocks.map(\.spelling) == ["{{literal}}", "{Series Title}"])
        #expect(escaped.blocks[0].kind == .text)
        #expect(catalog.text(of: escaped.blocks[0]) == "{literal}", "Sonarr writes an escaped brace as one brace.")

        let folders = NamingBlockFixtures.parse("{Series TitleFirstCharacter}/{Series TitleYear}", "sonarr-seriesFolder")
        #expect(folders.blocks.map(\.spelling) == ["{Series TitleFirstCharacter}", "/", "{Series TitleYear}"])
        #expect(folders.blocks[1].isFolderBreak)
        #expect(folders.joins == ["", ""])
    }

    @Test("Whitespace around a format stays outside the blocks")
    func surroundingWhitespaceIsKept() {
        let arrangement = NamingBlockFixtures.parse("  {series title}  -  S{Season:00}E{Episode:00}  ")
        #expect(arrangement.leading == "  ")
        #expect(arrangement.trailing == "  ")
        #expect(arrangement.blocks.map(\.spelling) == ["{series title}", "S{Season:00}E{Episode:00}"])
        #expect(arrangement.joins == ["  -  "])
    }
}

// MARK: - Mutations

/// Insert, move, remove, customise and separator changes, each checked against the
/// exact serialized format a server would receive.
@Suite("Naming block editing")
@MainActor
struct ArrNamingBlockEditingTests {
    @Test("Inserting at the end, the start and into an empty format uses the format's own join")
    func insertAtEdges() throws {
        let format = "{Series Title} - S{season:00}E{episode:00}"

        let atEnd = NamingBlockFixtures.session(format: format)
        let quality = try #require(atEnd.catalog.definition(id: "quality"))
        atEnd.insert(quality, at: atEnd.arrangement.blocks.count)
        #expect(atEnd.draftFormat == "{Series Title} - S{season:00}E{episode:00} - {Quality Full}")

        let atStart = NamingBlockFixtures.session(format: format)
        atStart.insert(quality, at: 0)
        #expect(atStart.draftFormat == "{Quality Full} - {Series Title} - S{season:00}E{episode:00}")

        let empty = NamingBlockFixtures.session(format: "")
        let showName = try #require(empty.catalog.definition(id: "showName"))
        empty.insert(showName, at: 0)
        #expect(empty.draftFormat == "{Series Title}")
        #expect(empty.separatorState == .none)
    }

    @Test("Moving a block yields the expected format; moving it to where it is changes nothing")
    func moveBlocks() {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        let blocks = session.arrangement.blocks

        session.move(blocks[3].id, to: 0)
        #expect(session.draftFormat == "{Quality Full} - {Series Title} - S{season:00}E{episode:00} - {Episode Title}")
        session.undo()
        #expect(session.draftFormat == NamingBlockFixtures.standardDefault)

        session.move(blocks[2].id, to: 1)
        #expect(session.draftFormat == "{Series Title} - {Episode Title} - S{season:00}E{episode:00} - {Quality Full}")
        session.undo()

        let untouched = session.arrangement
        #expect(untouched.moving(blocks[2].id, to: 2, defaultSeparator: .dashes) == untouched)
        session.move(blocks[2].id, to: 2)
        #expect(!session.canUndo, "A move to the same position is not an edit.")
    }

    @Test("Removing a middle block collapses its joins and keeps an optional release group attached")
    func removeBlocks() {
        let middle = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        middle.remove(middle.arrangement.blocks[2].id)
        #expect(middle.draftFormat == "{Series Title} - S{season:00}E{episode:00} - {Quality Full}")
        #expect(middle.arrangement.joins.count == middle.arrangement.blocks.count - 1)

        let optional = NamingBlockFixtures.session(format: "{Series Title} - {Episode Title} {Quality Full}{-Release Group}")
        optional.remove(optional.arrangement.blocks[2].id)
        #expect(
            optional.draftFormat == "{Series Title} - {Episode Title}{-Release Group}",
            "The release group writes its own dash; a separator before it would double up."
        )
    }

    @Test("Choosing a variant changes only that block's text", arguments: [
        ("{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}", 1, "episodeNumber", "{season}x{episode:00}",
         "{Series Title} - {season}x{episode:00} - {Episode Title} {Quality Full}"),
        ("{Series Title} - S{season:00}E{episode:00} {[Quality Full]}", 2, "quality", "{Quality Title}",
         "{Series Title} - S{season:00}E{episode:00} {[Quality Title]}"),
        ("{Series.Title}.S{season:00}E{episode:00}", 0, "showName", "{Series CleanTitle}",
         "{Series.CleanTitle}.S{season:00}E{episode:00}"),
        // A truncated title is still an Episode title block, and keeps its truncation.
        ("{Series Title} - S{season:00}E{episode:00} - {Episode Title:30}", 2, "episodeTitle", "{Episode CleanTitle}",
         "{Series Title} - S{season:00}E{episode:00} - {Episode CleanTitle:30}")
    ])
    func customiseBlock(format: String, blockIndex: Int, definitionID: String, variantSpelling: String, expected: String) throws {
        let session = NamingBlockFixtures.session(format: format)
        let before = session.arrangement
        #expect(before.blocks[blockIndex].kind == .element(definitionID: definitionID), "The block must be recognised as its friendly definition, not shown as Custom.")
        let definition = try #require(session.catalog.definition(id: definitionID))
        let variant = try #require(definition.variants.first { $0.spelling == variantSpelling })

        session.choose(variant, for: before.blocks[blockIndex].id)

        let after = session.arrangement
        #expect(session.draftFormat == expected)
        #expect(after.blocks.map(\.id) == before.blocks.map(\.id))
        #expect(after.joins == before.joins)
        #expect(after.leading == before.leading && after.trailing == before.trailing)
        for index in before.blocks.indices where index != blockIndex {
            #expect(after.blocks[index] == before.blocks[index])
        }
    }

    @Test("Separator state is uniform only when every ordinary join is one offered style")
    func separatorState() {
        #expect(NamingBlockFixtures.parse("{Series Title} {Episode Title} {Quality Full}").separatorState == .uniform(.spaces))
        #expect(NamingBlockFixtures.parse("{Series Title}.S{season:00}E{episode:00}.{Episode CleanTitle}").separatorState == .uniform(.dots))
        #expect(NamingBlockFixtures.parse("{Series Title} - S{season:00}E{episode:00} - {Episode Title}").separatorState == .uniform(.dashes))
        #expect(NamingBlockFixtures.parse(NamingBlockFixtures.standardDefault).separatorState == .custom)
        #expect(NamingBlockFixtures.parse("{Series Title}_{Episode Title}").separatorState == .custom)
        #expect(NamingBlockFixtures.parse("{Series Title}").separatorState == .none)
    }

    @Test("Applying a separator replaces only ordinary joins", arguments: [
        ("sonarr-standardEpisode", "dots",
         "{Series Title} - S{season:00}E{episode:00} - {Episode Title} [{Quality Full}]{-Release Group}",
         "{Series Title}.S{season:00}E{episode:00}.{Episode Title} [{Quality Full}]{-Release Group}"),
        ("sonarr-standardEpisode", "dots",
         "{Series Title} - Extras - S{season:00}E{episode:00} {Episode Title}",
         "{Series Title} - Extras - S{season:00}E{episode:00}.{Episode Title}"),
        ("sonarr-standardEpisode", "dashes",
         "{Series Title} {season}x{episode:00} {Episode Title}",
         "{Series Title} - {season}x{episode:00} - {Episode Title}"),
        ("sonarr-seriesFolder", "dashes",
         "{Series TitleFirstCharacter}/{Series Title} {Series Year}",
         "{Series TitleFirstCharacter}/{Series Title} - {Series Year}")
    ])
    func applySeparator(targetID: String, styleName: String, format: String, expected: String) throws {
        let style = try #require(ArrNamingSeparatorStyle(rawValue: styleName))
        let session = NamingBlockFixtures.session(NamingBlockFixtures.target(targetID), format: format)
        let spellings = session.arrangement.blocks.map(\.spelling)

        session.applySeparator(style)

        #expect(session.draftFormat == expected)
        #expect(session.arrangement.blocks.map(\.spelling) == spellings, "No block, compound numbering included, is respelled.")
        session.undo()
        #expect(session.draftFormat == format, "A separator change is one explicit, undoable step.")
    }
}

// MARK: - Session

/// The draft a person edits: drags that only commit on drop, the shared Advanced text
/// draft, and saves that keep every edit until the server accepts one.
@Suite("Naming editor session")
@MainActor
struct ArrNamingEditorSessionTests {
    @Test("A proposed drag previews its position and a cancel leaves nothing behind")
    func proposeThenCancel() throws {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        let payload = session.placedPayload(for: session.arrangement.blocks[3].id)

        session.propose(payload, at: 0)
        let proposal = try #require(session.proposal)
        #expect(proposal.serialized == "{Quality Full} - {Series Title} - S{season:00}E{episode:00} - {Episode Title}")
        #expect(session.preview == session.catalog.render(proposal.serialized))
        #expect(session.draftFormat == NamingBlockFixtures.standardDefault, "Hovering is not an edit.")

        session.cancelProposal()
        #expect(session.proposal == nil)
        #expect(session.displayedArrangement == session.arrangement)
        #expect(session.draftFormat == NamingBlockFixtures.standardDefault)
        #expect(session.preview == session.catalog.render(NamingBlockFixtures.standardDefault))
        #expect(!session.canUndo)
        #expect(!session.isDirty)

        #expect(session.drop(payload, at: 3))
        #expect(!session.canUndo, "Dropping a block back where it started records nothing.")
    }

    @Test("A drag through several positions is one undo step, for placed and tray blocks")
    func dragIsOneUndoStep() throws {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        let placed = session.placedPayload(for: session.arrangement.blocks[3].id)

        session.propose(placed, at: 0)
        session.propose(placed, at: 2)
        session.propose(placed, at: 1)
        #expect(session.drop(placed, at: 1))
        let moved = "{Series Title} - {Quality Full} - S{season:00}E{episode:00} - {Episode Title}"
        #expect(session.draftFormat == moved)

        session.undo()
        #expect(session.draftFormat == NamingBlockFixtures.standardDefault)
        #expect(!session.canUndo)
        session.redo()
        #expect(session.draftFormat == moved)
        session.undo()

        let videoInfo = try #require(session.catalog.definition(id: "videoInfo"))
        let tray = try #require(session.trayPayload(for: videoInfo))
        session.propose(tray, at: 0)
        let hoveringID = session.displayedArrangement.blocks[0].id
        session.propose(tray, at: 4)
        #expect(session.displayedArrangement.blocks[4].id == hoveringID, "The hovering block keeps one identity.")
        #expect(session.drop(tray, at: 4))
        let inserted = "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full} - {MediaInfo Simple}"
        #expect(session.draftFormat == inserted)
        #expect(session.arrangement.blocks[4].id == hoveringID)

        session.undo()
        #expect(session.draftFormat == NamingBlockFixtures.standardDefault)
        session.redo()
        #expect(session.draftFormat == inserted)
    }

    @Test("A payload this session does not own is refused and a drop changes nothing", arguments: [
        "another session", "a removed block", "a variant the field does not offer", "a block the field does not offer"
    ])
    func refusesForeignPayloads(kind: String) {
        let payload: ArrNamingBlockDragPayload
        let accepted: ArrNamingBlockDragPayload
        let session: ArrNamingEditorSession

        switch kind {
        case "another session":
            session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
            let other = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
            let source = ArrNamingBlockDragPayload.Source.placed(blockID: session.arrangement.blocks[0].id)
            payload = ArrNamingBlockDragPayload(sessionID: other.id, source: source)
            accepted = ArrNamingBlockDragPayload(sessionID: session.id, source: source)
        case "a removed block":
            session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
            let blockID = session.arrangement.blocks[1].id
            payload = session.placedPayload(for: blockID)
            accepted = session.placedPayload(for: session.arrangement.blocks[0].id)
            #expect(session.accepts(payload), "Accepted while the block exists.")
            session.remove(blockID)
        case "a variant the field does not offer":
            session = NamingBlockFixtures.session(.sonarr(.seriesFolder), format: "{Series Title}")
            payload = ArrNamingBlockDragPayload(sessionID: session.id, source: .tray(definitionID: "year", variant: "({Release Year})"))
            accepted = ArrNamingBlockDragPayload(sessionID: session.id, source: .tray(definitionID: "year", variant: "({Series Year})"))
        default:
            session = NamingBlockFixtures.session(.sonarr(.seriesFolder), format: "{Series Title}")
            payload = ArrNamingBlockDragPayload(sessionID: session.id, source: .tray(definitionID: "airDate", variant: "{Air-Date}"))
            accepted = ArrNamingBlockDragPayload(sessionID: session.id, source: .tray(definitionID: "showName", variant: "{Series TitleYear}"))
        }

        #expect(session.accepts(accepted), "The sibling payload is accepted, so the refusal is about \(kind).")
        let history = session.history
        let draft = session.draftFormat

        #expect(!session.accepts(payload))
        session.propose(payload, at: 0)
        #expect(session.proposal == nil)
        #expect(!session.drop(payload, at: 0))
        #expect(session.history == history)
        #expect(session.draftFormat == draft)
    }

    @Test("Advanced text shares the draft and returns to blocks as one undo step")
    func textModeSharesTheDraft() {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)

        session.editAsText()
        #expect(session.mode == .text)
        #expect(session.textDraft == NamingBlockFixtures.standardDefault)
        #expect(session.useBlocks())
        #expect(!session.canUndo, "Returning unchanged text is not an edit.")

        session.editAsText()
        let edited = NamingBlockFixtures.standardDefault + "{-Release Group}"
        session.textDraft = edited
        #expect(session.draftFormat == edited)
        #expect(session.isDirty)
        #expect(session.preview == session.catalog.render(edited))

        #expect(session.useBlocks())
        #expect(session.mode == .blocks)
        #expect(session.draftFormat == edited)
        #expect(session.arrangement.blocks.last?.kind == .element(definitionID: "releaseGroup"))

        session.undo()
        #expect(session.draftFormat == NamingBlockFixtures.standardDefault)
        #expect(!session.canUndo)
        session.redo()
        #expect(session.draftFormat == edited)
    }

    @Test("A refused save keeps the whole draft, and the retry submits exactly what the preview showed")
    func refusedSaveKeepsDraftForRetry() async {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        session.applySeparator(.dots)
        let draft = session.draftFormat
        let preview = session.preview
        let recorder = SubmissionRecorder()

        let refused = await session.save { submitted in
            recorder.record(submitted)
            return nil
        }
        #expect(!refused)
        #expect(session.saveState == .failed)
        #expect(session.isDirty)
        #expect(session.draftFormat == draft)
        #expect(session.canUndo, "The edit history survives a refusal too.")

        let saved = await session.save { submitted in
            recorder.record(submitted)
            return submitted
        }
        #expect(saved)
        #expect(recorder.submissions == [draft, draft])
        #expect(session.catalog.render(recorder.submissions.last ?? "") == preview)
        #expect(session.saveState == .idle)
        #expect(session.baseline == draft)
        #expect(!session.isDirty)
    }

    @Test("A server value that differs from the submission becomes the baseline and the draft")
    func acceptedValueReconciles() async {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        session.applySeparator(.dots)
        let canonical = "{Series Title}.S{season:00}E{episode:00}.{Episode CleanTitle}.{Quality Full}"
        #expect(session.draftFormat != canonical)

        let saved = await session.save { _ in canonical }

        #expect(saved)
        #expect(session.baseline == canonical)
        #expect(session.draftFormat == canonical)
        #expect(session.arrangement.serialized == canonical)
        #expect(session.preview == session.catalog.render(canonical))
        #expect(!session.isDirty)
    }

    @Test("A second save while one is in flight is refused without submitting")
    func duplicateSaveIsRefused() async {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        session.applySeparator(.dots)
        let draft = session.draftFormat
        let barrier = SaveBarrier()
        let duplicate = SubmissionRecorder()

        let first = Task { await session.save { await barrier.perform($0) } }
        await barrier.waitForSubmission()
        #expect(session.isSaving)
        #expect(!session.canSave)

        let second = await session.save { submitted in
            duplicate.record(submitted)
            return submitted
        }
        #expect(!second)
        #expect(duplicate.submissions.isEmpty)

        barrier.resume(returning: draft)
        #expect(await first.value)
        #expect(barrier.submissions == [draft])
        #expect(!session.isDirty)
        #expect(session.saveState == .idle)
    }
}

// MARK: - Preview and validation

/// What a person reads before saving, and the field rules Save is gated on.
@Suite("Naming preview and validation")
@MainActor
struct ArrNamingPreviewValidationTests {
    @Test("The preview renders exactly the draft Save would submit")
    func previewIsTheDraft() throws {
        let session = NamingBlockFixtures.session(format: NamingBlockFixtures.standardDefault)
        let episodeTitle = try #require(session.catalog.definition(id: "episodeTitle"))
        let clean = try #require(episodeTitle.variants.first { $0.spelling == "{Episode CleanTitle}" })
        session.choose(clean, for: session.arrangement.blocks[2].id)
        session.applySeparator(.dots)

        #expect(session.preview == session.catalog.render(session.draftFormat))
        #expect(session.preview.text == "Example Show.S02E03.Pilot.WEBDL-1080p Proper")

        session.editAsText()
        session.textDraft = "{Series Title} {Fancy Token}"
        #expect(session.preview == session.catalog.render(session.draftFormat))
    }

    @Test("Token case, separators, decoration and padding shape the sample as the server would", arguments: [
        ("sonarr-standardEpisode", "{series title}", "example show"),
        ("sonarr-standardEpisode", "{SERIES TITLE}", "EXAMPLE SHOW"),
        ("sonarr-standardEpisode", "{Series.Title}", "Example.Show"),
        ("sonarr-dailyEpisode", "{Air.Date}", "2026.05.17"),
        ("sonarr-standardEpisode", "{[Quality Full]}", "[WEBDL-1080p Proper]"),
        ("sonarr-standardEpisode", "{season:000}", "002"),
        ("sonarr-standardEpisode", "{Series Title} - S{season:00}E{episode:00}{-Release Group}", "Example Show - S02E03-GROUP"),
        ("sonarr-standardEpisode", "{Series Title} - ", "Example Show"),
        ("sonarr-standardEpisode", "{{literal}} {Series Title}", "{literal} Example Show"),
        ("radarr-standardMovie", "{Movie Title} ({Release Year}) {Quality Full}", "Example Movie (2026) WEBDL-1080p Proper")
    ])
    func renderedSamples(targetID: String, format: String, expected: String) {
        let rendered = ArrNamingBlockCatalog(target: NamingBlockFixtures.target(targetID)).render(format)
        #expect(rendered.text == expected)
        #expect(rendered.isVerifiable)
    }

    @Test("Unknown and approximated tokens are identified, not presented as verified")
    func unverifiableTokensAreFlagged() {
        let rendered = ArrNamingBlockCatalog(target: .sonarr(.standardEpisode)).render("{Series Title} {Fancy Token} {Episode Title:30}")
        #expect(rendered.text == "Example Show {Fancy Token} Pilot")
        #expect(rendered.unresolvedTokens == ["{Fancy Token}"])
        #expect(rendered.approximatedTokens == ["{Episode Title:30}"])
        #expect(!rendered.isVerifiable)
    }

    @Test("Folder builders offer no episode, air date, quality or media blocks")
    func folderCatalogsAreRestricted() {
        let fileOnlyPrefixes = ["season", "episode", "airdate", "absolute", "quality", "mediainfo", "customformat", "releasegroup", "releasehash", "original"]

        func fileOnlyTokens(in target: ArrNamingFormatEditorTarget) -> [String] {
            let catalog = ArrNamingBlockCatalog(target: target)
            return catalog.definitions
                .flatMap(\.variants)
                .flatMap { ArrNamingSyntax.tokens(in: $0.spelling, dialect: catalog.dialect) }
                .filter { token in fileOnlyPrefixes.contains { token.normalizedName.hasPrefix($0) } }
                .map(\.spelling)
        }

        #expect(fileOnlyTokens(in: .sonarr(.seriesFolder)).isEmpty)
        #expect(fileOnlyTokens(in: .radarr(.movieFolder)).isEmpty)
        #expect(!fileOnlyTokens(in: .sonarr(.standardEpisode)).isEmpty, "The episode builder does offer them, so the check can fail.")
        #expect(!fileOnlyTokens(in: .radarr(.standardMovie)).isEmpty)
    }

    @Test("The file extension is illustrative: files show .mkv, folders none, and no draft ever saves it")
    func extensionIsPreviewOnly() async {
        let fileTargets: Set<String> = ["sonarr-standardEpisode", "sonarr-dailyEpisode", "sonarr-animeEpisode", "radarr-standardMovie"]

        for target in NamingBlockFixtures.allTargets {
            let session = NamingBlockFixtures.session(target, format: target.presets.first?.format ?? "")
            #expect(session.catalog.previewFileExtension == (fileTargets.contains(target.id) ? ".mkv" : nil), "\(target.id)")

            for definition in session.catalog.commonDefinitions {
                session.append(definition)
            }
            session.applySeparator(.dots)
            let recorder = SubmissionRecorder()
            _ = await session.save { submitted in
                recorder.record(submitted)
                return submitted
            }

            #expect(recorder.submissions.count == 1, "\(target.id)")
            #expect(!recorder.submissions.contains { $0.contains(".mkv") }, "\(target.id)")
            #expect(!session.draftFormat.contains(".mkv"), "\(target.id)")
            #expect(!session.preview.text.contains(".mkv"), "\(target.id)")
        }
    }

    @Test("Validation mirrors the servers' field rules", arguments: [
        ("sonarr-standardEpisode", "{Series Title} - {Episode Title}", true),
        ("sonarr-standardEpisode", "{Series Title} - S{season:00}E{episode:00}", false),
        ("sonarr-standardEpisode", "{Original Filename}", false),
        ("sonarr-dailyEpisode", "{Series Title} - {Episode Title}", true),
        ("sonarr-dailyEpisode", "{Series Title} - {Air-Date}", false),
        ("sonarr-animeEpisode", "{Series Title} - {absolute:000}", false),
        ("sonarr-seriesFolder", "{Series Title}", false),
        ("sonarr-seriesFolder", "{[Series Title]}", true),
        ("sonarr-seasonFolder", "Season {season:00}", false),
        ("sonarr-seasonFolder", "Season", true),
        ("radarr-standardMovie", "{Movie Title}", true),
        ("radarr-standardMovie", "{Release Year}", true),
        ("radarr-standardMovie", "{Movie Title} ({Release Year})", false),
        ("radarr-standardMovie", "{Original Title}", false),
        ("radarr-movieFolder", "{Movie Title}", false),
        ("radarr-movieFolder", "({Release Year})", true)
    ])
    func fieldRules(targetID: String, format: String, expectsIssue: Bool) {
        let issue = ArrNamingFormatValidation.issue(for: format, target: NamingBlockFixtures.target(targetID))
        #expect((issue != nil) == expectsIssue, "\(issue ?? "no issue")")
    }

    @Test("An empty or blank format is an issue for every field")
    func emptyFormatIsAnIssue() {
        for target in NamingBlockFixtures.allTargets {
            #expect(ArrNamingFormatValidation.issue(for: "", target: target) != nil, "\(target.id)")
            #expect(ArrNamingFormatValidation.issue(for: "   ", target: target) != nil, "\(target.id)")
        }
    }

    @Test("A rule the server's own format already breaks warns without blocking Save")
    func validationDefersToTheServerBaseline() {
        let unusual = NamingBlockFixtures.session(.sonarr(.seriesFolder), format: "{[Series Title]}")
        unusual.editAsText()
        unusual.textDraft = "{[Series Title]} ({Series Year})"
        #expect(unusual.validationIssue != nil)
        #expect(!unusual.validationBlocksSave)
        #expect(unusual.canSave)

        let ordinary = NamingBlockFixtures.session(.sonarr(.seriesFolder), format: "{Series Title}")
        ordinary.editAsText()
        ordinary.textDraft = "{Series Year}"
        #expect(ordinary.validationIssue != nil)
        #expect(ordinary.validationBlocksSave)
        #expect(!ordinary.canSave)
    }
}

// MARK: - Drop geometry

/// Where a drop lands on the board, for both arrangements the board draws: equal
/// columns filled in reading order, and one column at accessibility text sizes.
@Suite("Naming block drop geometry")
@MainActor
struct ArrNamingBlockDropIndexTests {
    private static let ids = (0..<4).map { _ in UUID() }

    /// A B / C D, 100pt columns and 80pt rows, 3pt apart.
    private static let twoColumns: [(id: UUID, frame: CGRect)] = [
        (ids[0], CGRect(x: 0, y: 0, width: 100, height: 80)),
        (ids[1], CGRect(x: 103, y: 0, width: 100, height: 80)),
        (ids[2], CGRect(x: 0, y: 83, width: 100, height: 80)),
        (ids[3], CGRect(x: 103, y: 83, width: 100, height: 80))
    ]

    /// A / B / C.
    private static let oneColumn: [(id: UUID, frame: CGRect)] = [
        (ids[0], CGRect(x: 0, y: 0, width: 200, height: 80)),
        (ids[1], CGRect(x: 0, y: 83, width: 200, height: 80)),
        (ids[2], CGRect(x: 0, y: 166, width: 200, height: 80))
    ]

    @Test("In columns a drop picks the row, then goes before the first block whose middle it has not passed", arguments: [
        (CGPoint(x: 10, y: 40), 0),
        (CGPoint(x: 60, y: 40), 1),
        (CGPoint(x: 190, y: 40), 2),
        (CGPoint(x: 10, y: 120), 2),
        (CGPoint(x: 190, y: 150), 4),
        (CGPoint(x: 60, y: 300), 3)
    ])
    func twoColumnInsertion(location: CGPoint, expected: Int) {
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: location, in: Self.twoColumns, placeholderID: nil) == expected)
    }

    @Test("A block dragged within the columns is not counted, so hovering beside its own slot keeps it there")
    func twoColumnReorderIgnoresTheDraggedBlock() {
        let dragged = Self.ids[1]
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: CGPoint(x: 160, y: 40), in: Self.twoColumns, placeholderID: dragged) == 1)
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: CGPoint(x: 10, y: 40), in: Self.twoColumns, placeholderID: dragged) == 0)
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: CGPoint(x: 190, y: 150), in: Self.twoColumns, placeholderID: dragged) == 3)
    }

    @Test("In one column a drop goes before the first block whose vertical middle it has not passed", arguments: [
        (CGPoint(x: 150, y: 20), 0),
        (CGPoint(x: 10, y: 100), 1),
        (CGPoint(x: 190, y: 130), 2),
        (CGPoint(x: 10, y: 300), 3)
    ])
    func oneColumnInsertion(location: CGPoint, expected: Int) {
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: location, in: Self.oneColumn, placeholderID: nil, singleColumn: true) == expected)
    }

    @Test("One column must be read vertically: the same point placed by columns would land after the first block")
    func oneColumnNeedsVerticalPlacement() {
        let topRightOfFirstBlock = CGPoint(x: 150, y: 20)
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: topRightOfFirstBlock, in: Self.oneColumn, placeholderID: nil, singleColumn: true) == 0)
        #expect(ArrNamingBlockDropIndex.insertionIndex(at: topRightOfFirstBlock, in: Self.oneColumn, placeholderID: nil) == 1)
    }
}
