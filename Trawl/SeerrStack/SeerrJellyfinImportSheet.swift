import SwiftUI

struct SeerrJellyfinImportSheet: View {
    let apiClient: SeerrAPIClient
    let onImport: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var availableUsers: [SeerrJellyfinUser] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Import from Jellyfin")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Import from Jellyfin")
                            .font(.headline)
                        if !selectedIDs.isEmpty {
                            Text("\(selectedIDs.count) selected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .animation(.default, value: selectedIDs.count)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(Array(selectedIDs))
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .task {
                if availableUsers.isEmpty { await loadUsers() }
            }
            .refreshable { await loadUsers() }
        }
        .presentationDetents([.medium, .large])
    }

    private var userList: some View {
        List {
            Section {
                ForEach(availableUsers) { user in
                    Button {
                        toggle(user.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(user.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(user.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

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
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    private var allSelected: Bool {
        !availableUsers.isEmpty && selectedIDs.count == availableUsers.count
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
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
