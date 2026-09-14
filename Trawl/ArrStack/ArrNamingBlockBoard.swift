import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag payload

/// Carried as JSON, a type the system already declares, and visible only inside this
/// process. Other apps never see a naming block, and no custom type needs an
/// Info.plist declaration (an undeclared exported type is undefined behaviour).
nonisolated extension ArrNamingBlockDragPayload: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
            .visibility(.ownProcess)
    }
}

/// The builder drag in flight.
///
/// `DropInfo` cannot read a payload until the drop, and `onDropSessionUpdated` needs
/// iOS 27, so hovering uses the payload recorded here when the system asks a chip or
/// tray item for it. The drop itself decodes the real payload and commits only when
/// the two agree, so a stale record can never be committed.
@MainActor
final class ArrNamingBlockDragTracker {
    static let shared = ArrNamingBlockDragTracker()

    private(set) var current: ArrNamingBlockDragPayload?

    /// Records `payload` as the drag starting now and hands it back to the drag source.
    func begin(_ payload: ArrNamingBlockDragPayload) -> ArrNamingBlockDragPayload {
        current = payload
        return payload
    }

    func end(_ payload: ArrNamingBlockDragPayload) {
        if current == payload { current = nil }
    }
}

// MARK: - Board

/// How much room the builder has, so blocks keep one design and only spacing adapts.
enum ArrNamingBlockDensity {
    case compact
    case regular

    var boardPadding: CGFloat { self == .compact ? 10 : 14 }
}

/// The arrangement being built: wrapping blocks that can be tapped for options,
/// dragged to reorder, and that accept blocks dragged in from the tray.
struct ArrNamingBlockBoard: View {
    let session: ArrNamingEditorSession
    var density: ArrNamingBlockDensity = .regular

