import SwiftUI

/// Full editor for a Jellyfin library's scanning, metadata and image-fetcher
/// configuration - the equivalent of the "Manage Library" settings page on the
/// Jellyfin dashboard. Loads the library's current `LibraryOptions` (returned by
/// `/Library/VirtualFolders`) plus the set of available fetchers for the content
/// type, lets the user toggle/reorder them, and writes the whole object back.
struct JellyfinLibraryOptionsView: View {
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(\.dismiss) private var dismiss

    let folder: JellyfinVirtualFolder
    let apiClient: JellyfinAPIClient
    let onSaved: () -> Void

    @State private var options: JellyfinLibraryOptions
    @State private var originalOptions: JellyfinLibraryOptions
    @State private var available: JellyfinAvailableLibraryOptions?
    @State private var isSaving = false
    #if DEBUG
    private var isPreview = false
    #endif

    init(folder: JellyfinVirtualFolder, apiClient: JellyfinAPIClient, onSaved: @escaping () -> Void = {}) {
        self.folder = folder
        self.apiClient = apiClient
        self.onSaved = onSaved
        let initial = folder.libraryOptions ?? JellyfinLibraryOptions()
        _options = State(initialValue: initial)
        _originalOptions = State(initialValue: initial)
    }

    private var isTVLike: Bool {
        folder.collectionType == "tvshows" || folder.collectionType == "mixed"
    }

    private var hasChanges: Bool { options != originalOptions }

    private var embeddedSubtitleBinding: Binding<JellyfinEmbeddedSubtitleOption> {
        Binding(
            get: { JellyfinEmbeddedSubtitleOption(rawValue: options.allowEmbeddedSubtitles) ?? .allowAll },
            set: { options.allowEmbeddedSubtitles = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            metadataLanguageSection
            scanningSection
            embeddedSection
            fetchersSection
            metadataSaversSection
            trickplaySection
            chapterImagesSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .navigationTitle("Scanning & Metadata")
        .navigationSubtitle(folder.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!hasChanges)
                }
            }
        }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            await loadAvailableOptions()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var metadataLanguageSection: some View {
        Section {
            LabeledContent("Preferred Language") {
                TextField("Preferred Language", text: $options.preferredMetadataLanguage, prompt: Text("en"))
                    .labeledContentField()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            LabeledContent("Country / Region") {
                TextField("Country / Region", text: $options.metadataCountryCode, prompt: Text("US"))
                    .labeledContentField()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
            }
            if isTVLike {
                LabeledContent("Special Season Name") {
                    TextField("Special Season Name", text: $options.seasonZeroDisplayName, prompt: Text("Specials"))
                        .labeledContentField()
                }
            }
        } header: {
            Text("Metadata")
        } footer: {
            Text("Language and country use the same codes as Jellyfin (e.g. \"en\", \"US\"). Lower-priority downloaders fill in anything the preferred one is missing.")
        }
    }

    @ViewBuilder
    private var scanningSection: some View {
        Section {
            Toggle("Refresh Metadata From the Internet", isOn: $options.enableInternetProviders)
            Toggle("Real-Time Monitoring", isOn: $options.enableRealtimeMonitor)
            if isTVLike {
                Toggle("Merge Series Across Folders", isOn: $options.enableAutomaticSeriesGrouping)
            }
            Toggle("Save Artwork Into Media Folders", isOn: $options.saveLocalMetadata)
        } header: {
            Text("Scanning")
        } footer: {
            Text("Real-time monitoring processes file changes immediately on supported filesystems. Saving artwork into media folders keeps images next to your files so future scans don't have to re-fetch them.")
        }
    }

    @ViewBuilder
    private var embeddedSection: some View {
        Section {
            Toggle("Prefer Embedded Titles Over Filenames", isOn: $options.enableEmbeddedTitles)
            if isTVLike {
                Toggle("Prefer Embedded Episode Info", isOn: $options.enableEmbeddedEpisodeInfos)
            }
            Picker("Embedded Subtitles", selection: embeddedSubtitleBinding) {
                ForEach(JellyfinEmbeddedSubtitleOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Embedded Data")
        } footer: {
            Text("Embedded subtitles are packaged inside the media container. Restricting them requires a full library refresh to take effect.")
        }
    }

    @ViewBuilder
    private var fetchersSection: some View {
        if !options.typeOptions.isEmpty {
            Section {
                ForEach($options.typeOptions) { $typeOption in
                    NavigationLink {
                        JellyfinTypeFetchersView(
                            typeOption: $typeOption,
                            available: available?.typeOptions(for: typeOption.type)
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(typeOption.displayName)
                                Text(fetcherSummary(typeOption))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: typeOption.systemImage)
                        }
                    }
                }
            } header: {
                Text("Downloaders & Image Fetchers")
            } footer: {
                Text("Choose which providers to use for each content type and drag to set their priority.")
            }
        }
    }

    @ViewBuilder
    private var metadataSaversSection: some View {
        if let savers = available?.metadataSavers, !savers.isEmpty {
            Section {
                ForEach(savers) { saver in
                    Toggle(saver.name, isOn: metadataSaverBinding(saver.name))
                }
            } header: {
                Text("Metadata Savers")
            } footer: {
                Text("File formats Jellyfin writes your metadata into (e.g. NFO sidecar files).")
            }
        }
    }

    @ViewBuilder
    private var trickplaySection: some View {
        Section {
            Toggle("Enable Trickplay Images", isOn: $options.enableTrickplayImageExtraction)
            if options.enableTrickplayImageExtraction {
                Toggle("Extract During Library Scan", isOn: $options.extractTrickplayImagesDuringLibraryScan)
                Toggle("Save Next to Media", isOn: $options.saveTrickplayWithMedia)
            }
        } header: {
            Text("Trickplay")
        } footer: {
            Text("Trickplay images power the preview thumbnails shown while scrubbing through a video.")
        }
    }

    @ViewBuilder
    private var chapterImagesSection: some View {
        Section {
            Toggle("Enable Chapter Images", isOn: $options.enableChapterImageExtraction)
            if options.enableChapterImageExtraction {
                Toggle("Extract During Library Scan", isOn: $options.extractChapterImagesDuringLibraryScan)
            }
        } header: {
            Text("Chapter Images")
        } footer: {
            Text("Chapter images let clients show graphical scene-selection menus. Extraction can be slow and disk-intensive.")
        }
    }

    // MARK: - Helpers

    private func fetcherSummary(_ typeOption: JellyfinTypeOptions) -> String {
        let meta = typeOption.metadataFetchers.count
        let img = typeOption.imageFetchers.count
        return "\(meta) metadata · \(img) image"
    }

    private func metadataSaverBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { options.metadataSavers.contains(name) },
            set: { isOn in
                if isOn {
                    if !options.metadataSavers.contains(name) { options.metadataSavers.append(name) }
                } else {
                    options.metadataSavers.removeAll { $0 == name }
                }
            }
        )
    }

