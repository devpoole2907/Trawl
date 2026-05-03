import SwiftUI

struct BazarrProvidersView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var settings: [String: JSONValue] = [:]
    @State private var providerStatuses: [BazarrProvider] = []
    @State private var enabledProviderKeys: [String] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var addSheetPresented = false
    @State private var deleteTarget: BazarrProviderDefinition?
    @State private var antiCaptchaProvider: BazarrAntiCaptchaProvider = .none
    @State private var antiCaptchaKey = ""
    @State private var deathByCaptchaUsername = ""
    @State private var deathByCaptchaPassword = ""
    @State private var isSavingAntiCaptcha = false
    @State private var isEditingAntiCaptcha = false

    private var client: BazarrAPIClient? {
        serviceManager.activeBazarrEntry?.client
    }

    private var enabledProviders: [BazarrProviderDefinition] {
        enabledProviderKeys.compactMap { BazarrProviderCatalog.definition(for: $0) }
    }

    private var filteredProviders: [BazarrProviderDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = enabledProviders
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            provider.displayName.localizedCaseInsensitiveContains(query)
                || provider.key.localizedCaseInsensitiveContains(query)
                || provider.description?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        Group {
            if !serviceManager.hasBazarrInstance {
                ContentUnavailableView(
                    "Bazarr Not Set Up",
                    systemImage: "captions.bubble",
                    description: Text("Add a Bazarr server in Settings to manage subtitle providers.")
                )
            } else if !serviceManager.hasAnyConnectedBazarrInstance {
                ContentUnavailableView(
                    "Bazarr Unreachable",
                    systemImage: "network.slash",
                    description: Text(serviceManager.bazarrConnectionError ?? "Unable to reach your configured Bazarr server.")
                )
            } else {
                contentView
            }
        }
        .navigationTitle("Providers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $searchText, prompt: "Search providers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addSheetPresented = true
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .disabled(client == nil)
            }

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await resetProviders() }
                } label: {
                    Label("Reset Provider Status", systemImage: "arrow.counterclockwise")
                }
                .disabled(providerStatuses.isEmpty)
            }
        }
        .sheet(isPresented: $addSheetPresented) {
            NavigationStack {
                BazarrProviderPickerView(
                    enabledKeys: enabledProviderKeys,
                    settings: settings
                ) { provider, values in
                    let succeeded = await save(provider: provider, values: values, enabling: true)
                    if succeeded {
                        addSheetPresented = false
                    }
                    return succeeded
                }
            }
        }
        .alert(
            "Disable Provider?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Disable", role: .destructive) {
                guard let deleteTarget else { return }
                self.deleteTarget = nil
                Task { await disable(deleteTarget) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This removes the provider from Bazarr's enabled list. Saved provider settings are kept.")
        }
        .task(id: serviceManager.activeBazarrProfileID) {
            await load()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        List {
            if let errorMessage {
                Section("Unavailable") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                antiCaptchaSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isLoading && enabledProviderKeys.isEmpty {
                loadingRows
            } else if filteredProviders.isEmpty {
                emptyState
            } else {
                Section("Enabled Providers") {
                    ForEach(filteredProviders) { provider in
                        NavigationLink {
                            BazarrProviderEditorView(
                                provider: provider,
                                settings: settings,
                                mode: .edit,
                                onRemove: {
                                    Task { await disable(provider) }
                                }
                            ) { values in
                                await save(provider: provider, values: values, enabling: false)
                            }
                        } label: {
                            BazarrProviderRowView(
                                title: provider.displayName,
                                subtitle: subtitle(for: provider),
                                barColor: .teal,
                                isEnabled: true,
                                warningState: warningState(for: provider)
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = provider
                            } label: {
                                Label("Disable", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTarget = provider
                            } label: {
                                Label("Disable", systemImage: "trash")
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
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .refreshable { await load() }
        .animation(.easeInOut(duration: 0.25), value: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var loadingRows: some View {
        Section("Enabled Providers") {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 4, height: 42)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 160, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 120, height: 11)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            searchText.isEmpty ? "No Providers" : "No Results",
            systemImage: searchText.isEmpty ? "person.2.slash" : "magnifyingglass",
            description: Text(searchText.isEmpty ? "Use the add button to enable a Bazarr subtitle provider." : "No enabled providers match your search.")
        )
        .listRowBackground(Color.clear)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.teal.opacity(0.10), Color.blue.opacity(0.05), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.teal.opacity(0.12), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }

    private func load() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let settingsLoad = client.getSettings()
            async let providersLoad = client.getProviders()
            let loadedSettings = try await settingsLoad
            let loadedStatuses = (try? await providersLoad) ?? []
            settings = loadedSettings
            providerStatuses = loadedStatuses
            enabledProviderKeys = loadedSettings.enabledBazarrProviderKeys
            applyAntiCaptchaSettings(from: loadedSettings)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @ViewBuilder
    private var antiCaptchaSection: some View {
        Section {
            if isEditingAntiCaptcha {
                Picker("Service", selection: $antiCaptchaProvider) {
                    ForEach(BazarrAntiCaptchaProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                switch antiCaptchaProvider {
                case .none:
                    EmptyView()
                case .antiCaptcha:
                    LabeledContent("Account Key") {
                        SecureField("Account key", text: $antiCaptchaKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                case .deathByCaptcha:
                    LabeledContent("Username") {
                        TextField("Username", text: $deathByCaptchaUsername)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Password") {
                        SecureField("Password", text: $deathByCaptchaPassword)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }

                Button {
                    Task { await saveAntiCaptchaSettings() }
                } label: {
                    HStack {
                        Spacer()
                        if isSavingAntiCaptcha {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.medium)
                        }
                        Spacer()
                    }
                }
                .tint(.teal)
                .disabled(isSavingAntiCaptcha || !canSaveAntiCaptcha)
            } else {
                LabeledContent("Service", value: antiCaptchaProvider.displayName)

                switch antiCaptchaProvider {
                case .none:
                    EmptyView()
                case .antiCaptcha:
                    LabeledContent("Account Key") {
                        Text(antiCaptchaKey.isEmpty ? "Not configured" : String(repeating: "•", count: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                case .deathByCaptcha:
                    LabeledContent("Username") {
                        Text(deathByCaptchaUsername.isEmpty ? "Not configured" : deathByCaptchaUsername)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    LabeledContent("Password") {
                        Text(deathByCaptchaPassword.isEmpty ? "Not configured" : String(repeating: "•", count: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { isEditingAntiCaptcha = true }
                } label: {
                    HStack {
                        Spacer()
                        Text("Edit")
                            .fontWeight(.medium)
                        Spacer()
                    }
                }
                .tint(.teal)
            }
        } header: {
            Text("Anti-Captcha")
        } footer: {
            Text("Some subtitle providers require an anti-captcha service before they can search or download reliably.")
        }
    }

    private var canSaveAntiCaptcha: Bool {
        switch antiCaptchaProvider {
        case .none:
            true
        case .antiCaptcha:
            !antiCaptchaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .deathByCaptcha:
            !deathByCaptchaUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !deathByCaptchaPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func applyAntiCaptchaSettings(from settings: [String: JSONValue]) {
        let providerValue = settings.bazarrSetting("general", "anti_captcha_provider") ?? ""
        antiCaptchaProvider = BazarrAntiCaptchaProvider(rawValue: providerValue) ?? .none
        antiCaptchaKey = settings.bazarrSetting("anticaptcha", "anti_captcha_key") ?? ""
        deathByCaptchaUsername = settings.bazarrSetting("deathbycaptcha", "username") ?? ""
        deathByCaptchaPassword = settings.bazarrSetting("deathbycaptcha", "password") ?? ""
    }

    private func saveAntiCaptchaSettings() async {
        guard let client else { return }
        isSavingAntiCaptcha = true
        defer { isSavingAntiCaptcha = false }

        let formItems = [
            URLQueryItem(name: "settings-general-anti_captcha_provider", value: antiCaptchaProvider.settingsValue),
            URLQueryItem(name: "settings-anticaptcha-anti_captcha_key", value: antiCaptchaKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "settings-deathbycaptcha-username", value: deathByCaptchaUsername.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "settings-deathbycaptcha-password", value: deathByCaptchaPassword)
        ]

        do {
            try await client.saveSettings(formItems)
            withAnimation(.easeInOut(duration: 0.25)) { isEditingAntiCaptcha = false }
            InAppNotificationCenter.shared.showSuccess(title: "Anti-Captcha Saved", message: "Bazarr anti-captcha settings were updated.")
            await load()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Save Failed", message: error.localizedDescription)
        }
    }

    private func save(provider: BazarrProviderDefinition, values: [String: String], enabling: Bool) async -> Bool {
        guard let client else { return false }
        var nextKeys = enabledProviderKeys
        if enabling, !nextKeys.contains(provider.key) {
            nextKeys.append(provider.key)
        }

        do {
            try await client.saveEnabledProviders(nextKeys, fieldValues: values)
            InAppNotificationCenter.shared.showSuccess(
                title: enabling ? "Provider Added" : "Provider Updated",
                message: "\(provider.displayName) has been saved in Bazarr."
            )
            await load()
            return true
        } catch {
            InAppNotificationCenter.shared.showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    private func disable(_ provider: BazarrProviderDefinition) async {
        guard let client else { return }
        let nextKeys = enabledProviderKeys.filter { $0 != provider.key }
        do {
            try await client.saveEnabledProviders(nextKeys)
            InAppNotificationCenter.shared.showSuccess(title: "Provider Disabled", message: "\(provider.displayName) has been disabled.")
            await load()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Disable Failed", message: error.localizedDescription)
        }
    }

    private func resetProviders() async {
        guard let client else { return }
        do {
            try await client.resetProviders()
            InAppNotificationCenter.shared.showSuccess(title: "Provider Status Reset", message: "Bazarr provider status has been reset.")
            await load()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Reset Failed", message: error.localizedDescription)
        }
    }

    private func subtitle(for provider: BazarrProviderDefinition) -> String {
        var parts = ["Bazarr"]
        if let status = status(for: provider), !status.status.isEmpty {
            parts.append(status.status)
        } else if let description = provider.description, !description.isEmpty {
            parts.append(description)
        }
        return parts.joined(separator: " · ")
    }

    private func status(for provider: BazarrProviderDefinition) -> BazarrProvider? {
        providerStatuses.first {
            $0.name.localizedCaseInsensitiveCompare(provider.key) == .orderedSame
                || $0.name.localizedCaseInsensitiveCompare(provider.displayName) == .orderedSame
        }
    }

    private func warningState(for provider: BazarrProviderDefinition) -> BazarrProviderRowWarningState {
        guard let status = status(for: provider) else { return .enabled }
        let lowercased = status.status.lowercased()
        if lowercased.contains("error") || lowercased.contains("throttle") || lowercased.contains("disabled") {
            return .warning
        }
        return .enabled
    }
}

private struct BazarrProviderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let enabledKeys: [String]
    let settings: [String: JSONValue]
    let onSave: (BazarrProviderDefinition, [String: String]) async -> Bool

    @State private var searchText = ""

    private var availableProviders: [BazarrProviderDefinition] {
        let providers = BazarrProviderCatalog.providers.filter { !enabledKeys.contains($0.key) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.key.localizedCaseInsensitiveContains(query)
                || $0.description?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        List {
            if availableProviders.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "All Providers Enabled" : "No Results",
                    systemImage: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Every supported provider is already enabled." : "No providers match your search.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(availableProviders) { provider in
                    NavigationLink {
                        BazarrProviderEditorView(
                            provider: provider,
                            settings: settings,
                            mode: .add
                        ) { values in
                            await onSave(provider, values)
                        }
                    } label: {
                        BazarrProviderRowView(
                            title: provider.displayName,
                            subtitle: provider.description ?? "Bazarr",
                            barColor: .teal,
                            isEnabled: true,
                            warningState: .available
                        )
                    }
                }
            }
        }
        .navigationTitle("Add Provider")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .searchable(text: $searchText, prompt: "Search providers")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }
}

private struct BazarrProviderEditorView: View {
    enum Mode {
        case add
        case edit

        var buttonTitle: String {
            switch self {
            case .add: "Enable"
            case .edit: "Save"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let provider: BazarrProviderDefinition
    let settings: [String: JSONValue]
    let mode: Mode
    let onSave: ([String: String]) async -> Bool
    let onRemove: (() -> Void)?

    @State private var values: [String: String]
    @State private var isSaving = false
    @State private var showDisableConfirm = false

    init(
        provider: BazarrProviderDefinition,
        settings: [String: JSONValue],
        mode: Mode,
        onRemove: (() -> Void)? = nil,
        onSave: @escaping ([String: String]) async -> Bool
    ) {
        self.provider = provider
        self.settings = settings
        self.mode = mode
        self.onRemove = onRemove
        self.onSave = onSave

        var initialValues: [String: String] = [:]
        for field in provider.fields {
            initialValues[field.key] = settings.bazarrProviderValue(providerKey: provider.key, fieldKey: field.key)
                ?? field.defaultValue
                ?? ""
        }
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        Form {
            if mode == .edit {
                Section("Status") {
                    Toggle("Enabled", isOn: Binding(
                        get: { true },
                        set: { newValue in if !newValue { showDisableConfirm = true } }
                    ))

                    LabeledContent("Provider", value: provider.displayName)
                    if let description = provider.description {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let message = provider.message {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    LabeledContent("Provider", value: provider.displayName)
                    if let description = provider.description {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let message = provider.message {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !provider.fields.isEmpty {
                Section("Configuration") {
                    ForEach(provider.fields) { field in
                        fieldRow(field)
                    }
                }
            }

            if mode == .edit {
                Section {
                    Button(role: .destructive) {
                        showDisableConfirm = true
                    } label: {
                        Label("Disable Provider", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(provider.displayName)
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
                }
            }
        }
        .alert("Disable Provider?", isPresented: $showDisableConfirm) {
            Button("Disable", role: .destructive) {
                onRemove?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \"\(provider.displayName)\" from Bazarr's enabled list. Saved settings are kept.")
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: BazarrProviderField) -> some View {
        switch field.kind {
        case .text:
            LabeledContent(field.displayName) {
                TextField(field.displayName, text: stringBinding(for: field.key))
                    .multilineTextAlignment(.trailing)
            }
        case .password:
            LabeledContent(field.displayName) {
                SecureField(field.displayName, text: stringBinding(for: field.key))
                    .multilineTextAlignment(.trailing)
            }
        case .toggle:
            Toggle(field.displayName, isOn: boolBinding(for: field.key))
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        var formValues: [String: String] = [:]
        for field in provider.fields {
            formValues["settings-\(provider.key)-\(field.key)"] = values[field.key] ?? ""
        }
        defer { isSaving = false }
        if await onSave(formValues) {
            dismiss()
        }
    }

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { (values[key] ?? "").boolValue },
            set: { values[key] = $0 ? "true" : "false" }
        )
    }
}

private struct BazarrProviderRowView: View {
    let title: String
    let subtitle: String
    let barColor: Color
    let isEnabled: Bool
    let warningState: BazarrProviderRowWarningState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(statusColor)
                .frame(width: 4, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isEnabled ? .primary : .secondary)

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
        switch warningState {
        case .enabled, .available: barColor
        case .warning: .orange
        }
    }

    private var warningIcon: String {
        switch warningState {
        case .enabled: "circle.fill"
        case .available: "plus.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var warningIconColor: Color {
        switch warningState {
        case .enabled: .green
        case .available: .teal
        case .warning: .orange
        }
    }
}

private enum BazarrProviderRowWarningState {
    case enabled
    case available
    case warning
}

private enum BazarrAntiCaptchaProvider: String, CaseIterable, Identifiable {
    case none = ""
    case antiCaptcha = "anti-captcha"
    case deathByCaptcha = "death-by-captcha"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "None"
        case .antiCaptcha:
            "Anti-Captcha.com"
        case .deathByCaptcha:
            "DeathByCaptcha"
        }
    }

    var settingsValue: String {
        rawValue
    }
}

private struct BazarrProviderDefinition: Identifiable, Hashable {
    let key: String
    let name: String?
    let description: String?
    let message: String?
    let fields: [BazarrProviderField]

    var id: String { key }
    var displayName: String { name ?? key.providerDisplayName }
}

private struct BazarrProviderField: Identifiable, Hashable {
    enum Kind: Hashable {
        case text
        case password
        case toggle
    }

    let key: String
    let name: String?
    let kind: Kind
    let defaultValue: String?

    var id: String { key }
    var displayName: String { name ?? key.providerDisplayName }
}

private enum BazarrProviderCatalog {
    static let providers: [BazarrProviderDefinition] = [
        provider("addic7ed", description: "Requires Anti-Captcha Provider or cookies", fields: [
            text("username"), password("password"), text("cookies", name: "Cookies"), text("user_agent", name: "User-Agent"), toggle("vip", name: "VIP")
        ]),
        provider("animekalesi", name: "AnimeKalesi", description: "Turkish Anime Series Subtitles Provider"),
        provider("animetosho", name: "Anime Tosho", description: "Anime torrent subtitle provider", message: "Requires AniDB Integration.", fields: [
            text("search_threshold", name: "Search Threshold", defaultValue: "6")
        ]),
        provider("animesubinfo", name: "AnimeSub.info", description: "Polish Anime Subtitles Provider"),
        provider("assrt", description: "Chinese Subtitles Provider", fields: [text("token")]),
        provider("avistaz", name: "AvistaZ", description: "Asian private tracker subtitle provider", fields: [
            text("cookies", name: "Cookies"), text("user_agent", name: "User-Agent")
        ]),
        provider("betaseries", name: "BetaSeries", description: "French / English Provider for TV Shows Only", fields: [text("token", name: "API Key")]),
        provider("bsplayer", name: "BSplayer", description: "Removed from Bazarr because it caused too many issues."),
        provider("cinemaz", name: "CinemaZ", description: "Private movie tracker subtitle provider", fields: [
            text("cookies", name: "Cookies"), text("user_agent", name: "User-Agent")
        ]),
        provider("embeddedsubtitles", name: "Embedded Subtitles", description: "Extract embedded subtitles from media files", message: "Cloud users: this provider reads the whole file to extract subtitles.", fields: [
            text("included_codecs", name: "Allowed Codecs"),
            text("timeout", name: "Extraction Timeout", defaultValue: "600"),
            toggle("hi_fallback", name: "Use HI subtitles as fallback"),
            toggle("unknown_as_fallback", name: "Use unknown subtitles as fallback"),
            text("fallback_lang", name: "Fallback Language", defaultValue: "en")
        ]),
        provider("gestdown", name: "Gestdown", description: "Addic7ed proxy. No login or cookies required."),
        provider("greeksubs", name: "GreekSubs", description: "Greek Subtitles Provider"),
        provider("greeksubtitles", name: "GreekSubtitles", description: "Greek Subtitles Provider"),
        provider("hdbits", name: "HDBits.org", description: "Private tracker subtitles provider", message: "2FA and IP whitelisting may be required.", fields: [
            text("username"), password("passkey", name: "Passkey")
        ]),
        provider("hosszupuska", description: "Hungarian Subtitles Provider"),
        provider("jimaku", name: "Jimaku.cc", description: "Japanese Subtitles Provider", message: "API key required.", fields: [
            password("api_key", name: "API Key"),
            toggle("enable_name_search_fallback", name: "Search by name fallback"),
            toggle("enable_archives_download", name: "Download archives"),
            toggle("enable_ai_subs", name: "Download AI subtitles")
        ]),
        provider("karagarga", name: "Karagarga.in", description: "Private movie tracker subtitles provider", fields: [
            text("username"), password("password"), text("f_username", name: "Forum Username"), password("f_password", name: "Forum Password")
        ]),
        provider("ktuvit", name: "Ktuvit", description: "Hebrew Subtitles Provider", fields: [
            text("email"), text("hashed_password", name: "Hashed Password")
        ]),
        provider("legendasdivx", name: "LegendasDivx", description: "Brazilian / Portuguese Subtitles Provider", fields: [
            text("username"), password("password"), toggle("skip_wrong_fps", name: "Skip Wrong FPS")
        ]),
        provider("legendasnet", name: "Legendas.net", description: "Brazilian Subtitles Provider", fields: [
            text("username"), password("password")
        ]),
        provider("napiprojekt", description: "Polish Subtitles Provider", fields: [
            toggle("only_authors", name: "Only subtitles with authors"),
            toggle("only_real_names", name: "Only real name authors")
        ]),
        provider("napisy24", description: "Polish Subtitles Provider", message: "Credentials must have API access. Leave empty to use defaults.", fields: [
            text("username"), password("password")
        ]),
        provider("nekur", description: "Latvian Subtitles Provider"),
        provider("opensubtitlescom", name: "OpenSubtitles.com", fields: [
            text("username"), password("password"), toggle("use_hash", name: "Use Hash", defaultValue: "true"),
            toggle("include_ai_translated", name: "Include AI translated subtitles"),
            toggle("include_machine_translated", name: "Include machine translated subtitles")
        ]),
        provider("podnapisi", name: "Podnapisi", fields: [toggle("verify_ssl", name: "Verify SSL", defaultValue: "true")]),
        provider("regielive", name: "RegieLive", description: "Romanian Subtitles Provider"),
        provider("soustitreseu", name: "Sous-Titres.eu", description: "Mostly French Subtitles Provider"),
        provider("subdl", fields: [text("api_key", name: "API Key")]),
        provider("subf2m", name: "subf2m.co", message: "Use a unique and credible user agent.", fields: [
            toggle("verify_ssl", name: "Verify SSL", defaultValue: "true"), text("user_agent", name: "User-Agent")
        ]),
        provider("subsource", name: "subsource.net", message: "API key is required.", fields: [password("apikey", name: "API Key")]),
        provider("subssabbz", name: "Subs.sab.bz", description: "Bulgarian Subtitles Provider"),
        provider("subs4free", name: "Subs4Free", description: "Greek Subtitles Provider"),
        provider("subs4series", name: "Subs4Series", description: "Greek Subtitles Provider. Requires anti-captcha."),
        provider("subscenter", description: "Hebrew Subtitles Provider"),
        provider("subsro", name: "subs.ro", description: "Romanian Subtitles Provider"),
        provider("subsunacs", name: "Subsunacs.net", description: "Bulgarian Subtitles Provider"),
        provider("subsynchro", description: "French Subtitles Provider"),
        provider("subtis", name: "Subtis", description: "Spanish Subtitles Provider for Movies"),
        provider("subtitrarinoi", name: "Subtitrari-noi.ro", description: "Romanian Subtitles Provider"),
        provider("subtitriid", name: "subtitri.id.lv", description: "Latvian Subtitles Provider"),
        provider("subtitulamostv", name: "Subtitulamos.tv", description: "Spanish Subtitles Provider"),
        provider("subx", name: "SubX", description: "Subdivx search/download API", message: "API key required.", fields: [text("api_key", name: "API Key")]),
        provider("supersubtitles"),
        provider("titlovi", fields: [text("username"), password("password")]),
        provider("titrari", name: "Titrari.ro", description: "Mostly Romanian Subtitles Provider"),
        provider("titulky", name: "Titulky.com", description: "CZ/SK Subtitles Provider. Available only with VIP.", fields: [
            text("username"), password("password"), toggle("approved_only", name: "Skip unapproved subtitles"), toggle("skip_wrong_fps", name: "Skip Wrong FPS")
        ]),
        provider("turkcealtyaziorg", name: "Turkcealtyazi.org", description: "Turkish Subtitles Provider", fields: [
            text("cookies", name: "Cookies"), text("user_agent", name: "User-Agent")
        ]),
        provider("tvsubtitles", name: "TVSubtitles"),
        provider("whisperai", name: "Whisper", description: "AI generated subtitles powered by Whisper", fields: [
            text("endpoint", name: "Whisper ASR Endpoint", defaultValue: "http://127.0.0.1:9000"),
            text("response", name: "Connection Timeout", defaultValue: "5"),
            text("timeout", name: "Transcription Timeout", defaultValue: "3600"),
            text("loglevel", name: "Logging Level", defaultValue: "INFO"),
            toggle("pass_video_name", name: "Pass video filename to Whisper")
        ]),
        provider("wizdom", description: "Wizdom.xyz Subtitles Provider"),
        provider("xsubs", name: "XSubs", description: "Greek Subtitles Provider", fields: [text("username"), password("password")]),
        provider("yavkanet", name: "Yavka.net", description: "Bulgarian Subtitles Provider"),
        provider("yifysubtitles", name: "YIFY Subtitles"),
        provider("zimuku", name: "Zimuku", description: "Chinese Subtitles Provider. Anti-captcha required.")
    ].sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    static func definition(for key: String) -> BazarrProviderDefinition? {
        providers.first { $0.key == key }
    }

    private static func provider(
        _ key: String,
        name: String? = nil,
        description: String? = nil,
        message: String? = nil,
        fields: [BazarrProviderField] = []
    ) -> BazarrProviderDefinition {
        BazarrProviderDefinition(key: key, name: name, description: description, message: message, fields: fields)
    }

    private static func text(_ key: String, name: String? = nil, defaultValue: String? = nil) -> BazarrProviderField {
        BazarrProviderField(key: key, name: name, kind: .text, defaultValue: defaultValue)
    }

    private static func password(_ key: String, name: String? = nil, defaultValue: String? = nil) -> BazarrProviderField {
        BazarrProviderField(key: key, name: name, kind: .password, defaultValue: defaultValue)
    }

    private static func toggle(_ key: String, name: String? = nil, defaultValue: String? = nil) -> BazarrProviderField {
        BazarrProviderField(key: key, name: name, kind: .toggle, defaultValue: defaultValue)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var enabledBazarrProviderKeys: [String] {
        guard case .object(let general)? = self["general"],
              case .array(let providers)? = general["enabled_providers"] else {
            return []
        }
        return providers.compactMap {
            guard case .string(let value) = $0, !value.isEmpty else { return nil }
            return value
        }
    }

    func bazarrProviderValue(providerKey: String, fieldKey: String) -> String? {
        guard case .object(let providerSettings)? = self[providerKey],
              let value = providerSettings[fieldKey] else {
            return nil
        }

        return stringValue(from: value)
    }

    func bazarrSetting(_ section: String, _ key: String) -> String? {
        guard case .object(let sectionValues)? = self[section],
              let value = sectionValues[key] else {
            return nil
        }

        return stringValue(from: value)
    }

    private func stringValue(from value: JSONValue) -> String? {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .array(let values):
            return values.compactMap {
                guard case .string(let value) = $0 else { return nil }
                return value
            }.joined(separator: ",")
        case .object, .null:
            return nil
        }
    }
}

private extension String {
    var providerDisplayName: String {
        split(separator: "_")
            .flatMap { $0.split(separator: "-") }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var boolValue: Bool {
        ["true", "1", "yes"].contains(lowercased())
    }
}