    @State private var dropState = ArrNamingBlockDropState()
    @State private var optionsBlockID: UUID?
    @State private var editingTextBlockID: UUID?
    @State private var textDraft = ""
    @FocusState private var focusedBlockID: UUID?
    @AccessibilityFocusState private var accessibilityFocusedBlockID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var maxBlockWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .body) private var minBoardHeight: CGFloat = 110

    private var accent: Color { session.target.serviceType.serviceIdentity.brandColor }
    private var animation: Animation? { reduceMotion ? nil : .snappy }

    /// Equal columns where room is tight - two on a phone, one at accessibility text
    /// sizes - so blocks line up in reading order; wider boards wrap blocks by content.
    private var columnCount: Int? {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return density == .compact ? 2 : nil
    }

    private var blockLayout: AnyLayout {
        let spacing = DesignConstants.Spacing.iconText
        if let columnCount {
            return AnyLayout(ArrNamingBlockColumnsLayout(columns: columnCount, spacing: spacing))
        }
        return AnyLayout(ArrNamingBlockFlowLayout(spacing: spacing, maxStretchedWidth: maxBlockWidth))
    }

    var body: some View {
        let arrangement = session.displayedArrangement
        let placeholderID = dropState.placeholderID(in: session)
        let boardShape = RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)

        Group {
            if arrangement.blocks.isEmpty {
                Label("Drop your first block here, or tap one below.", systemImage: "plus.square.dashed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: minBoardHeight)
            } else {
                blockLayout {
                    ForEach(arrangement.blocks.enumerated(), id: \.element.id) { index, block in
                        chip(for: block, index: index, count: arrangement.blocks.count, isPlaceholder: block.id == placeholderID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minBoardHeight, alignment: .topLeading)
        .padding(density.boardPadding)
        .background(dropState.isHovering ? accent.opacity(0.08) : Color.clear, in: boardShape)
        .background(.background.secondary, in: boardShape)
        .overlay {
            boardShape.strokeBorder(
                dropState.isHovering ? accent : Color.secondary.opacity(0.3),
                style: StrokeStyle(lineWidth: 2, dash: [7, 5])
            )
        }
        .animation(animation, value: arrangement.blocks.map(\.id))
        .animation(animation, value: dropState.isHovering)
        // The drop location arrives in this view's space, so chip frames are measured in it.
        .coordinateSpace(.named(ArrNamingBlockDropIndex.coordinateSpace))
        .onDrop(of: [.json], delegate: ArrNamingBlockDropDelegate(session: session, state: dropState, animation: animation))
        .disabled(session.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filename blocks")
        .accessibilityIdentifier("naming.blocks")
        .onChange(of: session.id) {
            dropState.reset()
            optionsBlockID = nil
        }
        .onChange(of: columnCount, initial: true) { _, count in
            // A single column reads top to bottom, so drops compare vertical midpoints.
            dropState.isSingleColumn = count == 1
        }
        .alert("Edit Words", isPresented: textEditorBinding) {
            TextField("Words", text: $textDraft)
                .autocorrectionDisabled()
            Button("Update", action: commitText)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.catalog.isFolderFormat
                 ? "Written into every folder name exactly as typed."
                 : "Written into every filename exactly as typed.")
        }
    }

    private func chip(for block: ArrNamingBlock, index: Int, count: Int, isPlaceholder: Bool) -> some View {
        let catalog = session.catalog
        let title = catalog.title(for: block)
        let sample = catalog.sample(for: block)
        let tile = ArrNamingBlockChip(
            title: title,
            sample: sample,
            systemImage: catalog.systemImage(for: block),
            style: ArrNamingBlockChip.Style(block),
            category: ArrNamingBlockCategory(block, in: catalog)
        )

        return Button {
            optionsBlockID = block.id
        } label: {
            tile.placeholder(isPlaceholder, accent: accent)
        }
        .buttonStyle(.plain)
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: ArrNamingBlockChip.cornerRadius))
        // The system lifts the block itself, so drag feedback stays native.
        .draggable(ArrNamingBlockDragTracker.shared.begin(session.placedPayload(for: block.id)))
        .focusable()
        .focused($focusedBlockID, equals: block.id)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press, for: block.id)
        }
        // A native choice list, anchored to the block where the platform anchors
        // dialogs, rather than a sheet carrying its own chrome.
        .confirmationDialog(title, isPresented: optionsBinding(for: block.id), titleVisibility: .visible) {
            blockActions(for: block, index: index, count: count)
        } message: {
            Text(optionsMessage(for: block, sample: sample))
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(ArrNamingBlockDropIndex.coordinateSpace))
        } action: { frame in
            dropState.frames[block.id] = frame
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(sample)")
        .accessibilityValue("Block \(index + 1) of \(count)")
        .accessibilityHint("Opens options")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("naming.block")
        .accessibilityFocused($accessibilityFocusedBlockID, equals: block.id)
        .accessibilityAction {
            optionsBlockID = block.id
        }
        .accessibilityActions {
            if index > 0 {
                Button("Move Earlier") { moveEarlier(block.id) }
            }
            if index < count - 1 {
                Button("Move Later") { moveLater(block.id) }
            }
            Button("Remove") { remove(block.id) }
        }
    }

    private func optionsBinding(for blockID: UUID) -> Binding<Bool> {
        Binding {
            optionsBlockID == blockID
        } set: { isPresented in
            if isPresented {
                optionsBlockID = blockID
            } else if optionsBlockID == blockID {
                optionsBlockID = nil
                // Back to the chip the options belonged to, for keyboard and VoiceOver alike.
                if session.arrangement.index(of: blockID) != nil {
                    focusedBlockID = blockID
                    accessibilityFocusedBlockID = blockID
                }
            }
        }
    }

    // MARK: Options

    /// The other ways this block can be written, labelled by what they write, then its
    /// position and removal.
    @ViewBuilder
    private func blockActions(for block: ArrNamingBlock, index: Int, count: Int) -> some View {
        let catalog = session.catalog
        if let definition = catalog.definition(for: block) {
            let selected = catalog.selectedVariant(for: block)
            let samples = definition.variants.map { catalog.sample(forSpelling: $0.spelling) }
            ForEach(definition.variants.enumerated(), id: \.element.id) { offset, variant in
                if variant != selected {
                    Button(variantTitle(variant, sample: samples[offset], among: samples)) {
                        withAnimation(animation) { session.choose(variant, for: block.id) }
                    }
                }
            }
        }
        if block.kind == .text, !block.isFolderBreak {
            Button("Edit Words…") { beginEditingText(block) }
        }
        if index > 0 {
            Button("Move Earlier") { moveEarlier(block.id) }
        }
        if index < count - 1 {
            Button("Move Later") { moveLater(block.id) }
        }
        Button("Remove", role: .destructive) { remove(block.id) }
        Button("Cancel", role: .cancel) {}
    }

    /// A choice's output, plus the catalog's name only when two choices would otherwise
    /// read the same (a clean title and a plain one).
    private func variantTitle(_ variant: ArrNamingBlockVariant, sample: String, among samples: [String]) -> String {
        guard samples.filter({ $0 == sample }).count > 1,
              let name = session.target.tokenGroups
                .flatMap(\.tokens)
                .first(where: { $0.value.lowercased() == variant.spelling.lowercased() })?
                .title else {
            return sample
        }
        return "\(sample) (\(name))"
    }

    private func optionsMessage(for block: ArrNamingBlock, sample: String) -> String {
        let catalog = session.catalog
        if block.isFolderBreak {
            return "Starts a subfolder. The blocks before it name the outer folder, and the blocks after it name the folder inside."
        }
        switch block.kind {
        case .element:
            if catalog.selectedVariant(for: block) == nil {
                return "Currently \(sample), with its own styling on \(session.serverName)."
            }
            return "Currently \(sample)."
        case .unknownToken:
            return "Kept exactly as \(session.serverName) has it: \(block.spelling)"
        case .text:
            return "Written exactly as “\(catalog.text(of: block))”."
        }
    }

    private var textEditorBinding: Binding<Bool> {
        Binding {
            editingTextBlockID != nil
        } set: { isPresented in
            if !isPresented { editingTextBlockID = nil }
        }
    }

    private func beginEditingText(_ block: ArrNamingBlock) {
        textDraft = session.catalog.text(of: block)
        editingTextBlockID = block.id
    }

    /// Saves edited words as one undo step. Clearing them is not a removal; Remove is.
    private func commitText() {
        guard let blockID = editingTextBlockID,
              let block = session.arrangement.blocks.first(where: { $0.id == blockID }) else { return }
        let words = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != session.catalog.text(of: block) else { return }
        withAnimation(animation) { session.setText(words, for: blockID) }
    }

    // MARK: Actions

    private func handleKeyPress(_ press: KeyPress, for blockID: UUID) -> KeyPress.Result {
        switch press.key {
        case .delete, .deleteForward:
            remove(blockID)
            return .handled
        case .leftArrow where press.modifiers.contains(.command):
            moveEarlier(blockID)
            return .handled
        case .rightArrow where press.modifiers.contains(.command):
            moveLater(blockID)
            return .handled
        case .return, .space:
            optionsBlockID = blockID
            return .handled
        default:
            return .ignored
        }
    }

    private func moveEarlier(_ blockID: UUID) {
        withAnimation(animation) { session.moveEarlier(blockID) }
        keepFocus(on: blockID)
    }

    private func moveLater(_ blockID: UUID) {
        withAnimation(animation) { session.moveLater(blockID) }
        keepFocus(on: blockID)
    }

    /// Removes a block and moves focus to the one that took its place, so a keyboard or
    /// VoiceOver user is not dropped back at the top of the screen.
    private func remove(_ blockID: UUID) {
        let removedIndex = session.arrangement.index(of: blockID)
        let hadKeyboardFocus = focusedBlockID == blockID
        if optionsBlockID == blockID { optionsBlockID = nil }
        withAnimation(animation) { session.remove(blockID) }

        let remaining = session.arrangement.blocks
        guard let removedIndex, !remaining.isEmpty else { return }
        let neighbour = remaining[min(removedIndex, remaining.count - 1)].id
        if hadKeyboardFocus { focusedBlockID = neighbour }
        accessibilityFocusedBlockID = neighbour
    }

    private func keepFocus(on blockID: UUID) {
        if focusedBlockID != nil { focusedBlockID = blockID }
        accessibilityFocusedBlockID = blockID
    }
}

