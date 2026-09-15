import SwiftUI

/// Builds a naming format from friendly blocks, with a live preview of the result.
///
/// Everything edits `session`'s local draft; nothing reaches the server until Save is
/// confirmed. Pushed on compact widths, it guards Back while the draft has edits; in
/// a detail pane it never dismisses, and the list column guards selection changes.
struct ArrNamingBuilderView: View {
    let session: ArrNamingEditorSession
    /// Writes the format to the session's server and returns the value it accepted,
    /// or nil when it refused.
    let performSave: (String) async -> String?

    @State private var availableWidth: CGFloat = 0
    @State private var isConfirmingSave = false
    @State private var isConfirmingDiscard = false
    @State private var isShowingUnsavedChanges = false
    @State private var isSubmitting = false
    @State private var isEditing = false
    @State private var textModeMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isDetailPane) private var isDetailPane
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? { reduceMotion ? nil : .snappy }

    /// The tray sits beside the builder only while the builder keeps a useful width.
    private var placesTrayAlongside: Bool {
        availableWidth >= 700 && !dynamicTypeSize.isAccessibilitySize
    }

    /// One block design everywhere; only spacing adapts to the room available.
    private var density: ArrNamingBlockDensity {
        availableWidth > 0 && availableWidth < 500 ? .compact : .regular
    }

    private var trayColumns: Int {
        if placesTrayAlongside { return 1 }
        return density == .compact ? 2 : 3
    }

    private var hidesBackButton: Bool {
        !isDetailPane && (session.isDirty || session.isSaving)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density == .compact ? 18 : 24) {
                previewCard

                Group {
                    switch session.mode {
                    case .blocks:
                        blocksContent
                    case .text:
                        textContent
                    }
                }
                .disabled(!isEditing || session.isSaving || isSubmitting)
            }
            .padding(.horizontal, density == .compact ? 16 : 24)
            .padding(.vertical, density == .compact ? 16 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Kept off the scroll view, which hosts the unsaved-changes question, so
            // each confirmation dialog has a presentation host of its own.
            .confirmationDialog("Discard Changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive, action: discardChanges)
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your changes to \(session.target.title) on \(session.serverName) will be lost.")
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(animation, value: session.mode)
        .navigationTitle(session.target.title)
        .navigationSubtitle(session.serverName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(hidesBackButton)
        .trawlEditingGuard(isEditing: isEditing, isSaving: session.isSaving || isSubmitting)
        .onAppear { if session.isDirty { isEditing = true } }
        .toolbar { toolbarContent }
        .alert("Save Format?", isPresented: $isConfirmingSave) {
            Button("Save", action: confirmSave)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply this naming format to \(session.serverName)?")
        }
        .namingUnsavedChangesDialog(
            for: session,
            isPresented: $isShowingUnsavedChanges,
            onSave: {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task {
                    let saved = await session.save(using: performSave)
                    isSubmitting = false
                    if saved { dismiss() }
                }
            },
            onDiscard: {
                session.discardChanges()
                dismiss()
            }
        )
    }

    // MARK: Preview

    private var previewCard: some View {
        let preview = session.preview

        return VStack(alignment: .leading, spacing: 8) {
            Label(
                session.catalog.isFolderFormat ? "Your folder will look like this" : "Your file will look like this",
                systemImage: session.catalog.isFolderFormat ? "folder" : "film"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Group {
                if preview.text.isEmpty {
                    Text(ArrNamingFormatPreview.emptyText)
                        .foregroundStyle(.secondary)
                } else {
                    // The extension is illustrative; it is never part of the saved format.
                    let fileExtension = session.catalog.previewFileExtension ?? ""
                    Text("\(Text(verbatim: preview.text))\(Text(verbatim: fileExtension).foregroundStyle(.secondary))")
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("naming.preview")

            if !preview.unresolvedTokens.isEmpty {
                previewNote("Preview can't show \(Self.list(preview.unresolvedTokens)). The server still fills these in.", systemImage: "eye.slash")
            }
            if !preview.approximatedTokens.isEmpty {
                previewNote("Preview can't apply the options on \(Self.list(preview.approximatedTokens)), so these are approximate.", systemImage: "info.circle")
            }
            if let issue = session.validationIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(session.validationBlocksSave ? Color.orange : Color.secondary)
            }
            if session.saveState == .failed {
                Label("\(session.serverName) didn't accept this format. Your changes are still here, so you can try again.", systemImage: "exclamationmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
        .overlay {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }

    private func previewNote(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private static func list(_ tokens: [String]) -> String {
        var seen: Set<String> = []
        return tokens.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    // MARK: Blocks

    @ViewBuilder
    private var blocksContent: some View {
        if placesTrayAlongside {
            HStack(alignment: .top, spacing: 20) {
                builderColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ArrNamingBlockTray(session: session, columns: trayColumns, isAlongside: true)
                    .frame(width: 230)
            }
        } else {
            builderColumn
            Divider()
            ArrNamingBlockTray(session: session, columns: trayColumns)
        }
    }

    private var builderColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arrange your blocks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                undoRedoButtons
            }
            ArrNamingBlockBoard(session: session, density: density)

            separatorSection
        }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                withAnimation(animation) { session.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!session.canUndo)
            .help("Undo")

            Button("Redo", systemImage: "arrow.uturn.forward") {
                withAnimation(animation) { session.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!session.canRedo)
            .help("Redo")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
    }

    // MARK: Separator

    private var separatorSection: some View {
        let state = session.separatorState

        return VStack(alignment: .leading, spacing: 8) {
            Text("Join with")
                .font(.subheadline)

            TrawlSegmentBar(
                "Join with",
                selection: separatorSelection,
                items: separatorItems(for: state),
                horizontalPadding: 0
            )
            .disabled(state == ArrNamingSeparatorState.none || session.isSaving)
            .accessibilityIdentifier("naming.separator")

            switch state {
            case .custom:
                Text("Blocks are joined in more than one way. Choosing a style replaces those joins, and you can undo it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .none:
                Text("Add another block to choose what goes between blocks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .uniform:
                EmptyView()
            }
        }
    }

    /// The offered styles, plus Custom while the format joins blocks in a way none of
    /// them spell. Custom only reflects that state; choosing it changes nothing.
    private func separatorItems(for state: ArrNamingSeparatorState) -> [TrawlSegmentBarItem<ArrNamingSeparatorStyle?>] {
        var items = ArrNamingSeparatorStyle.allCases.map { TrawlSegmentBarItem($0.title, value: Optional($0)) }
        if state == .custom {
            items.append(TrawlSegmentBarItem("Custom", value: nil))
        }
        return items
    }

    private var separatorSelection: Binding<ArrNamingSeparatorStyle?> {
        Binding {
            if case .uniform(let style) = session.separatorState { style } else { nil }
        } set: { style in
            guard let style else { return }
            withAnimation(animation) { session.applySeparator(style) }
        }
    }

    // MARK: Text

    @ViewBuilder
    private var textContent: some View {
        @Bindable var session = session

        VStack(alignment: .leading, spacing: 12) {
            Text("Format")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Naming format", text: $session.textDraft, axis: .vertical)
                // A vertical field only exposes its title as a placeholder, so once it
                // holds a format nothing names it; this keeps it findable.
                .accessibilityIdentifier("Naming format")
                .lineLimit(3...8)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
                .disabled(session.isSaving)

            if let textModeMessage {
                Label(textModeMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Button("Use Blocks", systemImage: "square.grid.2x2", action: useBlocks)
                .buttonStyle(.bordered)
                .disabled(session.isSaving)
        }
        .onChange(of: session.textDraft) {
            textModeMessage = nil
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if hidesBackButton {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") {
                    isShowingUnsavedChanges = true
                }
                .disabled(session.isSaving)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            moreMenu.disabled(!isEditing || session.isSaving || isSubmitting)
        }

        TrawlEditToolbar(isEditing: $isEditing, isSaving: session.isSaving || isSubmitting,
            canSave: session.canSave,
            onCancel: { session.discardChanges(); textModeMessage = nil },
            onSave: { isConfirmingSave = true })
    }

    private var moreMenu: some View {
        Menu {
            switch session.mode {
            case .blocks:
                Button("Edit as Text", systemImage: "curlybraces", action: editAsText)
            case .text:
                Button("Use Blocks", systemImage: "square.grid.2x2", action: useBlocks)
            }

            if !session.target.presets.isEmpty {
                Menu("Start Simple", systemImage: "wand.and.stars") {
                    ForEach(session.target.presets) { preset in
                        Button {
                            withAnimation(animation) { session.replaceFormat(with: preset.format) }
                        } label: {
                            Text(preset.title)
                            Text(session.catalog.render(preset.format).text)
                        }
                    }
                }
            }

            if session.isDirty {
                Divider()
                Button("Discard Changes", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
                    isConfirmingDiscard = true
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .disabled(session.isSaving)
    }

    // MARK: Actions

    private func confirmSave() {
        guard session.canSave, !isSubmitting else { return }
        isSubmitting = true
        Task {
            let saved = await session.save(using: performSave)
            isSubmitting = false
            if saved { isEditing = false }
        }
    }

    private func editAsText() {
        textModeMessage = nil
        session.editAsText()
    }

    private func useBlocks() {
        if session.useBlocks() {
            textModeMessage = nil
        } else {
            textModeMessage = "Part of this format can't be shown exactly as blocks, so it stays as text. Nothing was changed."
        }
    }

    private func discardChanges() {
        textModeMessage = nil
        withAnimation(animation) { session.discardChanges() }
    }
}

#if DEBUG
private extension ArrNamingEditorSession {
    static func preview(_ target: ArrNamingFormatEditorTarget, _ format: String) -> ArrNamingEditorSession {
        ArrNamingEditorSession(
            scope: .init(instanceID: UUID(), target: target),
            serverName: target.serviceType == .radarr ? "Radarr" : "Sonarr 4K",
            serverFormat: format
        )
    }
}

private let standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full}"

#Preview("Narrow iPhone", traits: .fixedLayout(width: 360, height: 800)) {
    NavigationStack {
        ArrNamingBuilderView(session: .preview(.sonarr(.standardEpisode), standardEpisodeFormat), performSave: { $0 })
    }
}

#Preview("Dark") {
    NavigationStack {
        ArrNamingBuilderView(session: .preview(.sonarr(.standardEpisode), standardEpisodeFormat), performSave: { $0 })
    }
    .preferredColorScheme(.dark)
}

#Preview("Accessibility Text") {
    NavigationStack {
        ArrNamingBuilderView(session: .preview(.sonarr(.standardEpisode), standardEpisodeFormat), performSave: { $0 })
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Empty Format") {
    NavigationStack {
        ArrNamingBuilderView(session: .preview(.sonarr(.standardEpisode), ""), performSave: { $0 })
    }
}

#Preview("Custom Format") {
    NavigationStack {
        ArrNamingBuilderView(
            session: .preview(.sonarr(.standardEpisode), "{Series Title} [{Custom Thing}] {{literal}} {Episode Title:30}{-Release Group}"),
            performSave: { $0 }
        )
    }
}

#Preview("Radarr Movie File") {
    NavigationStack {
        ArrNamingBuilderView(
            session: .preview(.radarr(.standardMovie), "{Movie Title} ({Release Year}) {Quality Full}"),
            performSave: { $0 }
        )
    }
}

#Preview("Folder With Subfolder") {
    NavigationStack {
        ArrNamingBuilderView(
            session: .preview(.sonarr(.seriesFolder), "{Series TitleFirstCharacter}/{Series TitleYear}"),
            performSave: { $0 }
        )
    }
}

#Preview("Detail Pane") {
    NavigationStack {
        ArrNamingBuilderView(session: .preview(.sonarr(.standardEpisode), standardEpisodeFormat), performSave: { $0 })
    }
    .environment(\.isDetailPane, true)
}
#endif
