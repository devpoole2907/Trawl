import Foundation
import Observation

/// Which format on which server a draft belongs to. HD and 4K servers keep separate
/// naming rules with identical field names, so the service type alone is not an identity.
struct ArrNamingEditorScope: Hashable {
    let instanceID: UUID
    let target: ArrNamingFormatEditorTarget
}

/// What a builder drag carries. The session ID makes a drag from another editor, a
/// stale session or another app land nowhere rather than on the wrong format.
nonisolated struct ArrNamingBlockDragPayload: Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        case placed(blockID: UUID)
        case tray(definitionID: String, variant: String)
    }

    let sessionID: UUID
    let source: Source
}

/// One naming format being edited: the value the server holds, the local draft with
/// its undo history, any drag in progress, and the save in flight.
///
/// Everything here is local until `save(using:)`. The builder and the Advanced text
/// editor share this one draft, and the preview renders the same serialized string
/// that Save submits.
@MainActor
@Observable
final class ArrNamingEditorSession: Identifiable {
    enum Mode: Hashable {
        case blocks
        case text
    }

    enum SaveState: Hashable {
        case idle
        case saving
        case failed
    }

    let id = UUID()
    let scope: ArrNamingEditorScope
    /// The server as the person knows it ("Sonarr 4K"), for confirmations.
    let serverName: String
    let catalog: ArrNamingBlockCatalog

    private(set) var baseline: String
    private(set) var history: ArrNamingDraftHistory
    private(set) var mode: Mode = .blocks
    /// The Advanced editor's text. Only authoritative while `mode == .text`.
    var textDraft = ""
    /// Where an in-flight drag would put things. Nil when nothing is being dragged
    /// over the arrangement, so a cancelled drag leaves nothing behind.
    private(set) var proposal: ArrNamingArrangement?
    private(set) var saveState: SaveState = .idle

    /// A block created for a tray drag keeps one identity while it hovers, so the
    /// arrangement animates it between positions rather than replacing it.
    private var trayDragBlock: (payload: ArrNamingBlockDragPayload, block: ArrNamingBlock)?

    init(scope: ArrNamingEditorScope, serverName: String, serverFormat: String) {
        self.scope = scope
        self.serverName = serverName
        let catalog = ArrNamingBlockCatalog(target: scope.target)
        self.catalog = catalog
        self.baseline = serverFormat
        self.history = ArrNamingDraftHistory(.parse(serverFormat, catalog: catalog))
    }

    var target: ArrNamingFormatEditorTarget { scope.target }
    var arrangement: ArrNamingArrangement { history.current }
    /// The arrangement to draw: the drag proposal while one exists.
    var displayedArrangement: ArrNamingArrangement { proposal ?? history.current }

    /// Exactly what Save submits.
    var draftFormat: String {
        mode == .text ? textDraft : history.current.serialized
    }

    /// What the preview renders: the draft, or where a hovering drag would leave it.
    var previewFormat: String {
        mode == .text ? textDraft : displayedArrangement.serialized
    }

    var preview: ArrNamingRenderedFormat { catalog.render(previewFormat) }

    var isDirty: Bool { draftFormat != baseline }
    var isSaving: Bool { saveState == .saving }

    /// Why the server would refuse the draft, if the servers' field rules say it would.
    var validationIssue: String? {
        ArrNamingFormatValidation.issue(for: draftFormat, target: target)
    }

    /// A rule the server's own saved format already breaks is this validator
    /// disagreeing with the server, not the draft being wrong, so it warns without
    /// blocking a save.
    var validationBlocksSave: Bool {
        validationIssue != nil && ArrNamingFormatValidation.issue(for: baseline, target: target) == nil
    }

    var canSave: Bool { isDirty && !isSaving && !validationBlocksSave }
    var canUndo: Bool { mode == .blocks && !isSaving && history.canUndo }
    var canRedo: Bool { mode == .blocks && !isSaving && history.canRedo }
    var separatorState: ArrNamingSeparatorState { displayedArrangement.separatorState }

    // MARK: - Editing

    func append(_ definition: ArrNamingBlockDefinition, variant: ArrNamingBlockVariant? = nil) {
        insert(definition, variant: variant, at: arrangement.blocks.count)
    }