// MARK: - Category colours

/// One restrained hue per kind of information, shared by placed blocks and the tray,
/// used as ink for the label and as a flat tint behind it. It only supplements the
/// label and icon every block also carries.
enum ArrNamingBlockCategory: Hashable {
    /// Who: the show or movie.
    case subject
    /// Which one: episode, season, absolute number or air date.
    case numbering
    case title
    /// Quality and year.
    case quality
    /// Media information, release group, IDs and the rest of the catalog.
    case technical
    /// Custom tokens, typed text and folder breaks, which have no friendly kind.
    case custom

    init(_ block: ArrNamingBlock, in catalog: ArrNamingBlockCatalog) {
        guard let definition = catalog.definition(for: block) else {
            self = .custom
            return
        }
        self.init(definition)
    }

    init(_ definition: ArrNamingBlockDefinition) {
        switch definition.id {
        case "showName", "movieName": self = .subject
        case "episodeNumber", "absoluteNumber", "airDate", "seasonNumber": self = .numbering
        case "episodeTitle": self = .title
        case "quality", "year": self = .quality
        case "videoInfo", "releaseGroup": self = .technical
        default:
            switch definition.group {
            case "Series", "Movie": self = .subject
            case "Episode", "Season": self = .numbering
            case "Quality": self = .quality
            default: self = .technical
            }
        }
    }

