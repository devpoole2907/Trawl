import SwiftUI

/// The blocks a format can use, drawn as the same pieces the board holds. Common ones
/// are shown first; the rest of the field's catalog stays one disclosure away. Tap to
/// append, or drag onto the board to place.
struct ArrNamingBlockTray: View {
    let session: ArrNamingEditorSession
    /// 1 beside the builder, 2 on a phone, 3 where the tray spans a wider screen.
    var columns = 2
    var isAlongside = false

    @State private var showsMoreBlocks = false
    @State private var isAddingText = false
    @State private var newText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var catalog: ArrNamingBlockCatalog { session.catalog }
    private var animation: Animation? { reduceMotion ? nil : .snappy }

    private var gridColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : max(columns, 1)
        return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    header
                    Spacer(minLength: 8)
                    hint
                }
                VStack(alignment: .leading, spacing: 2) {
                    header
                    hint
                }
            }

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                ForEach(catalog.commonDefinitions) { definition in
                    item(for: definition)
                }
                textItem
            }

            if !catalog.additionalGroups.isEmpty {
                DisclosureGroup("More blocks", isExpanded: $showsMoreBlocks) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(catalog.additionalGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                                    ForEach(group.definitions) { definition in
                                        item(for: definition)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .accessibilityIdentifier("naming.tray.more")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(session.isSaving)
        .alert("Add Text", isPresented: $isAddingText) {
            TextField("Words", text: $newText)
                .autocorrectionDisabled()
            Button("Add", action: addText)
            Button("Cancel", role: .cancel) { newText = "" }
        } message: {
            Text(catalog.isFolderFormat
                 ? "These words appear in every folder name exactly as you type them."
                 : "These words appear in every filename exactly as you type them.")
        }
    }

    private var header: some View {
        Text("Add a block")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private var hint: some View {
        Text(isAlongside ? "Drag across, or tap +" : "Drag it up, or tap +")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func item(for definition: ArrNamingBlockDefinition) -> some View {
        let sample = definition.variants.first.map { catalog.sample(forSpelling: $0.spelling) } ?? ""
        // A definition always has a variant; the fallback is refused by `accepts`.
        let payload = session.trayPayload(for: definition)
            ?? ArrNamingBlockDragPayload(sessionID: session.id, source: .tray(definitionID: definition.id, variant: ""))
        let tile = ArrNamingBlockChip(
            title: definition.title,
            sample: sample,
            systemImage: definition.systemImage,
            style: .element,
            category: ArrNamingBlockCategory(definition),
            affordance: .add
        )

        return Button {
            withAnimation(animation) { session.append(definition) }
        } label: {
            tile
        }
        .buttonStyle(.plain)
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: ArrNamingBlockChip.cornerRadius))
        .draggable(ArrNamingBlockDragTracker.shared.begin(payload))
        .accessibilityLabel("Add \(definition.title)")
        .accessibilityHint(sample.isEmpty ? "" : "Adds \(sample) to the end")
        .accessibilityIdentifier("naming.tray.\(definition.id)")
    }

    private var textItem: some View {
        Button {
            newText = ""
            isAddingText = true
        } label: {
            ArrNamingBlockChip(
                title: "Text",
                sample: "Your own words",
                systemImage: "textformat",
                style: .text,
                category: .custom,
                affordance: .add
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Text")
        .accessibilityHint("Asks for words to add to the end")
        .accessibilityIdentifier("naming.tray.text")
    }

    private func addText() {
        let words = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        newText = ""
        guard !words.isEmpty else { return }
        withAnimation(animation) { _ = session.insertText(words) }
    }
}