    func insert(_ definition: ArrNamingBlockDefinition, variant: ArrNamingBlockVariant? = nil, at index: Int) {
        guard let variant = variant ?? definition.variants.first else { return }
        let block = ArrNamingBlock(kind: .element(definitionID: definition.id), spelling: variant.spelling)
        commit(arrangement.inserting(block, at: index, defaultSeparator: catalog.defaultSeparator))
    }

    /// Adds literal text such as `Specials`. Returns the new block's ID.
    @discardableResult
    func insertText(_ text: String, at index: Int? = nil) -> UUID? {
        let spelling = catalog.spelling(forText: text)
        guard !spelling.isEmpty else { return nil }
        let block = ArrNamingBlock(kind: .text, spelling: spelling)
        commit(arrangement.inserting(block, at: index ?? arrangement.blocks.count, defaultSeparator: catalog.defaultSeparator))
        return block.id
    }

    /// Replaces a text block's words. Clearing them is a removal, so do that explicitly.
    func setText(_ text: String, for blockID: UUID) {
        let spelling = catalog.spelling(forText: text)
        guard !spelling.isEmpty else { return }
        commit(arrangement.replacingSpelling(of: blockID, with: spelling, kind: .text))
    }

    func remove(_ blockID: UUID) {
        commit(arrangement.removing(blockID, defaultSeparator: catalog.defaultSeparator))
    }

    func move(_ blockID: UUID, to destination: Int) {
        commit(arrangement.moving(blockID, to: destination, defaultSeparator: catalog.defaultSeparator))
    }

    func moveEarlier(_ blockID: UUID) {
        guard let index = arrangement.index(of: blockID), index > 0 else { return }
        move(blockID, to: index - 1)
    }

    func moveLater(_ blockID: UUID) {
        guard let index = arrangement.index(of: blockID), index < arrangement.blocks.count - 1 else { return }
        move(blockID, to: index + 1)
    }

    func choose(_ variant: ArrNamingBlockVariant, for blockID: UUID) {
        guard let block = arrangement.blocks.first(where: { $0.id == blockID }) else { return }
        commit(arrangement.replacingSpelling(of: blockID, with: catalog.spelling(for: block, choosing: variant)))
    }

    /// An explicit, undoable replacement of the joins between ordinary blocks.
    func applySeparator(_ style: ArrNamingSeparatorStyle) {
        commit(arrangement.applyingSeparator(style))
    }

    /// Replaces the whole draft, as "Start Simple" and presets do. Undoable.
    func replaceFormat(with format: String) {
        switch mode {
        case .blocks:
            commit(.parse(format, catalog: catalog))
        case .text:
            textDraft = format
        }
    }

    func undo() {
        guard canUndo else { return }
        proposal = nil
        history.undo()
    }

    func redo() {
        guard canRedo else { return }
        proposal = nil
        history.redo()
    }

    /// Returns the draft to the server's value.
    func discardChanges() {
        history = ArrNamingDraftHistory(.parse(baseline, catalog: catalog))
        mode = .blocks
        textDraft = ""
        proposal = nil
        trayDragBlock = nil
        saveState = .idle
    }

    private func commit(_ next: ArrNamingArrangement) {
        guard mode == .blocks, !isSaving else { return }
        proposal = nil
        history.commit(next)
    }

    // MARK: - Advanced text

    func editAsText() {
        guard mode == .blocks else { return }
        proposal = nil
        textDraft = history.current.serialized
        mode = .text
    }

    /// Returns to the builder with the text reparsed, as one undo step when it
    /// changed. Stays in text mode, and returns false, if the text could not be
    /// represented exactly as blocks.
    @discardableResult
    func useBlocks() -> Bool {
        guard mode == .text else { return true }
        let parsed = ArrNamingArrangement.parse(textDraft, catalog: catalog)
        guard parsed.serialized == textDraft else { return false }
        mode = .blocks
        if parsed.serialized != history.current.serialized {
            history.commit(parsed)
        }
        return true
    }

    // MARK: - Dragging

    /// Whether a drop of `payload` belongs here: this session, a block that still
    /// exists, or a tray variant this format really offers.
    func accepts(_ payload: ArrNamingBlockDragPayload) -> Bool {
        guard payload.sessionID == id, mode == .blocks, !isSaving else { return false }
        switch payload.source {
        case .placed(let blockID):
            return arrangement.index(of: blockID) != nil
        case .tray(let definitionID, let spelling):
            return catalog.definition(id: definitionID)?.variants.contains { $0.spelling == spelling } ?? false
        }
    }