    /// A flat wash of the category's system hue, which adapts to light and dark on its
    /// own and stays vivid where a wash of the darker ink would read as grey.
    var tint: Color {
        switch self {
        case .subject: Color.blue.opacity(0.2)
        case .numbering: Color.purple.opacity(0.2)
        case .title: Color.green.opacity(0.2)
        case .quality: Color.orange.opacity(0.22)
        case .technical: Color.teal.opacity(0.2)
        case .custom: Color.secondary.opacity(0.1)
        }
    }

    /// Light and dark inks from the approved mockup, legible on their own tint in both.
    var ink: Color {
        switch self {
        case .subject: Self.subjectInk
        case .numbering: Self.numberingInk
        case .title: Self.titleInk
        case .quality: Self.qualityInk
        case .technical: Self.technicalInk
        case .custom: Color.primary
        }
    }

    private static let subjectInk = Color(light: 0x225572, dark: 0xA8DCF8)
    private static let numberingInk = Color(light: 0x63459B, dark: 0xD0BDF5)
    private static let titleInk = Color(light: 0x316B4A, dark: 0xB5E2C8)
    private static let qualityInk = Color(light: 0x885F1D, dark: 0xF2D39A)
    private static let technicalInk = Color(light: 0x556173, dark: 0xCED4DF)
}

private extension Color {
    /// A colour with separate light and dark values, resolved by the system as the
    /// appearance changes.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? Self.platformColor(dark) : Self.platformColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? Self.platformColor(dark) : Self.platformColor(light)
        })
        #endif
    }

    #if os(macOS)
    nonisolated static func platformColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
    #else
    nonisolated static func platformColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
    #endif
}

// MARK: - Block tile

/// One block, on the board or in the tray: a large, flat tile whose plain-language
/// label leads and whose concrete sample sits underneath. Colour only supplements the label
/// and icon; custom, text and subfolder blocks also differ by title and border style.
struct ArrNamingBlockChip: View {
    enum Style {
        case element
        case custom
        case text
        case folderBreak

        init(_ block: ArrNamingBlock) {
            switch block.kind {
            case .element: self = .element
            case .unknownToken: self = .custom
            case .text: self = block.isFolderBreak ? .folderBreak : .text
            }
        }
    }

    /// What the corner mark offers: a grip on the board, an add on the tray.
    enum Affordance {
        case grip
        case add
    }

    static let cornerRadius = DesignConstants.CornerRadius.medium