    private func loadAvailableOptions() async {
        do {
            available = try await apiClient.getAvailableLibraryOptions(contentType: folder.collectionType)
        } catch {
            // Non-fatal: the toggles still work from the saved options; we just
            // can't show providers the library has never had configured.
            available = nil
        }
    }

    private func save() async {
        isSaving = true
        do {
            try await apiClient.updateLibraryOptions(id: folder.itemId, options: options)
            originalOptions = options
            inAppNotificationCenter.showSuccess(title: "Library Updated", message: folder.name)
            onSaved()
            dismiss()
        } catch {
            inAppNotificationCenter.showError(title: "Update Failed", message: error.localizedDescription)
        }
        isSaving = false
    }
}

// MARK: - Per-type fetcher hub

/// Lists the two fetcher editors (metadata downloaders and image fetchers) for a
/// single content type. Bindings flow straight back into the parent library
/// options so a single Save at the top persists everything.
private struct JellyfinTypeFetchersView: View {
    @Binding var typeOption: JellyfinTypeOptions
    let available: JellyfinAvailableTypeOptions?

    var body: some View {
        // A `Form`, so the Mac gets the grouped styling the rest of this sheet has.
        // `formStyle` reaches `Form` only, so as a `List` this child drew flat inside
        // a grouped parent.
        Form {
            Section {
                NavigationLink {
                    JellyfinFetcherOrderEditor(
                        title: "Metadata Downloaders",
                        footer: "Lower-priority downloaders only fill in information the higher ones are missing.",
                        available: available?.metadataFetchers ?? [],
                        enabled: $typeOption.metadataFetchers,
                        order: $typeOption.metadataFetcherOrder
                    )
                } label: {
                    summaryRow(
                        title: "Metadata Downloaders",
                        systemImage: "text.book.closed",
                        count: typeOption.metadataFetchers.count
                    )
                }

                NavigationLink {
                    JellyfinFetcherOrderEditor(
                        title: "Image Fetchers",
                        footer: "Jellyfin tries enabled fetchers top-to-bottom. The Screen Grabber / Embedded Image Extractor make good last-resort fallbacks.",
                        available: available?.imageFetchers ?? [],
                        enabled: $typeOption.imageFetchers,
                        order: $typeOption.imageFetcherOrder
                    )
                } label: {
                    summaryRow(
                        title: "Image Fetchers",
                        systemImage: "photo.stack",
                        count: typeOption.imageFetchers.count
                    )
                }
            }
        }
        .serviceSettingsFormStyle()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .navigationTitle(typeOption.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func summaryRow(title: String, systemImage: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count) on")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

// MARK: - Fetcher enable + reorder editor

/// Reusable enable/reorder list for a single fetcher list. Enabled providers are
/// the ones checked; the row order defines priority. Always in edit mode so the
/// drag handles are visible without a separate Edit button (mirrors the Bazarr
/// language-profile editor).
private struct JellyfinFetcherOrderEditor: View {
    let title: String
    let footer: String
    let available: [JellyfinLibraryOptionInfo]
    @Binding var enabled: [String]
    @Binding var order: [String]

    @State private var rows: [FetcherRow]

    private struct FetcherRow: Identifiable, Equatable {
        let name: String
        var isEnabled: Bool
        var id: String { name }
    }

    init(
        title: String,
        footer: String,
        available: [JellyfinLibraryOptionInfo],
        enabled: Binding<[String]>,
        order: Binding<[String]>
    ) {
        self.title = title
        self.footer = footer
        self.available = available
        _enabled = enabled
        _order = order
        _rows = State(initialValue: Self.buildRows(available: available, enabled: enabled.wrappedValue, order: order.wrappedValue))
    }

    var body: some View {
        // A `Form`, so this matches its parent and its sibling - but reordering is the
        // whole point of the screen, and the two platforms have to get there
        // differently. `onMove` needs a real list to attach to; on iOS a `Form` *is* a
        // list, so drag still works. A macOS grouped form is a layout rather than a
        // list, so the Mac gets explicit move controls instead. Converting without
        // them would have kept the styling and silently dropped the feature.
        Form {
            Section {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No Providers",
                        systemImage: "questionmark.folder",
                        description: Text("Jellyfin didn't report any providers for this type.")
                    )
                } else {
                    ForEach($rows) { $row in
                        HStack {
                            Toggle(isOn: $row.isEnabled) {
                                Text(row.name)
                            }
                            #if os(macOS)
                            Spacer()
                            moveControls(for: row)
                            #endif
                        }
                    }
                    #if os(iOS)
                    .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                    #endif
                }
            } footer: {
                Text(footer)
            }
        }
        .serviceSettingsFormStyle()
        #if os(iOS)
        // Forces the reorder handles to show without an Edit button. macOS uses the
        // move controls on each row instead; `editMode` doesn't exist there.
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: rows) { _, newRows in commit(newRows) }
    }

