import SwiftUI

/// SABnzbd's Usenet servers, read from `get_config&section=servers`.
///
/// Supports native 3-column split view navigation on iPadOS and macOS with detail pane,
/// and standard push navigation on compact iPhone.
struct SABnzbdNewsServersView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(SABnzbdNewsServerBrowserState.self) private var sharedBrowser: SABnzbdNewsServerBrowserState?
    @State private var localBrowser = SABnzbdNewsServerBrowserState()

    private var browser: SABnzbdNewsServerBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var servers: [SABnzbdNewsServer] { serviceManager.newsServers }

    var body: some View {
        @Bindable var browser = self.browser
        Group {
            if showsDetailPane {
                TrawlListDetailPanes(title: "News Servers", subtitle: "SABnzbd") {
                    serverList
                } detail: {
                    selectedServerDetail
                }
                .task {
                    guard sidebarColumn != .detail else { return }
                    await serviceManager.refreshNewsServers()
                }
                .onDisappear {
                    guard sidebarColumn != .detail else { return }
                    serviceManager.clearNewsServers()
                }
            } else {
                compactContent
            }
        }
        .sheet(item: $browser.editorTarget) { target in
            SABnzbdNewsServerEditorSheet(existingServer: target.server) {
                browser.editorTarget = nil
            }
            .environment(serviceManager)
        }
        .alert(
            "Delete Server?",
            isPresented: Binding(
                get: { browser.serverPendingDeletion != nil },
                set: { if !$0 { browser.serverPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let server = browser.serverPendingDeletion else { return }
                browser.serverPendingDeletion = nil
                Task { await delete(server) }
            }
            Button("Cancel", role: .cancel) { browser.serverPendingDeletion = nil }
        } message: {
            Text("This removes the server from SABnzbd's configuration.")
        }
        .alert(
            "Couldn't Delete Server",
            isPresented: Binding(
                get: { browser.actionError != nil },
                set: { if !$0 { browser.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { browser.actionError = nil }
        } message: {
            Text(browser.actionError ?? "")
        }
    }

    // MARK: - Split View List Column

    @ViewBuilder
    private var serverList: some View {
        @Bindable var browser = self.browser
        List(selection: $browser.selectedServerID) {
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
                            browser.editorTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: nil)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(servers) { server in
                        serverRow(server)
                            .tag(server.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    browser.serverPendingDeletion = server
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
        .scrollContentBackground(.hidden)
        .moreDestinationBackground(.newsServers)
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button {
                    browser.editorTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: nil)
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .refreshable { await serviceManager.refreshNewsServers() }
        .onChange(of: servers.map(\.id), initial: true) { _, _ in
            browser.reconcileSelection(servers: servers)
        }
    }

    // MARK: - Split View Detail Column

    @ViewBuilder
    private var selectedServerDetail: some View {
        if let selectedID = browser.selectedServerID,
           let server = servers.first(where: { $0.id == selectedID }) {
            SABnzbdNewsServerDetailPane(
                server: server,
                onEdit: {
                    browser.editorTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: server)
                },
                onDelete: {
                    browser.serverPendingDeletion = server
                }
            )
            .id(server.id)
        } else if servers.isEmpty {
            listDetailPlaceholder("No News Servers", systemImage: "server.rack")
        } else {
            listDetailPlaceholder("Select a News Server", systemImage: "server.rack")
        }
    }

    // MARK: - Compact Content (iPhone)

    @ViewBuilder
    private var compactContent: some View {
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
                            browser.editorTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: nil)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(servers) { server in
                        NavigationLink {
                            SABnzbdNewsServerDetailPane(
                                server: server,
                                onEdit: {
                                    browser.editorTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: server)
                                },
                                onDelete: {
                                    browser.serverPendingDeletion = server
                                }
                            )
                        } label: {
                            serverRow(server)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                browser.serverPendingDeletion = server
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
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button {
                    browser.editorTarget = SABnzbdNewsServerBrowserState.EditorTarget(server: nil)
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .refreshable { await serviceManager.refreshNewsServers() }
        .task { await serviceManager.refreshNewsServers() }
        .onDisappear { serviceManager.clearNewsServers() }
    }

    // MARK: - Shared Server Row

    private func serverRow(_ server: SABnzbdNewsServer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Label(
                    server.enabled ? "Enabled" : "Disabled",
                    systemImage: server.enabled ? "circle.fill" : "circle"
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
            browser.actionError = error.localizedDescription
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

// MARK: - News Server Detail Pane

struct SABnzbdNewsServerDetailPane: View {
    let server: SABnzbdNewsServer
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @State private var isTesting = false
    @State private var testOutcome: (succeeded: Bool, message: String)?
    @State private var testErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                connectionCard
                credentialsCard
                if let notes = server.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notesCard(notes)
                }
                testConnectionCard
                actionsCard
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .paneAwareNavigationTitle(server.title, subtitle: "SABnzbd", whenPane: server.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            #endif
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(ServiceIdentity.sabnzbd.brandColor)
                        .frame(width: 44, height: 44)
                        .background(ServiceIdentity.sabnzbd.brandColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.title)
                            .font(.title2.weight(.bold))

                        Text(server.hostLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                Label(
                    server.enabled ? "Enabled" : "Disabled",
                    systemImage: server.enabled ? "checkmark.circle.fill" : "circle.slash"
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (server.enabled ? Color.green : Color.secondary).opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(server.enabled ? .green : .secondary)
            }

            HStack(spacing: 8) {
                if let priority = server.priority {
                    Label("Priority \(priority)", systemImage: "arrow.up.and.down.circle")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                Label(server.ssl ? "SSL Encrypted" : "Plaintext", systemImage: server.ssl ? "lock.fill" : "lock.open")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())

                if server.optional {
                    Label("Optional / Backup", systemImage: "shield")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection & Transport", systemImage: "network")
                .font(.headline)
                .foregroundStyle(ServiceIdentity.sabnzbd.brandColor)

            Divider()

            VStack(spacing: 10) {
                detailRow("Host", value: server.host, textSelection: true)
                detailRow("Port", value: String(server.port))
                detailRow("SSL / TLS", value: server.ssl ? "Enabled" : "Disabled")
                detailRow("Cert Verification", value: sslVerifyDescription)
                detailRow("Connections", value: String(server.connections))
                detailRow("Retention", value: server.retention.flatMap { $0 > 0 ? "\($0) days" : nil } ?? "Unlimited / Server Default")
                detailRow("Timeout", value: server.timeout.flatMap { $0 > 0 ? "\($0)s" : nil } ?? "Default")
                detailRow("Role", value: server.optional ? "Optional (Fill Server)" : "Primary Server")
                if let priority = server.priority {
                    detailRow("Priority", value: String(priority))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Authentication", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(ServiceIdentity.sabnzbd.brandColor)

            Divider()

            VStack(spacing: 10) {
                detailRow("Username", value: server.username.flatMap { $0.isEmpty ? nil : $0 } ?? "None")
                detailRow("Password", value: (server.password?.isEmpty == false) ? "••••••••" : "None")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes", systemImage: "note.text")
                .font(.headline)
                .foregroundStyle(ServiceIdentity.sabnzbd.brandColor)

            Divider()

            Text(notes)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var testConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection Test", systemImage: "bolt.horizontal.circle")
                .font(.headline)
                .foregroundStyle(ServiceIdentity.sabnzbd.brandColor)

            Text("Verify that SABnzbd can connect and authenticate with this Usenet server.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await runConnectionTest() }
            } label: {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing Connection…")
                    } else {
                        Image(systemName: "play.fill")
                        Text("Test Connection")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ServiceIdentity.sabnzbd.brandColor)
            .disabled(isTesting)

            if let outcome = testOutcome {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(outcome.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.succeeded ? "Connection Succeeded" : "Connection Failed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(outcome.succeeded ? .green : .red)
                        if !outcome.message.isEmpty {
                            Text(outcome.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((outcome.succeeded ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let error = testErrorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test Error")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Actions", systemImage: "slider.horizontal.3")
                .font(.headline)
                .foregroundStyle(ServiceIdentity.sabnzbd.brandColor)

            Divider()

            HStack(spacing: 12) {
                Button(action: onEdit) {
                    Label("Edit Server", systemImage: "pencil")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete Server", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detailRow(_ label: String, value: String, textSelection: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if textSelection {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var sslVerifyDescription: String {
        guard let verify = server.sslVerify else { return "Default" }
        switch verify {
        case 0: return "Disabled"
        case 1: return "Default"
        case 2, 3: return "Strict"
        default: return "\(verify)"
        }
    }

    private func runConnectionTest() async {
        isTesting = true
        testOutcome = nil
        testErrorMessage = nil
        defer { isTesting = false }

        do {
            let result = try await serviceManager.testNewsServer(server)
            testOutcome = result
        } catch {
            testErrorMessage = error.localizedDescription
        }
    }
}
