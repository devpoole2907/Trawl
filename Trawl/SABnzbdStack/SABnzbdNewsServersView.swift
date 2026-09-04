import SwiftUI

/// SABnzbd's Usenet servers, read from `get_config&section=servers`.
///
/// Editing writes back through `set_config&section=servers`. The payload carries
/// credentials, so the list is loaded on demand and dropped again on disappear
/// rather than living in the poll.
struct SABnzbdNewsServersView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager

    @State private var editorTarget: EditorTarget?
    @State private var serverPendingDeletion: SABnzbdNewsServer?
    @State private var actionError: String?

    /// `server == nil` is the add case. Wrapped in an Identifiable box so one
    /// `.sheet(item:)` covers both add and edit.
    private struct EditorTarget: Identifiable {
        let server: SABnzbdNewsServer?
        var id: String { server?.id ?? "new-server" }
    }

    private var servers: [SABnzbdNewsServer] { serviceManager.newsServers }

    var body: some View {
        List {
            if let error = serviceManager.newsServersError {
                ServiceErrorView(
                    title: "News Servers Unavailable",
                    message: error,
                    identity: .sabnzbd,
                    hasContent: !servers.isEmpty,
                    onRetry: { await serviceManager.refreshNewsServers() }
                )
            }

            if servers.isEmpty {
                if serviceManager.isLoadingNewsServers {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading servers…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if serviceManager.newsServersError == nil {
                    Section {
                        Text("SABnzbd has no news servers configured.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Add Server", systemImage: "plus") {
                            editorTarget = EditorTarget(server: nil)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(servers) { server in
                        Button {
                            editorTarget = EditorTarget(server: server)
                        } label: {
                            serverRow(server)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                serverPendingDeletion = server
                            }
                        }
                    }
                } header: {
                    Text(servers.count == 1 ? "1 Server" : "\(servers.count) Servers")
                } footer: {
                    Text("Changes are written straight to SABnzbd's own configuration.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("News Servers")
        .navigationSubtitle("SABnzbd")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = EditorTarget(server: nil)
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .refreshable { await serviceManager.refreshNewsServers() }
        .task { await serviceManager.refreshNewsServers() }
        .onDisappear { serviceManager.clearNewsServers() }
        .sheet(item: $editorTarget) { target in
            SABnzbdNewsServerEditorSheet(existingServer: target.server) {
                editorTarget = nil
            }
            .environment(serviceManager)
        }
        .alert(
            "Delete Server?",
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let server = serverPendingDeletion else { return }
                serverPendingDeletion = nil
                Task { await delete(server) }
            }
            Button("Cancel", role: .cancel) { serverPendingDeletion = nil }
        } message: {
            Text("This removes the server from SABnzbd's configuration.")
        }
        .alert(
            "Couldn't Delete Server",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func serverRow(_ server: SABnzbdNewsServer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Label(
                    server.enabled ? "Enabled" : "Disabled",
                    systemImage: "circle.fill"
                )
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(server.enabled ? .green : .secondary)
            }

            Text(server.hostLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(chips(for: server), id: \.self) { chip in
                    Text(chip)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func delete(_ server: SABnzbdNewsServer) async {
        do {
            try await serviceManager.deleteNewsServer(name: server.name)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func chips(for server: SABnzbdNewsServer) -> [String] {
        var chips: [String] = []
        chips.append(server.connections == 1 ? "1 connection" : "\(server.connections) connections")
        chips.append(server.ssl ? "SSL" : "No SSL")
        if server.optional { chips.append("Optional") }
        if let retention = server.retention, retention > 0 {
            chips.append("\(retention)d retention")
        }
        if let priority = server.priority {
            chips.append("Priority \(priority)")
        }
        return chips
    }
}
