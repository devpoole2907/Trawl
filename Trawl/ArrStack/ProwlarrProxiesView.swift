import SwiftUI
import SwiftData

struct ProwlarrProxiesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var viewModel: ProwlarrProxiesViewModel
    @State private var editorContext: ProwlarrProxyEditorContext?
    @State private var proxyPendingDelete: ProwlarrIndexerProxy?
    private let loadsDataOnAppear: Bool

    init(loadsDataOnAppear: Bool = true) {
        // Initialize viewModel synchronously in init so it's available for .sheet(item:).
        let placeholder = ProwlarrProxiesViewModel(serviceManager: ArrServiceManager())
        _viewModel = State(initialValue: placeholder)
        self.loadsDataOnAppear = loadsDataOnAppear
    }

    var body: some View {
        content
        .navigationTitle("Proxies")
        .navigationSubtitle("Prowlarr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard loadsDataOnAppear else { return }
            viewModel = ProwlarrProxiesViewModel(serviceManager: serviceManager)
            await viewModel.loadProxies()
            await viewModel.loadSchemaIfNeeded()
        }
        .sheet(item: $editorContext) { context in
            ProwlarrProxyEditorSheet(viewModel: viewModel, context: context)
        }
        .alert(
            "Remove Proxy?",
            isPresented: Binding(
                get: { proxyPendingDelete != nil },
                set: { if !$0 { proxyPendingDelete = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let proxyPendingDelete else { return }
                let name = proxyPendingDelete.name ?? proxyPendingDelete.typeName
                self.proxyPendingDelete = nil

                Task {
                    let removed = await viewModel.deleteProxy(proxyPendingDelete)
                    if removed {
                        InAppNotificationCenter.shared.showSuccess(title: "Proxy Removed", message: "\(name) was removed from Prowlarr.")
                    } else if let error = viewModel.errorMessage {
                        InAppNotificationCenter.shared.showError(title: "Remove Failed", message: error)
                        viewModel.clearError()
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                proxyPendingDelete = nil
            }
        } message: {
            Text("This removes the proxy from Prowlarr. Indexers tagged to use it will stop routing through it.")
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if viewModel.isLoadingProxies && viewModel.proxies.isEmpty {
                Section {
                    ProgressView("Loading proxies…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if let errorMessage = viewModel.errorMessage, !viewModel.isLoadingProxies, viewModel.proxies.isEmpty {
                ContentUnavailableView(
                    "Could Not Load Proxies",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .listRowBackground(Color.clear)
            } else if viewModel.proxies.isEmpty {
                ContentUnavailableView(
                    "No Proxies",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("Add an HTTP, SOCKS, or FlareSolverr proxy so tagged indexers can route their requests through it.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.sortedProxies) { proxy in
                        Button {
                            editorContext = .edit(proxy)
                        } label: {
                            ProwlarrProxyRow(proxy: proxy)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                proxyPendingDelete = proxy
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }

                            Button {
                                editorContext = .edit(proxy)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                editorContext = .edit(proxy)
                            }

                            Button("Remove", systemImage: "trash", role: .destructive) {
                                proxyPendingDelete = proxy
                            }
                        }
                    }
                } footer: {
                    Text("Indexers route through a proxy when they share one of its tags.")
                }
            }
        }
        .refreshable {
            await viewModel.loadProxies()
        }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Menu {
                    if viewModel.sortedSchemas.isEmpty {
                        Text("No proxy types available")
                    } else {
                        ForEach(viewModel.sortedSchemas, id: \.schemaListID) { schema in
                            Button {
                                editorContext = .create(schema)
                            } label: {
                                Label(schema.typeName, systemImage: schema.systemImage)
                            }
                        }
                    }
                } label: {
                    Label("Add Proxy", systemImage: "plus")
                }
                .disabled(!serviceManager.prowlarrConnected || viewModel.sortedSchemas.isEmpty)
            }
        }
    }
}

private struct ProwlarrProxyRow: View {
    let proxy: ProwlarrIndexerProxy

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: proxy.systemImage)
                .foregroundStyle(.yellow)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(proxy.name ?? proxy.typeName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                if let detail = connectionDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(proxy.typeName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
    }

    private var connectionDetail: String? {
        let host = proxy.stringFieldValue(named: "host")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !host.isEmpty else { return nil }
        if let port = proxy.stringFieldValue(named: "port"), !port.isEmpty {
            return "\(host):\(port)"
        }
        return host
    }
}

// MARK: - Editor

enum ProwlarrProxyEditorContext: Identifiable {
    case create(ProwlarrIndexerProxy)
    case edit(ProwlarrIndexerProxy)

    var id: String {
        switch self {
        case .create(let schema):
            "create-\(schema.implementation ?? schema.typeName)"
        case .edit(let proxy):
            "edit-\(proxy.id)"
        }
    }

    /// The schema template (create) or existing proxy (edit) used to seed the form.
    var seed: ProwlarrIndexerProxy {
        switch self {
        case .create(let schema):
            schema
        case .edit(let proxy):
            proxy
        }
    }

    var isEditing: Bool {
        if case .edit = self { return true }
        return false
    }
}

struct ProwlarrProxyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: ProwlarrProxiesViewModel
    let context: ProwlarrProxyEditorContext

    @State private var name: String
    @State private var selectedTagIDs: Set<Int>
    @State private var fieldValues: [String: ProwlarrApplicationValue]
    @State private var isSaving = false
    @State private var localErrorMessage: String?

    init(viewModel: ProwlarrProxiesViewModel, context: ProwlarrProxyEditorContext) {
        self.viewModel = viewModel
        self.context = context

        let seed = context.seed
        _name = State(initialValue: seed.name ?? seed.typeName)
        _selectedTagIDs = State(initialValue: Set(seed.tags ?? []))

        var defaults: [String: ProwlarrApplicationValue] = [:]
        for field in seed.fields ?? [] {
            if let fieldName = field.name, let value = field.value {
                defaults[fieldName] = value
            }
        }
        _fieldValues = State(initialValue: defaults)
    }

    private var visibleFields: [ProwlarrApplicationField] {
        (context.seed.fields ?? []).filter { field in
            field.hidden != "hidden" && field.type != "info"
        }
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        AppSheetShell(
            title: context.isEditing ? "Edit Proxy" : "Add \(context.seed.typeName) Proxy",
            subtitle: context.isEditing ? context.seed.typeName : nil,
            confirmTitle: context.isEditing ? "Update" : "Save",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } }
        ) {
            Form {
                Section("General") {
                    LabeledContent("Name") {
                        TextField("Proxy name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if !visibleFields.isEmpty {
                    Section("Settings") {
                        ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                            fieldRow(for: field)
                        }
                    }
                }

                Section {
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
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Indexers route through this proxy when they share one of its tags. Leave empty to apply to no indexers.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            if viewModel.isTesting {
                                ProgressView()
                            } else {
                                Image(systemName: "checkmark.circle")
                            }
                            Text("Test")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(viewModel.isTesting || isSaving)
                }

                if let errorMessage = localErrorMessage ?? viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Field rendering

    @ViewBuilder
    private func fieldRow(for field: ProwlarrApplicationField) -> some View {
        let label = field.label ?? field.name ?? ""
        let key = field.name ?? ""

        switch field.type {
        case "password":
            LabeledContent(label) {
                SecureField(label, text: stringBinding(for: key))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
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
                        Text(option.name ?? "").tag(intValue(of: option.value))
                    }
                }
            } else {
                LabeledContent(label) {
                    TextField(label, text: stringBinding(for: key))
                        .multilineTextAlignment(.trailing)
                }
            }
        default:
            LabeledContent(label) {
                TextField(label, text: stringBinding(for: key))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Bindings

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let value) = fieldValues[key] { return value }
                return ""
            },
            set: { fieldValues[key] = .string($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let value) = fieldValues[key] { return value }
                return false
            },
            set: { fieldValues[key] = .bool($0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                if case .int(let value) = fieldValues[key] { return value }
                return 0
            },
            set: { fieldValues[key] = .int($0) }
        )
    }

    private func numberStringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                if case .int(let value) = fieldValues[key] { return value == 0 ? "" : String(value) }
                if case .double(let value) = fieldValues[key] { return String(value) }
                return ""
            },
            set: { str in
                if let intValue = Int(str) { fieldValues[key] = .int(intValue) }
                else if str.isEmpty { fieldValues[key] = .int(0) }
            }
        )
    }

    private func intValue(of value: ProwlarrApplicationValue?) -> Int {
        switch value {
        case .int(let intValue): return intValue
        case .double(let doubleValue): return Int(doubleValue)
        case .string(let stringValue): return Int(stringValue) ?? 0
        default: return 0
        }
    }

    // MARK: - Actions

    private func buildPayload() -> ProwlarrIndexerProxy {
        var payload = context.seed
        payload.id = context.isEditing ? context.seed.id : 0
        payload.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.tags = Array(selectedTagIDs).sorted()
        payload.presets = nil

        for (key, value) in fieldValues {
            payload = payload.updatingField(named: key, with: value)
        }
        return payload
    }

    private func test() async {
        localErrorMessage = nil
        viewModel.clearError()

        let succeeded = await viewModel.testProxy(buildPayload())
        if succeeded {
            InAppNotificationCenter.shared.showSuccess(title: "Test Passed", message: "Prowlarr reached the proxy successfully.")
        } else if let errorMessage = viewModel.errorMessage {
            localErrorMessage = errorMessage
        }
    }

    private func save() async {
        guard !isSaving else { return }
        localErrorMessage = nil

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localErrorMessage = "A proxy name is required."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let payload = buildPayload()
        let didSave = await viewModel.saveProxy(payload)
        if didSave {
            let action = context.isEditing ? "updated in" : "added to"
            InAppNotificationCenter.shared.showSuccess(
                title: "Saved",
                message: "\(payload.name ?? payload.typeName) was \(action) Prowlarr."
            )
            dismiss()
        } else if let errorMessage = viewModel.errorMessage {
            localErrorMessage = errorMessage
        }
    }
}

