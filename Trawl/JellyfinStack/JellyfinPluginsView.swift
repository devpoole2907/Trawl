import SwiftUI

struct JellyfinPluginsView: View {
    let apiClient: JellyfinAPIClient

    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(JellyfinPluginBrowserState.self) private var sharedBrowser: JellyfinPluginBrowserState?
    @State private var localBrowser = JellyfinPluginBrowserState()
    private var browser: JellyfinPluginBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var showsDetailPane: Bool { sidebarColumn != nil }

    @State private var pluginToDelete: JellyfinPlugin?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        TrawlListDetailPanes(title: "Plugins", subtitle: "Jellyfin") {
            pluginsList
        } detail: {
            selectedPluginDetail
        }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            guard sidebarColumn != .detail else { return }
            await browser.loadPlugins(apiClient: apiClient)
        }
    }

    @ViewBuilder
    private var selectedPluginDetail: some View {
        if let id = browser.selectedPluginID,
           let plugin = currentPlugin(for: id) {
            JellyfinPluginDetailView(
                plugin: plugin,
                apiClient: apiClient
            )
            .id(plugin.id)
        } else {
            listDetailPlaceholder("Select a Plugin", systemImage: "puzzlepiece.extension")
        }
    }

    private func currentPlugin(for id: String) -> JellyfinPlugin? {
        browser.plugins.first(where: { $0.id == id })
    }

    @ViewBuilder
    private var pluginsList: some View {
        @Bindable var browser = self.browser
        List(selection: $browser.selectedPluginID) {
            if let error = browser.errorMessage {
                ServiceErrorView(
                    title: "Plugins Unavailable",
                    message: error,
                    identity: .jellyfin,
                    hasContent: !browser.plugins.isEmpty,
                    onRetry: { await browser.refresh(apiClient: apiClient) }
                )
            }

            if browser.isLoading && browser.plugins.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if browser.plugins.isEmpty {
                if browser.errorMessage == nil {
                    ContentUnavailableView(
                        "No Plugins",
                        systemImage: "puzzlepiece.extension",
                        description: Text("No plugins were returned by Jellyfin.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(browser.plugins) { plugin in
                        pluginLink(plugin)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pluginToDelete = plugin
                                } label: {
                                    Label("Uninstall", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .refreshable { await browser.refresh(apiClient: apiClient) }
        .alert("Uninstall Plugin", isPresented: Binding(
            get: { pluginToDelete != nil },
            set: { if !$0 { pluginToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pluginToDelete = nil }
            Button("Uninstall", role: .destructive) {
                if let plugin = pluginToDelete {
                    Task { await browser.deletePlugin(plugin, apiClient: apiClient) }
                }
                pluginToDelete = nil
            }
        } message: {
            if let plugin = pluginToDelete {
                Text("Are you sure you want to uninstall \(plugin.name)? This cannot be undone.")
            }
        }
        .onChange(of: browser.plugins.map(\.id)) { _, ids in
            if let id = browser.selectedPluginID, !ids.contains(id) {
                browser.selectedPluginID = nil
            }
        }
    }

    @ViewBuilder
    private func pluginLink(_ plugin: JellyfinPlugin) -> some View {
        if showsDetailPane {
            pluginRow(plugin)
                .tag(plugin.id)
        } else {
            NavigationLink {
                JellyfinPluginDetailView(
                    plugin: currentPlugin(for: plugin.id) ?? plugin,
                    apiClient: apiClient
                )
            } label: {
                pluginRow(plugin)
            }
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: JellyfinPlugin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(plugin.name)
                    .font(.body)
                    .fontWeight(.medium)

                Spacer(minLength: 8)

                if let status = plugin.status, !status.isEmpty {
                    Text(plugin.statusLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(plugin.statusColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(plugin.statusColor)
                }
            }

            if let version = plugin.version, !version.isEmpty {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let description = plugin.overview ?? plugin.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .macListRowStableHeight()
    }
}

// MARK: - Detail View

struct JellyfinPluginDetailView: View {
    let plugin: JellyfinPlugin
    let apiClient: JellyfinAPIClient

    @Environment(\.dismiss) private var dismiss
    @Environment(JellyfinPluginBrowserState.self) private var sharedBrowser: JellyfinPluginBrowserState?
    @State private var showingUninstallAlert = false
    @State private var isUninstalling = false

    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: plugin.name,
                    subtitle: plugin.version.map { "Version \($0)" },
                    systemImage: "puzzlepiece.extension.fill",
                    tint: ServiceIdentity.jellyfin.brandColor,
                    shape: .rounded,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            if let overview = plugin.overview, !overview.isEmpty {
                Section("Overview") {
                    Text(overview)
                        .font(.body)
                }
            }

            if let description = plugin.description, !description.isEmpty, description != plugin.overview {
                Section("Description") {
                    Text(description)
                        .font(.body)
                }
            }

            Section("Configuration") {
                LabeledContent("Status") {
                    HStack(spacing: 4) {
                        Image(systemName: plugin.statusIcon)
                            .foregroundStyle(plugin.statusColor)
                        Text(plugin.statusLabel)
                            .foregroundStyle(plugin.statusColor)
                    }
                }

                if let version = plugin.version, !version.isEmpty {
                    LabeledContent("Version", value: version)
                }

                if let configFile = plugin.configurationFileName, !configFile.isEmpty {
                    LabeledContent("Config File", value: configFile)
                }

                if let canUninstall = plugin.canUninstall {
                    LabeledContent("Removable", value: canUninstall ? "Yes" : "No (Built-in)")
                }

                LabeledContent("Identifier") {
                    Text(plugin.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    showingUninstallAlert = true
                } label: {
                    if isUninstalling {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Label("Uninstall Plugin", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(plugin.canUninstall == false || isUninstalling)
            } footer: {
                if plugin.canUninstall == false {
                    Text("This plugin is built-in or required by Jellyfin and cannot be uninstalled.")
                } else {
                    Text("Uninstalling removes the plugin assembly and configuration. A server restart may be required.")
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .paneAwareNavigationTitle(
            plugin.name,
            subtitle: "Jellyfin Plugin",
            whenPane: plugin.name
        )
        .alert("Uninstall Plugin?", isPresented: $showingUninstallAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                Task { await uninstallPlugin() }
            }
        } message: {
            Text("Are you sure you want to uninstall \(plugin.name)? This cannot be undone.")
        }
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        badges.append(ArrDetailBadge(
            icon: plugin.statusIcon,
            label: plugin.statusLabel,
            color: plugin.statusColor
        ))
        if let version = plugin.version, !version.isEmpty {
            badges.append(ArrDetailBadge(
                icon: "tag",
                label: "v\(version)",
                color: .secondary
            ))
        }
        if plugin.canUninstall == false {
            badges.append(ArrDetailBadge(
                icon: "lock.fill",
                label: "Built-in",
                color: .secondary
            ))
        } else if plugin.canUninstall == true {
            badges.append(ArrDetailBadge(
                icon: "trash",
                label: "Removable",
                color: .secondary
            ))
        }
        return badges
    }

    private func uninstallPlugin() async {
        isUninstalling = true
        if let browser = sharedBrowser {
            await browser.deletePlugin(plugin, apiClient: apiClient)
        } else {
            do {
                try await apiClient.deletePlugin(id: plugin.id, version: plugin.version)
            } catch {
                InAppNotificationCenter.shared.showError(
                    title: "Couldn't Uninstall Plugin",
                    message: error.localizedDescription
                )
            }
        }
        isUninstalling = false
        #if os(iOS)
        dismiss()
        #endif
    }
}

// MARK: - Presentation Helpers

extension JellyfinPlugin {
    /// Jellyfin reports a plugin's status as a bare enum name - `NotSupported`,
    /// `Superceded` (its spelling, not ours). Those went straight into the badge, so the
    /// screen read like a stack trace. Anything unrecognised still shows verbatim rather
    /// than being hidden: an unknown status is worth seeing.
    var statusLabel: String {
        switch (status ?? "").lowercased() {
        case "active": "Active"
        case "restart": "Restart Required"
        case "disabled": "Disabled"
        case "superceded": "Superseded"
        case "malfunctioned": "Malfunctioned"
        case "notsupported": "Not Supported"
        default: status ?? "Unknown"
        }
    }

    var statusColor: Color {
        switch (status ?? "").lowercased() {
        case "active": .green
        case "restart": .blue
        case "disabled", "superceded": .secondary
        case "malfunctioned": .red
        case "notsupported": .orange
        default: .secondary
        }
    }

    var statusIcon: String {
        switch (status ?? "").lowercased() {
        case "active": "checkmark.circle.fill"
        case "restart": "arrow.clockwise.circle.fill"
        case "disabled": "pause.circle.fill"
        case "superceded": "arrow.up.right.circle.fill"
        case "malfunctioned": "exclamationmark.octagon.fill"
        case "notsupported": "slash.circle.fill"
        default: "questionmark.circle.fill"
        }
    }
}

// MARK: - Previews

#if DEBUG
extension JellyfinPluginsView {
    init(
        apiClient: JellyfinAPIClient = .preview(),
        previewPlugins: [JellyfinPlugin],
        selectedPluginID: String? = nil,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.apiClient = apiClient
        let browser = JellyfinPluginBrowserState()
        browser.plugins = previewPlugins
        browser.selectedPluginID = selectedPluginID
        browser.isLoading = isLoading
        browser.errorMessage = errorMessage
        self._localBrowser = State(initialValue: browser)
        self.isPreview = true
    }
}

#Preview("Jellyfin Plugins - Loaded") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinPluginsView(previewPlugins: JellyfinPlugin.previewList)
        }
    }
}

#Preview("Jellyfin Plugins - Selected Detail") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinPluginDetailView(
                plugin: JellyfinPlugin.preview,
                apiClient: .preview()
            )
        }
    }
}

#Preview("Jellyfin Plugins - Empty") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinPluginsView(previewPlugins: [])
        }
    }
}

#Preview("Jellyfin Plugins - Loading") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connecting)) {
        NavigationStack {
            JellyfinPluginsView(previewPlugins: [], isLoading: true)
        }
    }
}

#Preview("Jellyfin Plugins - Error") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.error("Unable to load plugins."))) {
        NavigationStack {
            JellyfinPluginsView(
                previewPlugins: [],
                errorMessage: "The plugin catalog could not be loaded."
            )
        }
    }
}
#endif
