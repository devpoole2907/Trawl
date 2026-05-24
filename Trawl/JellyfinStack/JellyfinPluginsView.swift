import SwiftUI

struct JellyfinPluginsView: View {
    let apiClient: JellyfinAPIClient

    @State private var plugins: [JellyfinPlugin] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pluginToDelete: JellyfinPlugin?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && plugins.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if plugins.isEmpty {
                ContentUnavailableView(
                    "No Plugins",
                    systemImage: "puzzlepiece.extension",
                    description: Text("No plugins were returned by Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(plugins) { plugin in
                        pluginRow(plugin)
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
        .navigationTitle("Plugins")
        .navigationSubtitle("Jellyfin")
        .refreshable { await loadPlugins() }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            await loadPlugins()
        }
        .alert("Uninstall Plugin", isPresented: Binding(
            get: { pluginToDelete != nil },
            set: { if !$0 { pluginToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pluginToDelete = nil }
            Button("Uninstall", role: .destructive) {
                if let plugin = pluginToDelete {
                    Task { await deletePlugin(plugin) }
                }
                pluginToDelete = nil
            }
        } message: {
            if let plugin = pluginToDelete {
                Text("Are you sure you want to uninstall \(plugin.name)? This cannot be undone.")
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
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pluginStatusColor(status).opacity(0.16), in: Capsule())
                        .foregroundStyle(pluginStatusColor(status))
                }
            }

            if let version = plugin.version, !version.isEmpty {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let description = plugin.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func pluginStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "active", "restart": .green
        case "disabled", "superceded": .secondary
        case "malfunctioned": .red
        case "notsupported": .orange
        default: .secondary
        }
    }

    private func loadPlugins() async {
        isLoading = true
        errorMessage = nil
        do {
            plugins = try await apiClient.getPlugins()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deletePlugin(_ plugin: JellyfinPlugin) async {
        do {
            try await apiClient.deletePlugin(id: plugin.id, version: plugin.version)
            plugins.removeAll { $0.id == plugin.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
extension JellyfinPluginsView {
    init(
        apiClient: JellyfinAPIClient = .preview(),
        previewPlugins: [JellyfinPlugin],
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.apiClient = apiClient
        self._plugins = State(initialValue: previewPlugins)
        self._isLoading = State(initialValue: isLoading)
        self._errorMessage = State(initialValue: errorMessage)
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
