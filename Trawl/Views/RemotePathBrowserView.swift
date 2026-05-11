import SwiftUI

nonisolated enum RemotePathEntryKind: String, Codable, Sendable {
    case directory
    case file
    case drive
    case networkShare
    case parent
    case unknown
}

nonisolated struct RemotePathEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let kind: RemotePathEntryKind
    let isDirectory: Bool

    var id: String { "\(kind.rawValue)|\(path)|\(name)" }
}

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
    let onSelect: (String) -> Void

    @State private var entries: [RemotePathEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var manualPath: String

    init(
        title: String = "Browse Folder",
        source: RemotePathBrowserSource,
        initialPath: String = "",
        onSelect: @escaping (String) -> Void
    ) {
        self.title = title
        self.source = source
        self.initialPath = initialPath
        self.onSelect = onSelect
        _manualPath = State(initialValue: initialPath)
    }

    private var currentPath: String {
        initialPath
    }

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Cannot Browse Folder",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
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

                TextField("/media", text: $manualPath)
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
                Button("Cancel") { dismiss() }
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
                onSelect: onSelect
            )
        }
        .task {
            await loadEntries()
        }
        .refreshable {
            await loadEntries()
        }
    }

    private var trimmedManualPath: String {
        manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadEntries() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await (currentPath.isEmpty ? source.loadRoots() : source.loadChildren(currentPath))
            entries = loaded
                .filter(\.isDirectory)
                .sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func useFolder(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSelect(trimmed)
        dismiss()
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
