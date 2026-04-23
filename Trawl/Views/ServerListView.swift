import SwiftUI
import SwiftData

struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Query(sort: \ServerProfile.dateAdded) private var servers: [ServerProfile]

    @State private var showAddSheet = false
    @State private var serverToEdit: ServerProfile?
    @State private var pendingDeletion: ServerProfile?
    @State private var isDeleting = false

    var body: some View {
        List {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "server.rack",
                    description: Text("Add a qBittorrent server to switch between multiple instances.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Servers") {
                    ForEach(servers) { server in
                        Button {
                            if server.isActive {
                                serverToEdit = server
                            } else {
                                switchToServer(server)
                            }
                        } label: {
                            serverRow(server)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = server
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Servers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .sheet(item: $serverToEdit) { server in
            OnboardingSheet(serverProfile: server) {}
        }
        .sheet(isPresented: $showAddSheet) {
            OnboardingSheet(serverProfile: nil) {}
        }
        .alert("Delete Server?", isPresented: deleteAlertBinding, presenting: pendingDeletion) { server in
            Button("Delete", role: .destructive) {
                Task { await deleteServer(server) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { server in
            Text("This removes \(server.displayName) and deletes its stored credentials.")
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    @ViewBuilder
    private func serverRow(_ server: ServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(server.isActive ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(server.hostURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let lastConnected = server.lastConnected {
                    Text("Last connected \(lastConnected.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if server.isActive {
                Circle()
                    .fill(syncService.isPolling ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private func switchToServer(_ server: ServerProfile) {
        for existing in servers {
            existing.isActive = (existing.id == server.id)
        }
        do {
            try modelContext.save()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Switch Server",
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func deleteServer(_ server: ServerProfile) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer {
            isDeleting = false
            pendingDeletion = nil
        }

        do {
            try await KeychainHelper.shared.delete(key: server.usernameKey)
            try await KeychainHelper.shared.delete(key: server.passwordKey)
        } catch {
            return
        }

        let wasActive = server.isActive
        let replacement = servers.first { $0.id != server.id }
        modelContext.delete(server)

        if wasActive {
            replacement?.isActive = true
        }

        do {
            try modelContext.save()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Delete Server",
                message: error.localizedDescription
            )
        }
    }
}