    private func commit(_ rows: [FetcherRow]) {
        order = rows.map(\.name)
        enabled = rows.filter(\.isEnabled).map(\.name)
    }

    /// Priority order = saved order, then any newly-available providers appended.
    /// Enabled = the saved enabled set, or each provider's server default when the
    /// library has never been configured.
    #if os(macOS)
    /// Up/down instead of drag. Priority order is what this screen edits, so it has to
    /// stay editable on a platform where the grouped form cannot host `onMove`.
    @ViewBuilder
    private func moveControls(for row: FetcherRow) -> some View {
        let index = rows.firstIndex(of: row)
        HStack(spacing: 2) {
            Button {
                if let index, index > 0 {
                    rows.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled((index ?? 0) == 0)
            .help("Move \(row.name) up")

            Button {
                if let index, index < rows.count - 1 {
                    rows.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled((index ?? 0) >= rows.count - 1)
            .help("Move \(row.name) down")
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.semibold))
    }
    #endif

    private static func buildRows(
        available: [JellyfinLibraryOptionInfo],
        enabled: [String],
        order: [String]
    ) -> [FetcherRow] {
        let availableNames = available.map(\.name)
        var names = order
        for name in availableNames where !names.contains(name) {
            names.append(name)
        }
        if !availableNames.isEmpty {
            names = names.filter { availableNames.contains($0) }
        }

        let neverConfigured = order.isEmpty && enabled.isEmpty
        let enabledSet = Set(enabled)
        let defaultsByName = Dictionary(uniqueKeysWithValues: available.map { ($0.name, $0.defaultEnabled) })

        return names.map { name in
            let isEnabled = neverConfigured ? (defaultsByName[name] ?? true) : enabledSet.contains(name)
            return FetcherRow(name: name, isEnabled: isEnabled)
        }
    }
}

#if DEBUG
extension JellyfinLibraryOptionsView {
    init(
        folder: JellyfinVirtualFolder,
        apiClient: JellyfinAPIClient = .preview(),
        available: JellyfinAvailableLibraryOptions? = nil
    ) {
        self.folder = folder
        self.apiClient = apiClient
        self.onSaved = {}
        let initial = folder.libraryOptions ?? JellyfinLibraryOptions()
        _options = State(initialValue: initial)
        _originalOptions = State(initialValue: initial)
        _available = State(initialValue: available)
        self.isPreview = true
    }
}
#endif

// MARK: - Previews

#if DEBUG
/// The models here are decode-only (a custom `init(from:)` suppresses the memberwise
/// init), so preview fixtures come in the same way the app's do - through JSON.
private enum JellyfinFetcherPreviewFixture {
    static let movieOptions: JellyfinAvailableTypeOptions = decode(
        """
        {
          "Type": "Movie",
          "MetadataFetchers": [
            { "Name": "TheMovieDb", "DefaultEnabled": true },
            { "Name": "The Open Movie Database", "DefaultEnabled": true },
            { "Name": "Embedded Metadata", "DefaultEnabled": false },
            { "Name": "Nfo", "DefaultEnabled": false }
          ],
          "ImageFetchers": [
            { "Name": "TheMovieDb", "DefaultEnabled": true },
            { "Name": "Embedded Image Extractor", "DefaultEnabled": true },
            { "Name": "Screen Grabber", "DefaultEnabled": true },
            { "Name": "The Open Movie Database", "DefaultEnabled": false }
          ]
        }
        """
    )

    static let emptyOptions: JellyfinAvailableTypeOptions = decode(
        #"{ "Type": "Book", "MetadataFetchers": [], "ImageFetchers": [] }"#
    )

    private static func decode(_ json: String) -> JellyfinAvailableTypeOptions {
        // Force-try: the literals above are fixed, so a throw here is a typo in this
        // file rather than anything a preview should try to recover from.
        try! JSONDecoder().decode(JellyfinAvailableTypeOptions.self, from: Data(json.utf8))
    }
}

#Preview("Jellyfin Metadata Downloaders") {
    @Previewable @State var enabled = ["TheMovieDb", "The Open Movie Database"]
    @Previewable @State var order = ["TheMovieDb", "The Open Movie Database", "Embedded Metadata", "Nfo"]

    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinFetcherOrderEditor(
                title: "Metadata Downloaders",
                footer: "Lower-priority downloaders only fill in information the higher ones are missing.",
                available: JellyfinFetcherPreviewFixture.movieOptions.metadataFetchers,
                enabled: $enabled,
                order: $order
            )
        }
    }
}

