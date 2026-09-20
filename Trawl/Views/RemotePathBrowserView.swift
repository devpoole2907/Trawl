import SwiftUI

nonisolated struct RemotePathBrowserSource: Sendable {
    let serviceName: String
    let loadRoots: @Sendable () async throws -> [RemotePathEntry]
    let loadChildren: @Sendable (_ path: String) async throws -> [RemotePathEntry]
}

struct RemotePathBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let source: RemotePathBrowserSource
    let initialPath: String
    let onClose: (() -> Void)?
    let onSelect: (String) -> Void

    @State private var entries: [RemotePathEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var manualPath: String
    #if os(macOS)
    @State private var macPathHistory: [String] = []
    #endif

    init(
        title: String = "Browse Folder",
        source: RemotePathBrowserSource,
        initialPath: String = "",
        onClose: (() -> Void)? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.title = title
        self.source = source
        self.initialPath = initialPath
        self.onClose = onClose
        self.onSelect = onSelect
        _manualPath = State(initialValue: initialPath)
    }

    private var currentPath: String {
        #if os(macOS)
        macPathHistory.last ?? initialPath
        #else
        initialPath
        #endif
    }

    var body: some View {
        #if os(macOS)
        macBrowser
        #else
        List {
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage {
                    ServiceErrorView(
                        title: "Cannot Browse Folder",
                        message: errorMessage,
                        systemImage: "folder",
                        onRetry: { await loadEntries() }
                    )
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "No Folders",
                        systemImage: "folder",
                        description: Text("No folders were returned for this path.")
                    )
                } else {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.path) {
                            HStack(spacing: 12) {
                                Image(systemName: iconName(for: entry))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name.isEmpty ? entry.path : entry.name)
                                        .foregroundStyle(.primary)
                                    if entry.path != entry.name {
                                        Text(entry.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .disabled(!entry.isDirectory)
                    }
                }
            } header: {
                Text(currentPath.isEmpty ? "Roots" : currentPath)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .safeAreaInset(edge: .top) {
            HStack(spacing: 0) {
                Image(systemName: "folder")
                    .font(.title3)
                    .frame(width: 45)

                // An example value, not a label: macOS draws a field's title beside it, where this
                // reads as another entry that has already been added.
                TextField("", text: $manualPath, prompt: Text("/media"))
                    .labelsHidden()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                Button {
                    useFolder(manualPath)
                } label: {
                    Image(systemName: "arrow.turn.down.left")
                        .frame(width: 45, height: 45)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to path")
                .disabled(trimmedManualPath.isEmpty)
            }
            .frame(height: 45)
            .padding(.horizontal, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, 15)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: platformCancellationPlacement) {
                Button("Cancel") { closeBrowser() }
            }
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button("Use This Folder") {
                    useFolder(currentPath)
                }
                .disabled(currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationDestination(for: String.self) { path in
            RemotePathBrowserView(
                title: title,
                source: source,
                initialPath: path,
                onClose: onClose,
                onSelect: onSelect
            )
        }
        .task {
            await loadEntries()
        }
        .refreshable {
            await loadEntries()
        }
        #endif
    }

    #if os(macOS)
    private var macBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back", systemImage: "chevron.left") {
                    if !macPathHistory.isEmpty {
                        macPathHistory.removeLast()
                        manualPath = currentPath
                    } else {
                        macPathHistory = [""]
                        manualPath = ""
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(currentPath.isEmpty)

                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                TextField("Server path", text: $manualPath, prompt: Text("/media"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .onSubmit { browseManualPath() }
                Button("Go", systemImage: "arrow.right") { browseManualPath() }
                    .labelStyle(.iconOnly)
                    .disabled(trimmedManualPath.isEmpty || trimmedManualPath == currentPath)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()

            Group {
                if isLoading {
                    TrawlInitialLoadingView(label: "Loading folders")
                } else if let errorMessage {
                    ServiceErrorView(
                        title: "Cannot Browse Folder",
                        message: errorMessage,
                        systemImage: "folder",
                        onRetry: { await loadEntries() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "No Folders",
                        systemImage: "folder",
                        description: Text("No folders were returned for this path.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button {
                                    macPathHistory.append(entry.path)
                                    manualPath = entry.path
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: iconName(for: entry))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                        Text(entry.name.isEmpty ? entry.path : entry.name)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 9)
                                }
                                .buttonStyle(.plain)
                                .disabled(!entry.isDirectory)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Text(currentPath.isEmpty ? "Choose a folder" : currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Cancel") { closeBrowser() }
                Button("Use This Folder") { useFolder(currentPath) }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .task(id: currentPath) { await loadEntries() }
    }

    private func browseManualPath() {
        guard !trimmedManualPath.isEmpty, trimmedManualPath != currentPath else { return }
        macPathHistory.append(trimmedManualPath)
        manualPath = trimmedManualPath
    }
    #endif

    private var trimmedManualPath: String {
        manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadEntries() async {
        let requestedPath = currentPath
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await (requestedPath.isEmpty ? source.loadRoots() : source.loadChildren(requestedPath))
            guard currentPath == requestedPath else { return }
            entries = loaded
                .filter(\.isDirectory)
                .sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        } catch {
            guard currentPath == requestedPath else { return }
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func useFolder(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSelect(trimmed)
        closeBrowser()
    }

    private func closeBrowser() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func iconName(for entry: RemotePathEntry) -> String {
        switch entry.kind {
        case .drive:
            "externaldrive"
        case .networkShare:
            "network"
        case .parent:
            "arrowshape.turn.up.left"
        case .directory:
            "folder"
        case .file:
            "doc"
        case .unknown:
            entry.isDirectory ? "folder" : "questionmark.square"
        }
    }
}

#if DEBUG
#Preview("Remote Path Browser") {
    NavigationStack {
        RemotePathBrowserView(
            title: "Sonarr Folders",
            source: RemotePathBrowserSource(
                serviceName: "Sonarr",
                loadRoots: {
                    [
                        RemotePathEntry(name: "app", path: "/app", kind: .directory, isDirectory: true),
                        RemotePathEntry(name: "media", path: "/media", kind: .directory, isDirectory: true),
                        RemotePathEntry(name: "config", path: "/config", kind: .directory, isDirectory: true)
                    ]
                },
                loadChildren: { _ in [] }
            ),
            initialPath: "",
            onClose: {},
            onSelect: { _ in }
        )
    }
}
#endif
