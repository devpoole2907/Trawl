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
                    Task { await delete(server) }
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
                                    Task { await delete(server) }
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
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            // Match the other administration inspectors: establish the selected
            // server's identity before presenting its grouped settings.
            Section {
                TrawlEntityHeader(
                    title: server.title,
                    subtitle: "SABnzbd · \(server.hostLine)",
                    systemImage: "server.rack",
                    tint: ServiceIdentity.sabnzbd.brandColor,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            Section("Connection") {
                detailRow("Host", value: server.host)
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

            Section("Authentication") {
                detailRow("Username", value: server.username.flatMap { $0.isEmpty ? nil : $0 } ?? "None")
                detailRow("Password", value: (server.password?.isEmpty == false) ? "••••••••" : "None")
            }

            if let notes = server.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Connection Test") {
                Text("Verify that SABnzbd can connect and authenticate with this Usenet server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await runConnectionTest() }
                } label: {
                    Label(
                        isTesting ? "Testing Connection…" : "Test Connection",
                        systemImage: isTesting ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                    )
                }
                .disabled(isTesting)

                if isTesting {
                    HStack {
                        ProgressView()
                        Text("Testing…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let outcome = testOutcome {
                    Label(
                        outcome.message.isEmpty
                            ? (outcome.succeeded ? "Connection Succeeded" : "Connection Failed")
                            : "\(outcome.succeeded ? "Connection Succeeded" : "Connection Failed"): \(outcome.message)",
                        systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(outcome.succeeded ? .green : .red)
                } else if let error = testErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Edit Server", systemImage: "pencil", action: onEdit)
            }

            Section {
                Button("Delete Server", systemImage: "trash", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .confirmationDialog(
                    "Delete Server?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive, action: onDelete)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the server from SABnzbd's configuration.")
                }
            }
        }
        .serviceSettingsFormStyle()
        .paneAwareNavigationTitle(server.title, subtitle: "SABnzbd", whenPane: server.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            #endif
        }
    }

    private var headerBadges: [ArrDetailBadge] {
        [
            ArrDetailBadge(
                icon: server.enabled ? "checkmark.circle.fill" : "pause.circle.fill",
                label: server.enabled ? "Enabled" : "Disabled",
                color: server.enabled ? .green : .secondary
            )
        ]
    }

    private func detailRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
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