#Preview("Jellyfin Image Fetchers") {
    @Previewable @State var enabled = ["TheMovieDb", "Embedded Image Extractor", "Screen Grabber"]
    @Previewable @State var order: [String] = []

    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinFetcherOrderEditor(
                title: "Image Fetchers",
                footer: "Jellyfin tries enabled fetchers top-to-bottom. The Screen Grabber / Embedded Image Extractor make good last-resort fallbacks.",
                available: JellyfinFetcherPreviewFixture.movieOptions.imageFetchers,
                enabled: $enabled,
                order: $order
            )
        }
    }
}

/// A server that reports no providers for the type - the branch that draws
/// `ContentUnavailableView` instead of rows.
#Preview("Jellyfin Fetchers - No Providers") {
    @Previewable @State var enabled: [String] = []
    @Previewable @State var order: [String] = []

    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinFetcherOrderEditor(
                title: "Metadata Downloaders",
                footer: "Lower-priority downloaders only fill in information the higher ones are missing.",
                available: JellyfinFetcherPreviewFixture.emptyOptions.metadataFetchers,
                enabled: $enabled,
                order: $order
            )
        }
    }
}

#Preview("Jellyfin Type Fetchers") {
    @Previewable @State var typeOption: JellyfinTypeOptions = {
        var option = JellyfinTypeOptions()
        option.type = "Movie"
        option.metadataFetchers = ["TheMovieDb", "The Open Movie Database"]
        option.metadataFetcherOrder = ["TheMovieDb", "The Open Movie Database", "Embedded Metadata", "Nfo"]
        option.imageFetchers = ["TheMovieDb", "Embedded Image Extractor", "Screen Grabber"]
        option.imageFetcherOrder = []
        return option
    }()

    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinTypeFetchersView(
                typeOption: $typeOption,
                available: JellyfinFetcherPreviewFixture.movieOptions
            )
        }
    }
}
#endif
