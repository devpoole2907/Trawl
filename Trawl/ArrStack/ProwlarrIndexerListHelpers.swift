import SwiftUI

enum IndexerListSection: CaseIterable, Identifiable {
    case torrent
    case usenet
    case other

    var id: String { title }
    var title: String {
        switch self {
        case .torrent: "Torrent"
        case .usenet: "Usenet"
        case .other: "Other"
        }
    }

    var sortOrder: Int {
        switch self {
        case .torrent: 0
        case .usenet: 1
        case .other: 2
        }
    }
}

struct OwnedDirectIndexer: Identifiable {
    let indexer: ArrManagedIndexer
    let profile: ArrServiceProfile
    let serviceType: ArrServiceType

    var id: String { "\(serviceType.rawValue)-\(profile.id.uuidString)-\(indexer.id)" }
}

enum UnifiedIndexerDeleteTarget {
    case prowlarr(ProwlarrIndexer)
    case direct(OwnedDirectIndexer)

    var deleteMessage: String {
        switch self {
        case .prowlarr(let indexer):
            "This removes \"\(indexer.name ?? "this indexer")\" from Prowlarr."
        case .direct(let ownedIndexer):
            "This removes \"\(ownedIndexer.indexer.name ?? "this indexer")\" from \(ownedIndexer.profile.displayName)."
        }
    }
}

enum AddIndexerDestination: Identifiable {
    case prowlarr
    case direct(profileID: UUID, serviceType: ArrServiceType)

    var id: String {
        switch self {
        case .prowlarr:
            "prowlarr"
        case .direct(let profileID, let serviceType):
            "\(serviceType.rawValue)-\(profileID.uuidString)"
        }
    }
}

struct UnavailableIndexerSource: Identifiable {
    let profile: ArrServiceProfile
    let error: String

    var id: UUID { profile.id }
}

struct UnifiedIndexerListItem: Identifiable {
    enum Kind {
        case prowlarr(ProwlarrIndexer)
        case direct(OwnedDirectIndexer)
    }

    let kind: Kind
    let title: String
    let implementationName: String?
    let protocolName: String?
    let sourceLabel: String
    let barColor: Color
    let warningState: UnifiedIndexerRowWarningState
    let section: IndexerListSection

    var id: String {
        switch kind {
        case .prowlarr(let indexer):
            "prowlarr-\(indexer.id)"
        case .direct(let ownedIndexer):
            ownedIndexer.id
        }
    }

    var protocolDisplayName: String? { protocolName }
}

enum UnifiedIndexerRowWarningState {
    case connected
    case disabled
}

struct UnifiedIndexerRowView: View {
    let title: String
    let subtitle: String
    let sourceLabel: String
    let barColor: Color
    let priority: Int?
    let isEnabled: Bool
    let warningState: UnifiedIndexerRowWarningState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(statusColor)
                .frame(width: 4, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isEnabled ? .primary : .secondary)

                    if let priority, priority != 25 {
                        Text("P\(priority)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(barColor.opacity(0.9), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: warningIcon)
                .font(.caption)
                .foregroundStyle(warningIconColor)
        }
        .padding(.vertical, 4)
        .opacity(isEnabled ? 1.0 : 0.65)
    }

    private var statusColor: Color {
        isEnabled ? barColor : .secondary.opacity(0.4)
    }

    private var warningIcon: String {
        switch warningState {
        case .connected:
            "circle.fill"
        case .disabled:
            "circle"
        }
    }

    private var warningIconColor: Color {
        switch warningState {
        case .connected:
            .green
        case .disabled:
            .secondary
        }
    }
}