    let title: String
    let sample: String
    let systemImage: String
    let style: Style
    let category: ArrNamingBlockCategory
    var affordance: Affordance = .grip
    fileprivate var isPlaceholder = false
    fileprivate var placeholderAccent: Color = .accentColor

    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var minWidth: CGFloat = 115
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
    }

    /// The board's insertion slot: the dragged block's own footprint, drawn as a dashed
    /// "Drop here" so it cannot be mistaken for a real block.
    fileprivate func placeholder(_ isPlaceholder: Bool, accent: Color) -> Self {
        var copy = self
        copy.isPlaceholder = isPlaceholder
        copy.placeholderAccent = accent
        return copy
    }

    var body: some View {
        content
            .opacity(isPlaceholder ? 0 : 1)
            .padding(.leading, 14)
            .padding(.trailing, 30)
            .padding(.vertical, 12)
            .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if !isPlaceholder {
                    Image(systemName: affordance == .grip ? "line.3.horizontal" : "plus")
                        .font(.caption)
                        .foregroundStyle(category.ink.opacity(0.55))
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isPlaceholder {
                    Text("Drop here")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(placeholderAccent)
                }
            }
            .background { surface }
            .overlay { border }
            .contentShape(shape)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: systemImage)
                    .font(.caption)
            }
            .labelStyle(ArrNamingBlockLabelStyle())

            Text(sample.isEmpty ? " " : sample)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(category.ink)
        // Labels and examples wrap at full size rather than truncating or shrinking.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var surface: some View {
        if isPlaceholder {
            shape.fill(placeholderAccent.opacity(0.1))
        } else {
            shape.fill(category.tint)
        }
    }

    @ViewBuilder
    private var border: some View {
        if isPlaceholder {
            shape.strokeBorder(placeholderAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        } else {
            switch style {
            case .element:
                if contrast == .increased {
                    shape.strokeBorder(category.ink.opacity(0.6), lineWidth: 1)
                }
            case .custom:
                shape.strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            case .text:
                shape.strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.5, 4]))
            case .folderBreak:
                shape.strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

/// Icon and label on one baseline, with the icon kept small beside the label.
private struct ArrNamingBlockLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Flow layout

/// Leading-aligned rows that wrap. Rows are top-aligned, which the drop index relies
/// on to tell rows apart. Blocks in a row grow to share its spare width, up to
/// `maxStretchedWidth`, so a row reads as a set of even pieces rather than ragged
/// tags; a block wider than the board is offered the board's width.
struct ArrNamingBlockFlowLayout: Layout {
    var spacing: CGFloat = 8
    var maxStretchedWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let arrangement = arrange(subviews, within: limit ?? .infinity)
        return CGSize(width: limit ?? arrangement.size.width, height: arrangement.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, within: bounds.width)
        for (subview, placement) in zip(subviews, arrangement.placements) {
            subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, within limit: CGFloat) -> (placements: [CGRect], size: CGSize) {
        // Rows of natural widths first.
        var rows: [[(index: Int, width: CGFloat)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var width = subview.sizeThatFits(.unspecified).width
            if width > limit {
                width = min(subview.sizeThatFits(ProposedViewSize(width: limit, height: nil)).width, limit)
            }
            if x > 0, x + width > limit {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, width))
            x += width + spacing
        }

        var placements = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for row in rows where !row.isEmpty {
            let used = row.reduce(0) { $0 + $1.width } + spacing * CGFloat(row.count - 1)
            let share = limit.isFinite ? max(limit - used, 0) / CGFloat(row.count) : 0
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for item in row {
                let cap = max(item.width, maxStretchedWidth ?? item.width)
                let width = min(item.width + share, cap)
                let height = subviews[item.index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                placements[item.index] = CGRect(x: x, y: y, width: width, height: height)
                x += width + spacing
                rowHeight = max(rowHeight, height)
            }
            // Pieces in one row share a height, like the tiles they are.
            for item in row {
                placements[item.index].size.height = rowHeight
            }
            widest = max(widest, x - spacing)
            y += rowHeight + spacing
        }
        return (placements, CGSize(width: widest, height: max(y - spacing, 0)))
    }
}

/// Equal-width columns filled left to right, top to bottom, so reading order and drag
/// order agree. Rows are top-aligned and share their tallest block's height, which the
/// drop index relies on to tell rows apart.
struct ArrNamingBlockColumnsLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth(for: subviews)
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private var columnCount: Int { max(columns, 1) }

    private func idealWidth(for subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return widest * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1)
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let columnWidth = max((width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount), 0)
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for rowStart in stride(from: 0, to: subviews.count, by: columnCount) {
            let row = rowStart..<min(rowStart + columnCount, subviews.count)
            let height = row
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            for index in row {
                let x = CGFloat(index - rowStart) * (columnWidth + spacing)
                frames.append(CGRect(x: x, y: y, width: columnWidth, height: height))
            }
            y += height + spacing
        }
        return (frames, max(y - spacing, 0))
    }
}

