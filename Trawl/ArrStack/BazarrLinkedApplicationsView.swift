import SwiftData
import SwiftUI

struct BazarrLinkedApplicationsListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    @State private var settings: [String: JSONValue] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editorContext: BazarrLinkedApplicationType?

    private var client: BazarrAPIClient? {
        serviceManager.activeBazarrEntry?.client
    }

    var body: some View {
        List {
            if isLoading && settings.isEmpty {
                Section {
                    ProgressView("Loading linked applications...")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Could Not Load Apps",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(BazarrLinkedApplicationType.allCases) { appType in
                        Button {
                            editorContext = appType
                        } label: {
                            BazarrLinkedApplicationRow(
                                appType: appType,
                                settings: settings
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if settings.isBazarrLinkedApplicationEnabled(appType) {
                                Button(role: .destructive) {
                                    Task { await disable(appType) }
                                } label: {
                                    Label("Disable", systemImage: "trash")
                                }
                            }

                            Button {
                                editorContext = appType
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                editorContext = appType
                            }

                            if settings.isBazarrLinkedApplicationEnabled(appType) {
                                Button("Disable", systemImage: "trash", role: .destructive) {
                                    Task { await disable(appType) }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Bazarr uses these connections to sync series, episodes, and movies from Sonarr/Radarr.")
                }
            }
        }
        .navigationTitle("Linked Apps")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .refreshable { await load() }
        .task(id: serviceManager.activeBazarrProfileID) {
            await load()
        }
        .sheet(item: $editorContext) { appType in
            BazarrLinkedApplicationEditorSheet(
                appType: appType,
                settings: settings
            ) { formItems in
                await save(appType: appType, formItems: formItems)
            }
            .environment(serviceManager)
        }
    }

    private func load() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            settings = try await client.getSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save(appType: BazarrLinkedApplicationType, formItems: [URLQueryItem]) async -> Bool {
        guard let client else { return false }
        do {
            try await client.saveSettings(formItems)
            InAppNotificationCenter.shared.showSuccess(title: "Linked App Saved", message: "\(appType.displayName) was saved in Bazarr.")
            await load()
            return true
        } catch {
            InAppNotificationCenter.shared.showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    private func disable(_ appType: BazarrLinkedApplicationType) async {
        guard let client else { return }
        do {
            try await client.saveSettings([
                URLQueryItem(name: "settings-general-\(appType.enabledSettingsKey)", value: "false")
            ])
            InAppNotificationCenter.shared.showSuccess(title: "Linked App Disabled", message: "\(appType.displayName) was disabled in Bazarr.")
            await load()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Disable Failed", message: error.localizedDescription)
        }
    }
}

private struct BazarrLinkedApplicationRow: View {
    let appType: BazarrLinkedApplicationType
    let settings: [String: JSONValue]

    private var isEnabled: Bool {
        settings.isBazarrLinkedApplicationEnabled(appType)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: appType.systemImage)
                .foregroundStyle(appType.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(appType.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(settings.bazarrLinkedApplicationBaseURL(appType) ?? "Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(isEnabled ? "Enabled" : "Disabled")
                    .font(.caption2)
                    .foregroundStyle(isEnabled ? Color.green : Color.secondary)
            }

            Spacer()

            Image(systemName: isEnabled ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isEnabled ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct BazarrLinkedApplicationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    let appType: BazarrLinkedApplicationType
    let settings: [String: JSONValue]
    let onSave: ([URLQueryItem]) async -> Bool

    @State private var isEnabled = true
    @State private var selectedProfileID = Self.customProfileID
    @State private var host = ""
    @State private var port = ""
    @State private var baseURL = "/"
    @State private var apiKey = ""
    @State private var ssl = false
    @State private var syncOnLive = true
    @State private var minimumScore = ""
    @State private var excludedTags = ""
    @State private var excludedSeriesTypes: Set<String> = []
    @State private var onlyMonitored = false
    @State private var deferSearch = false
    @State private var excludeSeasonZero = false
    @State private var httpTimeout = "60"
    @State private var seededAPIKey = ""
    @State private var localErrorMessage: String?
    @State private var isSaving = false
    @State private var hasLoadedInitialState = false

    private static let customProfileID = "custom"

    private var remoteProfiles: [ArrServiceProfile] {
        allProfiles
            .filter { $0.resolvedServiceType == appType.serviceType && $0.isEnabled }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedProfile: ArrServiceProfile? {
        remoteProfiles.first { $0.id.uuidString == selectedProfileID }
    }

    private var isUsingCustomServer: Bool {
        selectedProfile == nil
    }

    private var canSave: Bool {
        !isSaving &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) != nil &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Enabled", isOn: $isEnabled)

                    Picker("\(appType.displayName) Server", selection: $selectedProfileID) {
                        ForEach(remoteProfiles) { profile in
                            Text(profile.displayName).tag(profile.id.uuidString)
                        }
                        Text("Custom").tag(Self.customProfileID)
                    }
                }

                Section("Host") {
                    LabeledContent("Address") {
                        TextField("Hostname or IPv4 Address", text: $host)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .disabled(!isUsingCustomServer)
                    }

                    LabeledContent("Port") {
                        TextField("Port", text: $port)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .disabled(!isUsingCustomServer)
                    }

                    LabeledContent("Base URL") {
                        TextField("/", text: $baseURL)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .disabled(!isUsingCustomServer)
                    }

                    LabeledContent("HTTP Timeout") {
                        TextField("60", text: $httpTimeout)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("API Key") {
                        SecureField("API key", text: $apiKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    Toggle("SSL", isOn: $ssl)
                }

                Section("Options") {
                    Toggle("Sync on live connection", isOn: $syncOnLive)

                    LabeledContent(appType.minimumScoreLabel) {
                        TextField("Score", text: $minimumScore)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Excluded Tags") {
                        TextField("tag-one, tag-two", text: $excludedTags)
                            .multilineTextAlignment(.trailing)
                    }

                    if appType == .sonarr {
                        ForEach(BazarrSeriesType.allCases) { seriesType in
                            Toggle(
                                seriesType.displayName,
                                isOn: Binding(
                                    get: { excludedSeriesTypes.contains(seriesType.rawValue) },
                                    set: { selected in
                                        if selected {
                                            excludedSeriesTypes.insert(seriesType.rawValue)
                                        } else {
                                            excludedSeriesTypes.remove(seriesType.rawValue)
                                        }
                                    }
                                )
                            )
                        }

                        Toggle("Exclude season zero", isOn: $excludeSeasonZero)
                    }

                    Toggle("Download only monitored", isOn: $onlyMonitored)
                    Toggle("Defer searching until scheduled task", isOn: $deferSearch)
                }

                if let localErrorMessage {
                    Section {
                        Label(localErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Link \(appType.displayName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .task {
                await loadInitialStateIfNeeded()
            }
            .onChange(of: selectedProfileID) { _, _ in
                guard hasLoadedInitialState else { return }
                Task { await applySelectedProfile() }
            }
        }
    }

    private func loadInitialStateIfNeeded() async {
        guard !hasLoadedInitialState else { return }

        isEnabled = settings.isBazarrLinkedApplicationEnabled(appType)
        host = settings.bazarrSetting(appType.settingsSection, "ip") ?? ""
        port = settings.bazarrSetting(appType.settingsSection, "port") ?? appType.defaultPort
        baseURL = settings.bazarrSetting(appType.settingsSection, "base_url") ?? "/"
        httpTimeout = settings.bazarrSetting(appType.settingsSection, "http_timeout") ?? "60"
        apiKey = settings.bazarrSetting(appType.settingsSection, "apikey") ?? ""
        seededAPIKey = apiKey
        ssl = settings.bazarrBool(appType.settingsSection, "ssl")
        syncOnLive = settings.bazarrBool(appType.settingsSection, appType.syncOnLiveSettingsKey, defaultValue: true)
        minimumScore = settings.bazarrSetting("general", appType.minimumScoreSettingsKey) ?? appType.defaultMinimumScore
        excludedTags = settings.bazarrArray(appType.settingsSection, "excluded_tags").joined(separator: ", ")
        onlyMonitored = settings.bazarrBool(appType.settingsSection, "only_monitored")
        deferSearch = settings.bazarrBool(appType.settingsSection, appType.deferSearchSettingsKey)

        if appType == .sonarr {
            excludedSeriesTypes = Set(settings.bazarrArray("sonarr", "excluded_series_types"))
            excludeSeasonZero = settings.bazarrBool("sonarr", "exclude_season_zero")
        }

        selectedProfileID = matchingProfileID() ?? Self.customProfileID
        hasLoadedInitialState = true
        await applySelectedProfile()
    }

    private func applySelectedProfile() async {
        localErrorMessage = nil
        guard selectedProfileID != Self.customProfileID else {
            return
        }
        guard let selectedProfile else {
            return
        }

        do {
            let parsed = try ParsedServerURL(profileURL: selectedProfile.hostURL, defaultPort: appType.defaultPort)
            host = parsed.host
            port = parsed.port
            baseURL = parsed.baseURL
            ssl = parsed.isSSL
        } catch {
            localErrorMessage = error.localizedDescription
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty || trimmedKey == seededAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        do {
            let loaded = try await KeychainHelper.shared.read(key: selectedProfile.apiKeyKeychainKey) ?? ""
            apiKey = loaded
            seededAPIKey = loaded
        } catch {
            apiKey = ""
            seededAPIKey = ""
            localErrorMessage = "Couldn't load the saved API key: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard !isSaving else { return }

        localErrorMessage = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = normalizedBaseURL(baseURL)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            localErrorMessage = "Address is required."
            return
        }
        guard Int(trimmedPort) != nil else {
            localErrorMessage = "Port must be a number."
            return
        }
        guard !trimmedAPIKey.isEmpty else {
            localErrorMessage = "API key is required."
            return
        }

        var formItems: [URLQueryItem] = [
            URLQueryItem(name: "settings-general-\(appType.enabledSettingsKey)", value: isEnabled ? "true" : "false"),
            URLQueryItem(name: "settings-\(appType.settingsSection)-ip", value: trimmedHost),
            URLQueryItem(name: "settings-\(appType.settingsSection)-port", value: trimmedPort),
            URLQueryItem(name: "settings-\(appType.settingsSection)-base_url", value: trimmedBaseURL),
            URLQueryItem(name: "settings-\(appType.settingsSection)-http_timeout", value: httpTimeout.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "settings-\(appType.settingsSection)-apikey", value: trimmedAPIKey),
            URLQueryItem(name: "settings-\(appType.settingsSection)-ssl", value: ssl ? "true" : "false"),
            URLQueryItem(name: "settings-\(appType.settingsSection)-\(appType.syncOnLiveSettingsKey)", value: syncOnLive ? "true" : "false"),
            URLQueryItem(name: "settings-general-\(appType.minimumScoreSettingsKey)", value: minimumScore.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "settings-\(appType.settingsSection)-only_monitored", value: onlyMonitored ? "true" : "false"),
            URLQueryItem(name: "settings-\(appType.settingsSection)-\(appType.deferSearchSettingsKey)", value: deferSearch ? "true" : "false")
        ]

        let tags = excludedTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        formItems.append(contentsOf: formItemsForList(key: "settings-\(appType.settingsSection)-excluded_tags", values: tags))

        if appType == .sonarr {
            formItems.append(contentsOf: formItemsForList(
                key: "settings-sonarr-excluded_series_types",
                values: Array(excludedSeriesTypes).sorted()
            ))
            formItems.append(URLQueryItem(name: "settings-sonarr-exclude_season_zero", value: excludeSeasonZero ? "true" : "false"))
        }

        isSaving = true
        defer { isSaving = false }
        if await onSave(formItems) {
            dismiss()
        }
    }

    private func matchingProfileID() -> String? {
        guard !host.isEmpty else { return nil }
        let configuredURL = "\(ssl ? "https" : "http")://\(host):\(port)\(normalizedBaseURL(baseURL))"
        guard let configuredIdentifier = normalizedURLIdentifier(from: configuredURL) else { return nil }
        return remoteProfiles.first { profile in
            guard let profileIdentifier = normalizedURLIdentifier(from: profile.hostURL) else { return false }
            return profileIdentifier == configuredIdentifier
        }?.id.uuidString
    }

    private func normalizedURLIdentifier(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        guard let scheme = components.scheme, let host = components.host else { return nil }
        let defaultPort: Int
        if scheme == "https" {
            defaultPort = 443
        } else if scheme == "http" {
            defaultPort = 80
        } else {
            defaultPort = Int(appType.defaultPort) ?? 80
        }
        let port = components.port ?? defaultPort
        let path = components.path.isEmpty ? "/" : components.path
        return "\(scheme)://\(host):\(port)\(path)"
    }

    private func normalizedBaseURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func formItemsForList(key: String, values: [String]) -> [URLQueryItem] {
        if values.isEmpty {
            return [URLQueryItem(name: key, value: "")]
        }
        return values.map { URLQueryItem(name: key, value: $0) }
    }
}

private enum BazarrLinkedApplicationType: String, CaseIterable, Identifiable {
    case sonarr
    case radarr

    var id: String { rawValue }

    var serviceType: ArrServiceType {
        switch self {
        case .sonarr: .sonarr
        case .radarr: .radarr
        }
    }

    var displayName: String {
        switch self {
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        }
    }

    var systemImage: String {
        switch self {
        case .sonarr: "tv"
        case .radarr: "film"
        }
    }

    var color: Color {
        switch self {
        case .sonarr: .purple
        case .radarr: .orange
        }
    }

    var settingsSection: String { rawValue }

    var enabledSettingsKey: String {
        switch self {
        case .sonarr: "use_sonarr"
        case .radarr: "use_radarr"
        }
    }

    var defaultPort: String {
        switch self {
        case .sonarr: "8989"
        case .radarr: "7878"
        }
    }

    var syncOnLiveSettingsKey: String {
        switch self {
        case .sonarr: "series_sync_on_live"
        case .radarr: "movies_sync_on_live"
        }
    }

    var minimumScoreSettingsKey: String {
        switch self {
        case .sonarr: "minimum_score"
        case .radarr: "minimum_score_movie"
        }
    }

    var minimumScoreLabel: String {
        switch self {
        case .sonarr: "Minimum Score For Episodes"
        case .radarr: "Minimum Score For Movies"
        }
    }

    var defaultMinimumScore: String {
        switch self {
        case .sonarr: "90"
        case .radarr: "70"
        }
    }

    var deferSearchSettingsKey: String {
        switch self {
        case .sonarr: "defer_search_signalr"
        case .radarr: "defer_search_signalr"
        }
    }
}

private enum BazarrSeriesType: String, CaseIterable, Identifiable {
    case standard
    case anime
    case daily

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Exclude standard series"
        case .anime: "Exclude anime"
        case .daily: "Exclude daily series"
        }
    }
}

private struct ParsedServerURL {
    let host: String
    let port: String
    let baseURL: String
    let isSSL: Bool

    init(profileURL: String, defaultPort: String) throws {
        guard let components = URLComponents(string: profileURL) else {
            throw ArrError.invalidURL
        }
        guard let scheme = components.scheme, let parsedHost = components.host else {
            throw ArrError.invalidURL
        }
        host = parsedHost
        isSSL = scheme == "https"
        let defaultPortInt = isSSL ? 443 : (Int(defaultPort) ?? 80)
        port = String(components.port ?? defaultPortInt)
        baseURL = components.path.isEmpty ? "/" : components.path
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func isBazarrLinkedApplicationEnabled(_ appType: BazarrLinkedApplicationType) -> Bool {
        bazarrBool("general", appType.enabledSettingsKey)
    }

    func bazarrLinkedApplicationBaseURL(_ appType: BazarrLinkedApplicationType) -> String? {
        guard let host = bazarrSetting(appType.settingsSection, "ip"), !host.isEmpty else { return nil }
        let port = bazarrSetting(appType.settingsSection, "port") ?? appType.defaultPort
        let baseURL = bazarrSetting(appType.settingsSection, "base_url") ?? "/"
        let ssl = bazarrBool(appType.settingsSection, "ssl")
        return "\(ssl ? "https" : "http")://\(host):\(port)\(baseURL == "/" ? "" : baseURL)"
    }

    func bazarrSetting(_ section: String, _ key: String) -> String? {
        guard case .object(let sectionValues)? = self[section],
              let value = sectionValues[key] else {
            return nil
        }

        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .array(let array):
            return array.compactMap {
                guard case .string(let value) = $0 else { return nil }
                return value
            }.joined(separator: ", ")
        case .object, .null:
            return nil
        }
    }

    func bazarrBool(_ section: String, _ key: String, defaultValue: Bool = false) -> Bool {
        guard case .object(let sectionValues)? = self[section],
              let value = sectionValues[key] else {
            return defaultValue
        }

        switch value {
        case .bool(let bool):
            return bool
        case .string(let string):
            return ["true", "1", "yes"].contains(string.lowercased())
        case .number(let number):
            return number != 0
        case .array, .object, .null:
            return defaultValue
        }
    }

    func bazarrArray(_ section: String, _ key: String) -> [String] {
        guard case .object(let sectionValues)? = self[section],
              let value = sectionValues[key] else {
            return []
        }

        switch value {
        case .array(let array):
            return array.compactMap {
                guard case .string(let value) = $0, !value.isEmpty else { return nil }
                return value
            }
        case .string(let string):
            return string
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .number, .bool, .object, .null:
            return []
        }
    }
}
