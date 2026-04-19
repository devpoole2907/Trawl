import SwiftUI
import SwiftData

struct ShareAddTorrentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ServerProfile> { $0.isActive }) private var activeServers: [ServerProfile]

    let magnetURL: String?
    let torrentFileData: Data?
    let torrentFileName: String?
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var savePath: String = ""
    @State private var selectedCategory: String = ""
    @State private var startPaused: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var error: String?
    @State private var availableCategories: [String] = []

    var body: some View {
        NavigationStack {
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
                        sequentialDownload: false
                    )
                } else if let fileData = torrentFileData, let fileName = torrentFileName {
                    try await apiClient.addTorrentFile(
                        fileData: fileData,
                        fileName: fileName,
                        savePath: path,
                        category: category,
                        paused: startPaused,
                        sequentialDownload: false
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

            let authService = AuthService(serverProfileID: server.id, allowsUntrustedTLS: server.allowsUntrustedTLS)
            let apiClient = QBittorrentAPIClient(
                baseURL: server.hostURL,
                authService: authService,
                allowsUntrustedTLS: server.allowsUntrustedTLS
            )
            try await apiClient.login(username: username, password: password)

            let cats = try await apiClient.getCategories()
            availableCategories = cats.keys.sorted()

            // Pre-fill default save path
            if let prefs = try? await apiClient.getPreferences(), let defaultPath = prefs.savePath {
                if savePath.isEmpty {
                    savePath = defaultPath
                }
            }
        } catch {
            // Non-critical — categories just won't be available
        }
    }

    private var hasPayload: Bool {
        magnetURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
        (torrentFileData != nil && torrentFileName != nil)
    }
}