// MARK: - Dropping

/// Where a drop would land, from chip frames as they are currently laid out.
enum ArrNamingBlockDropIndex {
    nonisolated static let coordinateSpace = "naming.blocks.board"

    /// The insertion index among blocks that stay put, as `ArrNamingEditorSession`
    /// expects: the placeholder (the dragged block, or the tray block standing in for
    /// one) is a slot, not a block, so it is never counted.
    ///
    /// The row is the one containing the pointer, or the nearest; within it the pointer
    /// goes before the first block whose midpoint it has not passed. A single column
    /// reads top to bottom instead, so there the pointer goes before the first block
    /// whose vertical midpoint it has not passed. Because the placeholder is not
    /// counted, hovering over it returns its own position, and a neighbour that slides
    /// aside after a change moves its midpoint away from the pointer - so a proposal
    /// does not flip back under a still pointer.
    static func insertionIndex(
        at location: CGPoint,
        in items: [(id: UUID, frame: CGRect)],
        placeholderID: UUID?,
        singleColumn: Bool = false
    ) -> Int {
        guard !items.isEmpty else { return 0 }

        if singleColumn {
            let position = items.firstIndex { location.y < $0.frame.midY } ?? items.count
            return items[..<position].count { $0.id != placeholderID }
        }

        var rows: [(range: Range<Int>, minY: CGFloat, maxY: CGFloat)] = []
        for (offset, item) in items.enumerated() {
            if let last = rows.last, abs(item.frame.minY - last.minY) < 1 {
                rows[rows.count - 1] = (last.range.lowerBound..<(offset + 1), last.minY, max(last.maxY, item.frame.maxY))
            } else {
                rows.append((offset..<(offset + 1), item.frame.minY, item.frame.maxY))
            }
        }

        func distance(to row: (range: Range<Int>, minY: CGFloat, maxY: CGFloat)) -> CGFloat {
            if location.y < row.minY { return row.minY - location.y }
            if location.y > row.maxY { return location.y - row.maxY }
            return 0
        }
        let row = rows.min { distance(to: $0) < distance(to: $1) } ?? rows[0]
        let position = row.range.first { location.x < items[$0].frame.midX } ?? row.range.upperBound
        return items[..<position].count { $0.id != placeholderID }
    }
}

/// Drag state for one board. Only `hoveringPayload` affects drawing; the rest is
/// bookkeeping read inside drop callbacks, so it does not invalidate the view.
@MainActor
@Observable
final class ArrNamingBlockDropState {
    private(set) var hoveringPayload: ArrNamingBlockDragPayload?

    @ObservationIgnored var frames: [UUID: CGRect] = [:]
    /// Whether the board is drawing one column, which changes how a drop is placed.
    @ObservationIgnored var isSingleColumn = false
    @ObservationIgnored fileprivate(set) var proposedIndex: Int?
    @ObservationIgnored fileprivate var lastChangeLocation: CGPoint?
    @ObservationIgnored fileprivate var isCompletingDrop = false

    var isHovering: Bool { hoveringPayload != nil }

    /// The block drawn as the insertion placeholder while a drag hovers here.
    func placeholderID(in session: ArrNamingEditorSession) -> UUID? {
        guard let hoveringPayload else { return nil }
        switch hoveringPayload.source {
        case .placed(let blockID):
            return blockID
        case .tray:
            return session.displayedArrangement.blocks.first { session.arrangement.index(of: $0.id) == nil }?.id
        }
    }

    fileprivate func beginHover(_ payload: ArrNamingBlockDragPayload) {
        hoveringPayload = payload
        proposedIndex = nil
        lastChangeLocation = nil
    }

    func reset() {
        hoveringPayload = nil
        proposedIndex = nil
        lastChangeLocation = nil
        isCompletingDrop = false
    }
}

/// Drives `ArrNamingEditorSession`'s proposal from the pointer. `propose` records
/// nothing; only the drop commits, as a single undo step.
struct ArrNamingBlockDropDelegate: DropDelegate {
    let session: ArrNamingEditorSession
    let state: ArrNamingBlockDropState
    let animation: Animation?

