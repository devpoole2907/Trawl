import SwiftUI

struct ProwlarrAddIndexerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: ProwlarrViewModel
    private let loadsSchemaOnAppear: Bool

    @State private var searchText = ""
    /// nil = every protocol.
    @State private var protocolFilter: IndexerListSection?

    init(viewModel: ProwlarrViewModel, loadsSchemaOnAppear: Bool = true) {
        self.viewModel = viewModel
        self.loadsSchemaOnAppear = loadsSchemaOnAppear
    }

    private var searchedSchema: [ProwlarrIndexer] {
        guard !searchText.isEmpty else { return viewModel.schemaIndexers }
        return viewModel.schemaIndexers.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.implementationName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredSchema: [ProwlarrIndexer] {
        guard let protocolFilter else { return searchedSchema }
        return searchedSchema.filter { listSection(for: $0) == protocolFilter }
    }

    /// Built from the whole schema rather than the search results, so the bar doesn't
    /// reshuffle while typing. Empty when Prowlarr only returned one protocol - a filter
    /// with a single option isn't worth the row.
    private var protocolSegments: [TrawlSegmentBarItem<IndexerListSection?>] {
        let present = Set(viewModel.schemaIndexers.map(listSection(for:)))
        guard present.count > 1 else { return [] }
        return [TrawlSegmentBarItem("All", value: nil)]
            + IndexerListSection.allCases
                .filter { present.contains($0) }
                .map { TrawlSegmentBarItem($0.title, value: $0) }
    }

    var body: some View {
        ArrSheetShell(title: "Add Indexer") {
            Group {
                if viewModel.isLoadingSchema {
                    ProgressView("Loading indexer types…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.schemaError {
                    ServiceErrorView(
                        title: "Failed to Load",
                        message: error,
                        identity: .prowlarr,
                        onRetry: { await viewModel.reloadSchema() }
                    )
                } else if filteredSchema.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No indexers match \"\(searchText)\".")
                    )
                } else if filteredSchema.isEmpty, let protocolFilter {
                    ContentUnavailableView(
                        "No \(protocolFilter.title) Indexers",
                        systemImage: "magnifyingglass",
                        description: Text("Prowlarr returned no \(protocolFilter.title.lowercased()) indexer types.")
                    )
                } else if filteredSchema.isEmpty {
                    ContentUnavailableView(
                        "No Indexers",
                        systemImage: "magnifyingglass",
                        description: Text("No indexer schemas were returned by Prowlarr.")
                    )
                } else {
                    List {
                        // Sectioned by protocol, matching the indexer list, so finding a
                        // Usenet schema doesn't mean scrolling a flat alphabetical list.
                        ForEach(IndexerListSection.allCases) { section in
                            let schemas = filteredSchema.filter { listSection(for: $0) == section }

                            if !schemas.isEmpty {
                                Section(section.title) {
                                    ForEach(schemas, id: \.schemaListID) { schema in
                                        NavigationLink {
                                            IndexerConfigView(
                                                schema: schema,
                                                viewModel: viewModel,
                                                onAdded: { dismiss() }
                                            )
                                        } label: {
                                            schemaRow(schema)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .safeAreaInset(edge: .top) {
                if !viewModel.isLoadingSchema, viewModel.schemaError == nil, !protocolSegments.isEmpty {
                    TrawlSegmentBar(
                        "Protocol",
                        selection: Binding(
                            get: { protocolFilter },
                            set: { newValue in
                                withAnimation(.smooth(duration: 0.25)) {
                                    protocolFilter = newValue
                                }
                            }
                        ),
                        items: protocolSegments
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search indexers")
            .task {
                guard loadsSchemaOnAppear else { return }
                await viewModel.loadSchema()
                await viewModel.loadTags()
            }
        }
    }

    private func listSection(for schema: ProwlarrIndexer) -> IndexerListSection {
        switch schema.protocol {
        case .torrent: .torrent
        case .usenet: .usenet
        case nil: .other
        }
    }

    private func schemaRow(_ schema: ProwlarrIndexer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(schema.name ?? schema.implementationName ?? "Unknown")
                .font(.body)
            HStack(spacing: 6) {
                if let impl = schema.implementationName {
                    Text(impl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let proto = schema.protocol {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Label(proto.displayName, systemImage: proto.systemImage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Loaded") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        ProwlarrAddIndexerSheet(
            viewModel: ProwlarrViewModel(
                previewIndexers: [],
                schemaIndexers: ProwlarrIndexer.previewSchemaList,
                serviceManager: manager
            ),
            loadsSchemaOnAppear: false
        )
    }
}

#Preview("Empty") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        ProwlarrAddIndexerSheet(
            viewModel: ProwlarrViewModel(previewIndexers: [], schemaIndexers: [], serviceManager: manager),
            loadsSchemaOnAppear: false
        )
    }
}

#Preview("Loading") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        ProwlarrAddIndexerSheet(
            viewModel: ProwlarrViewModel(
                previewIndexers: [],
                isLoadingSchema: true,
                serviceManager: manager
            ),
            loadsSchemaOnAppear: false
        )
    }
}

#Preview("Error") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        ProwlarrAddIndexerSheet(
            viewModel: ProwlarrViewModel(
                previewIndexers: [],
                schemaError: "Prowlarr could not return indexer schemas.",
                serviceManager: manager
            ),
            loadsSchemaOnAppear: false
        )
    }
}

#Preview("Configure") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        NavigationStack {
            IndexerConfigView(
                schema: .previewSchema,
                viewModel: ProwlarrViewModel(
                    previewIndexers: [],
                    schemaIndexers: ProwlarrIndexer.previewSchemaList,
                    serviceManager: manager
                ),
                onAdded: {}
            )
        }
    }
}
#endif

// MARK: - Config View

private struct IndexerConfigView: View {
    let schema: ProwlarrIndexer
    let viewModel: ProwlarrViewModel
    let onAdded: () -> Void

    @State private var indexerName: String
    @State private var priority = 25
    @State private var showAdvanced = false
    @State private var fieldValues: [String: AnyCodableValue]
    @State private var selectedTagIDs: Set<Int> = []
    @State private var selectedAppProfileID: Int
    @State private var redirect: Bool
    @State private var isAdding = false

    /// Prowlarr rejects a usenet indexer created with redirect off, so the toggle is
    /// forced on and locked rather than letting the user build a config that 400s.
    private var redirectIsRequired: Bool { schema.protocol == .usenet }

    init(schema: ProwlarrIndexer, viewModel: ProwlarrViewModel, onAdded: @escaping () -> Void) {
        self.schema = schema
        self.viewModel = viewModel
        self.onAdded = onAdded
        _indexerName = State(initialValue: schema.name ?? "")
        _selectedAppProfileID = State(initialValue: schema.appProfileId ?? 0)
        _redirect = State(initialValue: schema.redirect ?? (schema.protocol == .usenet))
        var defaults: [String: AnyCodableValue] = [:]
        for field in schema.fields ?? [] {
            if let name = field.name, let value = field.value {
                defaults[name] = value
            }
        }
        _fieldValues = State(initialValue: defaults)
    }

    /// The app profile the new indexer will be attached to. Falls back to the
    /// view model's default when the user hasn't (or couldn't) pick one.
    private var resolvedAppProfileID: Int {
        selectedAppProfileID > 0 ? selectedAppProfileID : viewModel.defaultAppProfileID
    }

    private var visibleFields: [ProwlarrIndexerField] {
        (schema.fields ?? []).filter { field in
            guard field.hidden != "hidden", field.type != "info" else { return false }
            if !showAdvanced && field.advanced == true { return false }
            return true
        }
    }

    private var infoFields: [ProwlarrIndexerField] {
        (schema.fields ?? []).filter { $0.type == "info" && $0.hidden != "hidden" }
    }

    private var hasAdvancedFields: Bool {
        (schema.fields ?? []).contains { $0.advanced == true && $0.hidden != "hidden" && $0.type != "info" }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $indexerName)
                        .multilineTextAlignment(.trailing)
                }
                Stepper("Priority: \(priority)", value: $priority, in: 1...50)

                Toggle("Redirect", isOn: redirectIsRequired ? .constant(true) : $redirect)
                    .disabled(redirectIsRequired)

                if viewModel.appProfiles.count > 1 {
                    Picker("Sync Profile", selection: $selectedAppProfileID) {
                        ForEach(viewModel.appProfiles) { profile in
                            Text(profile.name ?? "Profile \(profile.id)").tag(profile.id)
                        }
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text(
                    redirectIsRequired
                        ? "Grabs are passed straight to the indexer rather than proxied through Prowlarr. Usenet indexers require this, so it can't be turned off."
                        : "Redirect passes grabs straight to the indexer instead of proxying them through Prowlarr."
                )
            }

            if !infoFields.isEmpty {
                Section {
                    ForEach(Array(infoFields.enumerated()), id: \.offset) { _, field in
                        if let text = field.value?.displayString {
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !visibleFields.isEmpty {
                Section("Configuration") {
                    ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                        fieldRow(for: field)
                    }
                }
            }

            if hasAdvancedFields {
                Section {
                    Toggle("Show Advanced Settings", isOn: $showAdvanced)
                }
            }

            Section("Tags") {
                if viewModel.availableTags.isEmpty {
                    Text("No Prowlarr tags available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.availableTags) { tag in
                        Toggle(
                            tag.label,
                            isOn: Binding(
                                get: { selectedTagIDs.contains(tag.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedTagIDs.insert(tag.id)
                                    } else {
                                        selectedTagIDs.remove(tag.id)
                                    }
                                }
                            )
                        )
                    }
                }

                Text("Indexers route through an indexer proxy when they share one of its tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.indexerError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(schema.name ?? "Configure")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.loadTags()
            if selectedAppProfileID <= 0 {
                selectedAppProfileID = viewModel.defaultAppProfileID
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled(indexerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(for field: ProwlarrIndexerField) -> some View {
        let label = field.label ?? field.name ?? ""
        let key = field.name ?? ""

        switch field.type {
        case "textbox":
            LabeledContent(label) {
                TextField(label, text: stringBinding(for: key))
                    .multilineTextAlignment(.trailing)
            }
        case "password":
            LabeledContent(label) {
                SecureField(label, text: stringBinding(for: key))
                    .multilineTextAlignment(.trailing)
            }
        case "checkbox":
            Toggle(label, isOn: boolBinding(for: key))
        case "number":
            LabeledContent(label) {
                TextField(label, text: numberStringBinding(for: key))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        case "select":
            if let options = field.selectOptions, !options.isEmpty {
                Picker(label, selection: intBinding(for: key)) {
                    ForEach(options) { option in
                        Text(option.name ?? "").tag(option.value?.intValue ?? 0)
                    }
                }
            }
        default:
            LabeledContent(label) {
                TextField(label, text: stringBinding(for: key))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Bindings

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let v) = fieldValues[key] { return v }
                return ""
            },
            set: { fieldValues[key] = .string($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let v) = fieldValues[key] { return v }
                return false
            },
            set: { fieldValues[key] = .bool($0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                if case .int(let v) = fieldValues[key] { return v }
                return 0
            },
            set: { fieldValues[key] = .int($0) }
        )
    }

    private func numberStringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .int(let v) = fieldValues[key] { return v == 0 ? "" : String(v) }
                if case .double(let v) = fieldValues[key] { return String(v) }
                return ""
            },
            set: { str in
                if let i = Int(str) { fieldValues[key] = .int(i) }
                else if str.isEmpty { fieldValues[key] = .int(0) }
            }
        )
    }

    // MARK: - Save

    private func save() async {
        guard !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        viewModel.clearIndexerError()

        let updatedFields = (schema.fields ?? []).map { field -> ProwlarrIndexerField in
            guard let name = field.name, let newValue = fieldValues[name] else { return field }
            return ProwlarrIndexerField(
                name: field.name,
                label: field.label,
                value: newValue,
                type: field.type,
                advanced: field.advanced,
                hidden: field.hidden,
                selectOptions: field.selectOptions
            )
        }

        let newIndexer = ProwlarrIndexer(
            id: 0,
            name: indexerName.trimmingCharacters(in: .whitespacesAndNewlines),
            enable: true,
            implementation: schema.implementation,
            implementationName: schema.implementationName,
            configContract: schema.configContract,
            infoLink: schema.infoLink,
            tags: Array(selectedTagIDs).sorted(),
            priority: priority,
            appProfileId: resolvedAppProfileID,
            shouldSearch: nil,
            supportsRss: nil,
            supportsSearch: nil,
            protocol: schema.protocol,
            redirect: redirectIsRequired ? true : redirect,
            fields: updatedFields
        )

        let didAdd = await viewModel.addIndexer(newIndexer)

        if didAdd {
            InAppNotificationCenter.shared.showSuccess(
                title: "Indexer Added",
                message: "\(indexerName.trimmingCharacters(in: .whitespacesAndNewlines)) has been added to Prowlarr."
            )
            onAdded()
        }
    }
}
