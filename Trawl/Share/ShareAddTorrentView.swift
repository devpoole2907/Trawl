import SwiftUI
import SwiftData

struct ShareAddTorrentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ServerProfile> { $0.isActive }) private var activeServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    let magnetURL: String?
    let torrentFileData: Data?
    let torrentFileName: String?
    let nzbURL: String?
    let nzbFileData: Data?
    let nzbFileName: String?
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var savePath: String = ""
    @State private var selectedCategory: String = ""
    @State private var startPaused: Bool = false
    @State private var sequentialDownload: Bool = false
    @State private var firstLastPiecePriority: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var error: String?
    @State private var availableCategories: [String] = []

    var body: some View {
        NavigationStack {
            if isNZB {
                nzbForm
            } else {
                torrentForm
            }
        }
    }

    // MARK: - Torrent

    private var torrentForm: some View {
        Form {
                // What we're adding
                Section("Torrent") {
                    if let magnet = magnetURL {
                        Text(magnet)
                            .font(.caption)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    } else if let fileName = torrentFileName {
                        Label(fileName, systemImage: "doc.fill")
                    }
                }

                // Server info
                Section("Server") {
                    if let server = activeServers.first {
                        HStack {
                            Text(server.displayName)
                            Spacer()
                            Text(server.hostURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("No server configured. Open Trawl to add one.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                // Options
                Section("Options") {
                    TextField("Save Path (default)", text: $savePath)
                        .textInputAutocapitalization(.never)

                    if !availableCategories.isEmpty {
                        Picker("Category", selection: $selectedCategory) {
                            Text("None").tag("")
                            ForEach(availableCategories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                        }
                    }

                    Toggle("Start Paused", isOn: $startPaused)
                    Toggle("Sequential Download", isOn: $sequentialDownload)
                    Toggle("First and Last Pieces First", isOn: $firstLastPiecePriority)
                }

                // Status
                if isSubmitting {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Sending to server...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
        .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(activeServers.isEmpty || isSubmitting || !hasPayload)
                }
            }
            .task {
                await loadCategories()
            }
    }

    // MARK: - NZB

    /// SABnzbd's own defaults cover category, priority and post-processing, so the
    /// share sheet stays a confirm-and-send - the full option set lives in the
    /// app's Add Download sheet.
    private var nzbForm: some View {
        Form {
            Section("NZB") {
                if let nzbFileName {
                    Label(nzbFileName, systemImage: "doc.fill")
                } else if let nzbURL {
                    Text(nzbURL)
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Server") {
                if let profile = activeSABnzbdProfile {
                    HStack {
                        Text(profile.displayName)
                        Spacer()
                        Text(profile.hostURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("No SABnzbd server configured. Open Trawl to add one.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if isSubmitting {
                Section {
                    HStack {
                        ProgressView()
                        Text("Sending to SABnzbd...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Add NZB")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { submitNZB() }
                    .disabled(activeSABnzbdProfile == nil || isSubmitting)
            }
        }
    }

    private var isNZB: Bool {
        nzbFileData != nil || nzbURL?.isEmpty == false
    }

    private var activeSABnzbdProfile: SABnzbdServiceProfile? {
        sabnzbdProfiles.first(where: { $0.isEnabled }) ?? sabnzbdProfiles.first
    }

    private func submitNZB() {
        guard let profile = activeSABnzbdProfile else {
            error = "No SABnzbd server configured."
            return
        }

        isSubmitting = true
        error = nil

        let link = nzbURL
        let data = nzbFileData
        let name = nzbFileName

        Task {
            do {
                let apiKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey) ?? ""
                guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.error = "SABnzbd API key not found. Open Trawl and add the server again."
                    isSubmitting = false
                    return
                }

                // The share extension is a separate process, so - exactly as the
                // qBittorrent path does - it talks to the server itself rather than
                // through the app's service manager. `SABnzbdAPIClient` isn't compiled
                // into this target, so the two add calls are issued over the shared
                // `HTTPTransport` directly.
                let sender = ShareNZBSender(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )

                if let data, let name {
                    try await sender.addFile(data: data, filename: name)
                } else if let link, let url = URL(string: link) {
                    try await sender.addURL(url)
                } else {
                    self.error = "No NZB file or link was provided."
                    isSubmitting = false
                    return
                }

                onComplete()
            } catch {
                self.error = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    private func submit() {
        guard hasPayload else {
            error = "No torrent link or file was provided."
            return
        }

        guard let server = activeServers.first else {
            error = "No server configured."
            return
        }

        isSubmitting = true
        error = nil

        Task {
            do {
                let username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
                let password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""

                let authService = AuthService(serverProfileID: server.id, allowsUntrustedTLS: server.allowsUntrustedTLS)
                let apiClient = QBittorrentAPIClient(
                    baseURL: server.hostURL,
                    authService: authService,
                    allowsUntrustedTLS: server.allowsUntrustedTLS
                )
                try await apiClient.login(username: username, password: password)

                let path = savePath.isEmpty ? nil : savePath
                let category = selectedCategory.isEmpty ? nil : selectedCategory

                if let magnet = magnetURL {
                    try await apiClient.addTorrentMagnet(
                        magnetURL: magnet,
                        savePath: path,
                        category: category,
                        paused: startPaused,
                        sequentialDownload: sequentialDownload,
                        firstLastPiecePriority: firstLastPiecePriority
                    )
                } else if let fileData = torrentFileData, let fileName = torrentFileName {
                    try await apiClient.addTorrentFile(
                        fileData: fileData,
                        fileName: fileName,
                        savePath: path,
                        category: category,
                        paused: startPaused,
                        sequentialDownload: sequentialDownload,
                        firstLastPiecePriority: firstLastPiecePriority
                    )
                }

                // Persist save path
                if let path, !path.isEmpty {
                    let descriptor = FetchDescriptor<RecentSavePath>(predicate: #Predicate { $0.path == path })
                    if let existing = try? modelContext.fetch(descriptor).first {
                        existing.lastUsed = .now
                        existing.useCount += 1
                    } else {
                        modelContext.insert(RecentSavePath(path: path))
                    }
                    try? modelContext.save()
                }

                onComplete()
            } catch {
                self.error = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    private func loadCategories() async {
        guard let server = activeServers.first else { return }

        do {
            let username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
            let password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""

            let apiClient = try await QBittorrentClientFactory.makeAndLogin(
                baseURL: server.hostURL,
                serverProfileID: server.id,
                allowsUntrustedTLS: server.allowsUntrustedTLS,
                username: username,
                password: password
            )

            let cats = try await apiClient.getCategories()
            availableCategories = cats.keys.sorted()

            // Pre-fill default save path
            if let prefs = try? await apiClient.getPreferences(), let defaultPath = prefs.savePath {
                if savePath.isEmpty {
                    savePath = defaultPath
                }
            }
        } catch {
            // Non-critical - categories just won't be available
        }
    }

    private var hasPayload: Bool {
        magnetURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
        (torrentFileData != nil && torrentFileName != nil)
    }
}

/// Minimal SABnzbd `addfile` / `addurl` sender for the share extension.
/// `SABnzbdStack/SABnzbdAPIClient.swift` is excluded from the TrawlShare target,
/// so this mirrors just the two add calls over the shared `HTTPTransport`, the
/// same way the qBittorrent path builds its own client in-process.
private nonisolated struct ShareNZBSender {
    private let transport: HTTPTransport
    private let apiKey: String
    private let apiPath: String

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        self.apiKey = apiKey
        self.apiPath = Self.hasAPIPath(trimmed) ? "" : "/api"
        self.transport = HTTPTransport(
            baseURL: trimmed,
            auth: .none,
            allowsUntrustedTLS: allowsUntrustedTLS,
            errorMapper: HTTPErrorMapper(
                badURL: { ShareNZBError.message("The SABnzbd server URL is invalid.") },
                transport: { error in error },
                unauthorized: { ShareNZBError.message("SABnzbd rejected the API key.") },
                http: { code, body in ShareNZBError.message("SABnzbd returned HTTP \(code). \(body ?? "")") },
                decode: { _ in ShareNZBError.message("SABnzbd sent an unexpected response.") },
                invalidResponse: { ShareNZBError.message("SABnzbd sent an unexpected response.") },
                unauthorizedStatusCodes: [401, 403]
            )
        )
    }

    func addURL(_ url: URL) async throws {
        let response: Response = try await transport.get(
            apiPath,
            queryItems: commonItems + [
                URLQueryItem(name: "mode", value: "addurl"),
                URLQueryItem(name: "name", value: url.absoluteString)
            ]
        )
        try validate(response)
    }

    func addFile(data: Data, filename: String) async throws {
        guard !data.isEmpty else { throw ShareNZBError.message("That NZB file is empty.") }
        let response: Response = try await transport.postMultipart(
            apiPath,
            fileData: data,
            fieldName: "nzbfile",
            filename: filename,
            mimeType: "application/x-nzb",
            formItems: [URLQueryItem(name: "mode", value: "addfile")],
            queryItems: commonItems
        )
        try validate(response)
    }

    private var commonItems: [URLQueryItem] {
        [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
    }

    private func validate(_ response: Response) throws {
        if response.status == false {
            throw ShareNZBError.message(response.error ?? "SABnzbd refused the NZB.")
        }
    }

    private static func hasAPIPath(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .last?
            .lowercased() == "api"
    }

    struct Response: Decodable, Sendable {
        let status: Bool?
        let error: String?
    }
}

private nonisolated enum ShareNZBError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