    /// How far the pointer must move after a proposal before another is considered. A
    /// proposal re-lays out the board, and at a row wrap that can put a different
    /// midpoint under a pointer that has not moved (macOS repeats updates while still).
    private static let movementBeforeChange: CGFloat = 6

    private var payload: ArrNamingBlockDragPayload? {
        guard let current = ArrNamingBlockDragTracker.shared.current, session.accepts(current) else { return nil }
        return current
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.json]) && payload != nil
    }

    func dropEntered(info: DropInfo) {
        updateProposal(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let payload else { return DropProposal(operation: .forbidden) }
        updateProposal(info)
        if case .placed = payload.source {
            return DropProposal(operation: .move)
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        // Some platforms report an exit after a successful drop; that drop owns cleanup.
        guard !state.isCompletingDrop else { return }
        withAnimation(animation) { session.cancelProposal() }
        state.reset()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload, let provider = info.itemProviders(for: [.json]).first else {
            withAnimation(animation) { session.cancelProposal() }
            state.reset()
            return false
        }
        let index = state.proposedIndex ?? insertionIndex(at: info.location, for: payload)
        state.isCompletingDrop = true

        // The proposal stays on screen, already showing the result, while the payload
        // loads; committing then changes nothing visible.
        let session = session
        let state = state
        let animation = animation
        _ = provider.loadTransferable(type: ArrNamingBlockDragPayload.self) { result in
            Task { @MainActor in
                if let decoded = try? result.get(), decoded == payload {
                    withAnimation(animation) { _ = session.drop(decoded, at: index) }
                } else {
                    withAnimation(animation) { session.cancelProposal() }
                }
                state.reset()
                ArrNamingBlockDragTracker.shared.end(payload)
            }
        }
        return true
    }

    private func updateProposal(_ info: DropInfo) {
        guard let payload else { return }
        if state.hoveringPayload != payload {
            state.beginHover(payload)
        }

        let location = info.location
        if state.proposedIndex != nil,
           let placeholderID = state.placeholderID(in: session),
           let frame = state.frames[placeholderID],
           frame.contains(location) {
            return
        }

        let index = insertionIndex(at: location, for: payload)
        guard index != state.proposedIndex else { return }
        if let last = state.lastChangeLocation,
           hypot(location.x - last.x, location.y - last.y) < Self.movementBeforeChange {
            return
        }

        state.proposedIndex = index
        state.lastChangeLocation = location
        withAnimation(animation) { session.propose(payload, at: index) }
    }

    private func insertionIndex(at location: CGPoint, for payload: ArrNamingBlockDragPayload) -> Int {
        let items = session.displayedArrangement.blocks.compactMap { block in
            state.frames[block.id].map { (id: block.id, frame: $0) }
        }
        return ArrNamingBlockDropIndex.insertionIndex(
            at: location,
            in: items,
            placeholderID: state.placeholderID(in: session),
            singleColumn: state.isSingleColumn
        )
    }
}

#if DEBUG
#Preview("Drag feedback") {
    let session = ArrNamingEditorSession(
        scope: .init(instanceID: UUID(), target: .sonarr(.standardEpisode)),
        serverName: "Sonarr",
        serverFormat: "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full}"
    )
    let catalog = session.catalog
    let accent = ArrServiceType.sonarr.serviceIdentity.brandColor
    let tiles = session.arrangement.blocks.map { block in
        ArrNamingBlockChip(
            title: catalog.title(for: block),
            sample: catalog.sample(for: block),
            systemImage: catalog.systemImage(for: block),
            style: ArrNamingBlockChip.Style(block),
            category: ArrNamingBlockCategory(block, in: catalog)
        )
    }

    VStack(alignment: .leading, spacing: 28) {
        Text("Resting blocks and the insertion slot")
            .font(.headline)
        ArrNamingBlockColumnsLayout(columns: 2, spacing: DesignConstants.Spacing.iconText) {
            tiles[0]
            tiles[1].placeholder(true, accent: accent)
            tiles[2]
            tiles[3]
        }
        .padding(14)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
        .overlay {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }
    }
    .padding(24)
    .frame(maxWidth: 520)
}
#endif
