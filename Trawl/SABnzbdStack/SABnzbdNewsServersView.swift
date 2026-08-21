import SwiftUI

/// SABnzbd's Usenet servers, read from `get_config&section=servers`.
///
/// Read-only for now: creating and editing these means handling a Usenet password
/// in a form field, which is a deliberate second step rather than something to
/// inherit by accident.
struct SABnzbdNewsServersView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager

    private var servers: [SABnzbdNewsServer] { serviceManager.newsServers }

    var body: some View {
        List {
            if let error = serviceManager.newsServersError {
                Section("Unavailable") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    }
                }
            } else {
                Section {
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                } header: {
                    Text(servers.count == 1 ? "1 Server" : "\(servers.count) Servers")
                } footer: {
                    Text("Servers are configured in SABnzbd itself. Trawl shows them here so you can check what's set without leaving the app.")
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
        .refreshable { await serviceManager.refreshNewsServers() }
        .task { await serviceManager.refreshNewsServers() }
        .onDisappear { serviceManager.clearNewsServers() }
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