#if DEBUG
extension ProwlarrProxiesListView {
    init(previewViewModel: ProwlarrProxiesViewModel) {
        self.init(loadsDataOnAppear: false)
        self._viewModel = State(initialValue: previewViewModel)
    }
}

#Preview("Loaded") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrProxiesViewModel(
        previewProxies: ProwlarrIndexerProxy.previewList,
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrProxiesListView(previewViewModel: viewModel)
        }
    }
}

#Preview("Empty") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrProxiesViewModel(
        previewProxies: [],
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrProxiesListView(previewViewModel: viewModel)
        }
    }
}

#Preview("Loading") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrProxiesViewModel(
        previewProxies: [],
        isLoadingProxies: true,
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrProxiesListView(previewViewModel: viewModel)
        }
    }
}

#Preview("Error") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrProxiesViewModel(
        previewProxies: [],
        errorMessage: "Prowlarr returned 401 Unauthorized.",
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrProxiesListView(previewViewModel: viewModel)
        }
    }
}

#Preview("Editor - Edit") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrProxiesViewModel(
        previewProxies: ProwlarrIndexerProxy.previewList,
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        ProwlarrProxyEditorSheet(viewModel: viewModel, context: .edit(.previewHttp))
    }
}

#Preview("Editor - Create") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrProxiesViewModel(
        previewProxies: ProwlarrIndexerProxy.previewList,
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        ProwlarrProxyEditorSheet(
            viewModel: viewModel,
            context: .create(.previewSchema(implementation: "Socks5", configContract: "Socks5Settings"))
        )
    }
}
#endif