struct DirectIndexerSchemaPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: ArrServiceProfile
    let serviceType: ArrServiceType
    let viewModel: ArrIndexerManagementViewModel
    let linkedApplication: ProwlarrApplication?

    @State private var searchText = ""

    private var filteredSchema: [ArrManagedIndexer] {
        let schema = viewModel.schema(for: profile.id)
        guard !searchText.isEmpty else { return schema }
        return schema.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText)
                || ($0.implementationName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ArrSheetShell(title: "Add Indexer") {
            Group {
                if viewModel.isLoadingSchema(for: profile.id) {
                    ProgressView("Loading indexer types…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.schemaError(for: profile.id) {
                    ContentUnavailableView {
                        Label("Failed to Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.loadSchema(for: profile.id, serviceType: serviceType, force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if filteredSchema.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No indexers match \"\(searchText)\".")
                    )
                } else if filteredSchema.isEmpty {
                    ContentUnavailableView(
                        "No Indexers",
                        systemImage: "magnifyingglass",
                        description: Text("No indexer schemas were returned by \(profile.displayName).")
                    )
                } else {
                    List(filteredSchema, id: \.schemaListID) { schema in
                        NavigationLink {
                            DirectIndexerEditorView(
                                profile: profile,
                                serviceType: serviceType,
                                viewModel: viewModel,
                                mode: .add(schema),
                                linkedApplication: linkedApplication,
                                onSaved: { dismiss() }
                            )
                        } label: {
                            schemaRow(schema)
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .searchable(text: $searchText, prompt: "Search indexers")
            .task {
                await viewModel.loadSchema(for: profile.id, serviceType: serviceType)
            }
        }
    }

    private func schemaRow(_ schema: ArrManagedIndexer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(schema.name ?? schema.implementationName ?? "Unknown")
                .font(.body)

            HStack(spacing: 6) {
                if let implementationName = schema.implementationName {
                    Text(implementationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let protocolValue = schema.protocol {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Label(protocolValue.displayName, systemImage: protocolValue.systemImage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DirectIndexerEditorView: View {
    enum Mode {
        case add(ArrManagedIndexer)
        case edit(ArrManagedIndexer)

        var seed: ArrManagedIndexer {
            switch self {
            case .add(let schema), .edit(let schema):
                schema
            }
        }

        var buttonTitle: String {
            switch self {
            case .add:
                "Add"
            case .edit:
                "Save"
            }
        }

        var navigationTitle: String {
            switch self {
            case .add(let schema):
                schema.name ?? "Add Indexer"
            case .edit(let indexer):
                indexer.name ?? "Edit Indexer"
            }
        }
    }

    let profile: ArrServiceProfile
    let serviceType: ArrServiceType
    let viewModel: ArrIndexerManagementViewModel
    let mode: Mode
    let linkedApplication: ProwlarrApplication?
    var onSaved: (() -> Void)?

    @State private var indexerName: String
    @State private var priority: Int
    @State private var enableRss: Bool
    @State private var enableAutomaticSearch: Bool
    @State private var enableInteractiveSearch: Bool
    @State private var showAdvanced = false
    @State private var fieldValues: [String: ArrIndexerFieldValue]
    @State private var isSaving = false

    init(
        profile: ArrServiceProfile,
        serviceType: ArrServiceType,
        viewModel: ArrIndexerManagementViewModel,
        mode: Mode,
        linkedApplication: ProwlarrApplication? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.serviceType = serviceType
        self.viewModel = viewModel
        self.mode = mode
        self.linkedApplication = linkedApplication
        self.onSaved = onSaved

        let seed = mode.seed
        _indexerName = State(initialValue: seed.name ?? "")
        _priority = State(initialValue: seed.priority ?? 25)
        _enableRss = State(initialValue: seed.enableRss)
        _enableAutomaticSearch = State(initialValue: seed.enableAutomaticSearch)
        _enableInteractiveSearch = State(initialValue: seed.enableInteractiveSearch)

        var defaults: [String: ArrIndexerFieldValue] = [:]
        for field in seed.fields ?? [] {
            if let name = field.name, let value = field.value {
                defaults[name] = value
            }
        }
        _fieldValues = State(initialValue: defaults)
    }

    private var visibleFields: [ArrIndexerField] {
        (mode.seed.fields ?? []).filter { field in
            guard field.hidden != "hidden", field.type != "info" else { return false }
            if !showAdvanced && field.advanced == true {
                return false
            }
            return true
        }
    }

    private var infoFields: [ArrIndexerField] {
        (mode.seed.fields ?? []).filter { $0.type == "info" && $0.hidden != "hidden" }
    }

    private var hasAdvancedFields: Bool {
        (mode.seed.fields ?? []).contains { $0.advanced == true && $0.hidden != "hidden" && $0.type != "info" }
    }

    var body: some View {
        Form {
            if let linkedApplication {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Managed by Prowlarr", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text(linkedApplicationWarningText(for: linkedApplication))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                LabeledContent("Name") {
                    TextField("Indexer name", text: $indexerName)
                        .multilineTextAlignment(.trailing)
                }

                Stepper("Priority: \(priority)", value: $priority, in: 1...50)

                Toggle("RSS", isOn: $enableRss)
                Toggle("Automatic Search", isOn: $enableAutomaticSearch)
                Toggle("Interactive Search", isOn: $enableInteractiveSearch)
            } header: {
                Text("General")
            } footer: {
                Text("These switches control how \(profile.displayName) uses this indexer.")
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
                        DirectIndexerFieldRow(
                            field: field,
                            fieldValues: $fieldValues
                        )
                    }
                }
            }

            if hasAdvancedFields {
                Section {
                    Toggle("Show Advanced Settings", isOn: $showAdvanced)
                }
            }

            if let error = viewModel.error(for: profile.id) {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(mode.navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(mode.buttonTitle) {
                        Task { await save() }
                    }
                    .disabled(indexerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func linkedApplicationWarningText(for application: ProwlarrApplication) -> String {
        let appName = application.name ?? linkedApplicationDisplayName
        let syncLevel = application.syncLevel?.displayName ?? "Sync"
        return "\(appName) is linked to Prowlarr with \(syncLevel). Local indexer changes in \(profile.displayName) may be overwritten the next time Prowlarr syncs."
    }

    private var linkedApplicationDisplayName: String {
        switch serviceType {
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .prowlarr: "Prowlarr"
        case .bazarr: "Bazarr"
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let updatedFields = (mode.seed.fields ?? []).map { field -> ArrIndexerField in
            guard let name = field.name, let newValue = fieldValues[name] else { return field }
            return ArrIndexerField(
                order: field.order,
                name: field.name,
                label: field.label,
                unit: field.unit,
                helpText: field.helpText,
                helpTextWarning: field.helpTextWarning,
                helpLink: field.helpLink,
                value: newValue,
                type: field.type,
                advanced: field.advanced,
                selectOptions: field.selectOptions,
                selectOptionsProviderAction: field.selectOptionsProviderAction,
                section: field.section,
                hidden: field.hidden,
                placeholder: field.placeholder,
                isFloat: field.isFloat
            )
        }

        let tagsValue: [Int]?
        switch mode {
        case .add:
            tagsValue = []
        case .edit:
            tagsValue = mode.seed.tags
        }

        let candidate = ArrManagedIndexer(
            id: mode.seed.id,
            name: indexerName.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: updatedFields,
            implementationName: mode.seed.implementationName,
            implementation: mode.seed.implementation,
            configContract: mode.seed.configContract,
            infoLink: mode.seed.infoLink,
            message: mode.seed.message,
            tags: tagsValue,
            presets: mode.seed.presets,
            enableRss: enableRss,
            enableAutomaticSearch: enableAutomaticSearch,
            enableInteractiveSearch: enableInteractiveSearch,
            supportsRss: mode.seed.supportsRss,
            supportsSearch: mode.seed.supportsSearch,
            protocol: mode.seed.protocol,
            priority: priority,
            seasonSearchMaximumSingleEpisodeAge: mode.seed.seasonSearchMaximumSingleEpisodeAge,
            downloadClientId: mode.seed.downloadClientId
        )

        let saved: Bool
        switch mode {
        case .add:
            saved = await viewModel.addIndexer(candidate, for: profile.id, serviceType: serviceType)
            if saved {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Indexer Added",
                    message: "\(candidate.name ?? "Indexer") has been added to \(profile.displayName)."
                )
            }
        case .edit:
            saved = await viewModel.updateIndexer(candidate, for: profile.id, serviceType: serviceType)
            if saved {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Indexer Updated",
                    message: "\(candidate.name ?? "Indexer") has been updated in \(profile.displayName)."
                )
            }
        }

        if saved {
            onSaved?()
        }
    }
}

private struct DirectIndexerFieldRow: View {
    let field: ArrIndexerField
    @Binding var fieldValues: [String: ArrIndexerFieldValue]

    var body: some View {
        let label = field.label ?? field.name ?? "Field"

        VStack(alignment: .leading, spacing: 6) {
            if let key = field.name {
                switch field.type {
                case "checkbox":
                    Toggle(label, isOn: boolBinding(for: key))

                case "select":
                    if let options = field.selectOptions, !options.isEmpty {
                        Picker(label, selection: intBinding(for: key)) {
                            ForEach(options) { option in
                                Text(option.name ?? "Unknown")
                                    .tag(option.value ?? 0)
                            }
                        }
                    }

                case "password":
                    LabeledContent(label) {
                        SecureField(field.placeholder ?? label, text: stringBinding(for: key))
                            .multilineTextAlignment(.trailing)
                    }

                case "number":
                    LabeledContent(label) {
                        TextField(field.placeholder ?? label, text: numberStringBinding(for: key, isFloat: field.isFloat == true))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(field.isFloat == true ? .decimalPad : .numberPad)
                            #endif
                    }

                default:
                    LabeledContent(label) {
                        TextField(field.placeholder ?? label, text: stringBinding(for: key))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                }
            } else {
                LabeledContent(label) {
                    Text(field.value?.displayString ?? "Unavailable")
                        .foregroundStyle(.secondary)
                }
            }

            if let helpText = field.helpText?.trawlStrippingHTML, !helpText.isEmpty {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let value) = fieldValues[key] {
                    return value
                }
                return fieldValues[key]?.displayString ?? ""
            },
            set: { fieldValues[key] = .string($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let value) = fieldValues[key] {
                    return value
                }
                return false
            },
            set: { fieldValues[key] = .bool($0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                fieldValues[key]?.intValue ?? 0
            },
            set: { fieldValues[key] = .int($0) }
        )
    }

    private func numberStringBinding(for key: String, isFloat: Bool) -> Binding<String> {
        Binding(
            get: {
                switch fieldValues[key] {
                case .int(let value):
                    return value == 0 ? "" : String(value)
                case .double(let value):
                    return value == 0 ? "" : String(value)
                case .string(let value):
                    return value
                default:
                    return ""
                }
            },
            set: { value in
                if value.isEmpty {
                    fieldValues[key] = nil
                } else if isFloat {
                    if let parsed = Double(value) {
                        fieldValues[key] = .double(parsed)
                    }
                } else {
                    if let parsed = Int(value) {
                        fieldValues[key] = .int(parsed)
                    }
                }
            }
        )
    }
}

private extension String {
    var trawlStrippingHTML: String {
        var text = self
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</?p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</?div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
