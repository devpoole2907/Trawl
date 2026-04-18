import SwiftUI

struct ProwlarrAddIndexerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: ProwlarrViewModel

    @State private var searchText = ""

    private var filteredSchema: [ProwlarrIndexer] {
        guard !searchText.isEmpty else { return viewModel.schemaIndexers }
        return viewModel.schemaIndexers.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.implementationName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingSchema {
                    ProgressView("Loading indexer types…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSchema.isEmpty {
                    ContentUnavailableView.search
                } else {
                    List(filteredSchema) { schema in
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
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, prompt: "Search indexers")
            .navigationTitle("Add Indexer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await viewModel.loadSchema()
            }
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

// MARK: - Config View

private struct IndexerConfigView: View {
    let schema: ProwlarrIndexer
    let viewModel: ProwlarrViewModel
    let onAdded: () -> Void

    @State private var indexerName: String
    @State private var priority = 25
    @State private var showAdvanced = false
    @State private var fieldValues: [String: AnyCodableValue]
    @State private var isAdding = false

    init(schema: ProwlarrIndexer, viewModel: ProwlarrViewModel, onAdded: @escaping () -> Void) {
        self.schema = schema
        self.viewModel = viewModel
        self.onAdded = onAdded
        _indexerName = State(initialValue: schema.name ?? "")
        var defaults: [String: AnyCodableValue] = [:]
        for field in schema.fields ?? [] {
            if let name = field.name, let value = field.value {
                defaults[name] = value
            }
        }
        _fieldValues = State(initialValue: defaults)
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
            Section("General") {
                LabeledContent("Name") {
                    TextField("Name", text: $indexerName)
                        .multilineTextAlignment(.trailing)
                }
                Stepper("Priority: \(priority)", value: $priority, in: 1...50)
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
                        Text(option.name ?? "").tag(option.value ?? 0)
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
        isAdding = true
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
            tags: [],
            priority: priority,
            appProfileId: 1,
            shouldSearch: nil,
            supportsRss: nil,
            supportsSearch: nil,
            protocol: schema.protocol,
            fields: updatedFields
        )

        await viewModel.addIndexer(newIndexer)
        isAdding = false

        if viewModel.indexerError == nil {
            onAdded()
        }
    }
}
