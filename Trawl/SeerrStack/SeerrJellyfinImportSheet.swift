import SwiftUI

struct SeerrJellyfinImportSheet: View {
    let apiClient: SeerrAPIClient
    let onImport: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var availableUsers: [SeerrJellyfinUser] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = false
    @State private var loadError: String?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: SeerrAPIClient, onImport: @escaping ([String]) -> Void) {
        self.apiClient = apiClient
        self.onImport = onImport
    }

    var body: some View {
        AppSheetShell(
            title: "Import from Jellyfin",
            subtitle: selectedIDs.isEmpty ? nil : "\(selectedIDs.count) selected",
            confirmTitle: "Import",
            isConfirmDisabled: selectedIDs.isEmpty,
            onConfirm: {
                onImport(Array(selectedIDs))
                dismiss()
            },
            detents: [.medium, .large]
        ) {
            Group {
                if isLoading && availableUsers.isEmpty {
                    ProgressView("Fetching Jellyfin users…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError, availableUsers.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Users", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await loadUsers() } }
                            .buttonStyle(.bordered)
                    }
                } else if availableUsers.isEmpty {
                    ContentUnavailableView(
                        "No Jellyfin Users",
                        systemImage: "person.2.slash",
                        description: Text("Seerr didn't return any Jellyfin accounts to import.")
                    )
                } else {
                    userList
                }
            }
            .task {
                #if DEBUG
                if isPreview { return }
                #endif
                if availableUsers.isEmpty { await loadUsers() }
            }
            .refreshable { await loadUsers() }
        }
    }

    /// Selection is the List's own rather than a checkmark drawn per row. The sheet
    /// exists only to pick users, so edit mode is pinned on: there is no second mode
    /// to enter, and the rows get the system's ticks, hit targets and accessibility.
    private var userList: some View {
        List(selection: $selectedIDs) {
            Section {
                ForEach(availableUsers) { user in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let email = user.email, !email.isEmpty, email != user.displayName {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            } header: {
                Text("Jellyfin Users")
            } footer: {
                Text("Selected accounts will be imported as Seerr users.")
            }

            Section {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(availableUsers.map(\.id))
                    }
                }
                .selectionDisabled()
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        // `EditMode` is iOS-only and this file compiles into TrawlMac; macOS gets
        // List's native click selection instead.
        .environment(\.editMode, .constant(.active))
        #else
        .listStyle(.inset)
        #endif
    }

    private var allSelected: Bool {
        !availableUsers.isEmpty && selectedIDs.count == availableUsers.count
    }

    private func loadUsers() async {
        isLoading = true
        loadError = nil
        do {
            availableUsers = try await apiClient.getJellyfinUsers()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#if DEBUG
extension SeerrJellyfinImportSheet {
    init(
        apiClient: SeerrAPIClient = .preview(),
        previewUsers: [SeerrJellyfinUser],
        selectedIDs: Set<String> = [],
        isLoading: Bool = false,
        loadError: String? = nil,
        onImport: @escaping ([String]) -> Void = { _ in }
    ) {
        self.apiClient = apiClient
        self.onImport = onImport
        self._availableUsers = State(initialValue: previewUsers)
        self._selectedIDs = State(initialValue: selectedIDs)
        self._isLoading = State(initialValue: isLoading)
        self._loadError = State(initialValue: loadError)
        self.isPreview = true
    }
}

#Preview("Seerr Jellyfin Import - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        SeerrJellyfinImportSheet(
            previewUsers: SeerrJellyfinUser.previewList,
            selectedIDs: [SeerrJellyfinUser.preview.id]
        )
    }
}

#Preview("Seerr Jellyfin Import - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        SeerrJellyfinImportSheet(previewUsers: [])
    }
}

#Preview("Seerr Jellyfin Import - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        SeerrJellyfinImportSheet(previewUsers: [], isLoading: true)
    }
}

#Preview("Seerr Jellyfin Import - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to load Jellyfin users."))) {
        SeerrJellyfinImportSheet(
            previewUsers: [],
            loadError: "Seerr could not reach Jellyfin."
        )
    }
}
#endif