    /// The arrangement a drop would produce. `insertionIndex` counts positions among
    /// the blocks that stay put: for a placed block, the arrangement without it
    /// (`0..<count`); for a tray block, the whole arrangement (`0...count`).
    func arrangement(dropping payload: ArrNamingBlockDragPayload, at insertionIndex: Int) -> ArrNamingArrangement? {
        guard accepts(payload) else { return nil }
        let base = history.current
        switch payload.source {
        case .placed(let blockID):
            guard let source = base.index(of: blockID) else { return nil }
            let destination = min(max(insertionIndex, 0), base.blocks.count - 1)
            return destination == source ? base : base.moving(blockID, to: destination, defaultSeparator: catalog.defaultSeparator)
        case .tray:
            guard let block = trayBlock(for: payload) else { return nil }
            return base.inserting(block, at: insertionIndex, defaultSeparator: catalog.defaultSeparator)
        }
    }

    /// Shows where a drop would land, without recording anything.
    func propose(_ payload: ArrNamingBlockDragPayload, at insertionIndex: Int) {
        guard let next = arrangement(dropping: payload, at: insertionIndex) else {
            proposal = nil
            return
        }
        proposal = next == history.current ? nil : next
    }

    /// Restores the committed arrangement after a drag leaves or is cancelled.
    func cancelProposal() {
        proposal = nil
        trayDragBlock = nil
    }

    /// Completes a drag as one undoable step. Returns false, changing nothing, for a
    /// payload this session does not accept.
    @discardableResult
    func drop(_ payload: ArrNamingBlockDragPayload, at insertionIndex: Int) -> Bool {
        guard let next = arrangement(dropping: payload, at: insertionIndex) else {
            cancelProposal()
            return false
        }
        proposal = nil
        trayDragBlock = nil
        history.commit(next)
        return true
    }

    func trayPayload(for definition: ArrNamingBlockDefinition, variant: ArrNamingBlockVariant? = nil) -> ArrNamingBlockDragPayload? {
        guard let variant = variant ?? definition.variants.first else { return nil }
        return ArrNamingBlockDragPayload(sessionID: id, source: .tray(definitionID: definition.id, variant: variant.spelling))
    }

    func placedPayload(for blockID: UUID) -> ArrNamingBlockDragPayload {
        ArrNamingBlockDragPayload(sessionID: id, source: .placed(blockID: blockID))
    }

    private func trayBlock(for payload: ArrNamingBlockDragPayload) -> ArrNamingBlock? {
        guard case .tray(let definitionID, let spelling) = payload.source else { return nil }
        if let existing = trayDragBlock, existing.payload == payload {
            return existing.block
        }
        let block = ArrNamingBlock(kind: .element(definitionID: definitionID), spelling: spelling)
        trayDragBlock = (payload, block)
        return block
    }

    // MARK: - Saving

    /// Submits the draft through `perform`, which writes to the server captured when
    /// the session was created and returns the value the server accepted, or nil when
    /// it refused. A refusal leaves the whole draft in place for a retry.
    @discardableResult
    func save(using perform: (String) async -> String?) async -> Bool {
        guard isDirty, !isSaving else { return false }
        let submitted = draftFormat
        proposal = nil
        saveState = .saving
        guard let accepted = await perform(submitted) else {
            saveState = .failed
            return false
        }
        saveState = .idle
        reconcile(accepted: accepted, submitted: submitted)
        return true
    }

    /// Adopts the server's accepted value as the new baseline. The draft follows it
    /// only if it is still what was submitted; the accepted value is not assumed to
    /// equal the submitted one.
    func reconcile(accepted: String, submitted: String) {
        baseline = accepted
        switch mode {
        case .text:
            if textDraft == submitted { textDraft = accepted }
        case .blocks:
            if history.current.serialized == submitted, accepted != submitted {
                history = ArrNamingDraftHistory(.parse(accepted, catalog: catalog))
            }
        }
    }

    /// Follows a server value reloaded underneath an untouched draft. A draft with
    /// edits keeps its baseline, so its changes are still measured against what the
    /// person started from.
    func refreshBaseline(_ serverFormat: String) {
        guard !isDirty, !isSaving, serverFormat != baseline else { return }
        baseline = serverFormat
        history = ArrNamingDraftHistory(.parse(serverFormat, catalog: catalog))
        textDraft = mode == .text ? serverFormat : ""
    }
}
