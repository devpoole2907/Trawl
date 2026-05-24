import SwiftUI

struct SeerrLinkedApplicationsView: View {
    let apiClient: SeerrAPIClient

    @State private var viewModel: SeerrLinkedApplicationsViewModel?
    @State private var editorContext: SeerrLinkedAppEditorContext?
    @State private var pendingDelete: SeerrLinkedAppEntry?

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Linked Apps")
        .navigationSubtitle("Seerr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if viewModel == nil {
                viewModel = SeerrLinkedApplicationsViewModel(apiClient: apiClient)
            }
            await viewModel?.loadIfNeeded()
        }
        .sheet(item: $editorContext) { context in
            SeerrLinkedApplicationEditorSheet(
                apiClient: apiClient,
                context: context,
                onSaved: { _ in
                    Task { await viewModel?.loadAll() }
                }
            )
        }
        .alert(
            "Remove Linked App?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let pendingDelete else { return }
                let target = pendingDelete
                self.pendingDelete = nil
                Task { await viewModel?.delete(target) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This unlinks the application from Seerr.")
        }
    }

    @ViewBuilder
    private func content(viewModel: SeerrLinkedApplicationsViewModel) -> some View {
        List {
            if viewModel.isLoading && viewModel.entries.isEmpty {
                Section {
                    ProgressView("Loading linked applications…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "Could Not Load Apps",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .listRowBackground(Color.clear)
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "No Linked Apps",
                    systemImage: "app.connected.to.app.below.fill",
                    description: Text("Link Sonarr or Radarr so Seerr can route requests to them.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.entries) { entry in
                        Button {
                            editorContext = .edit(entry)
                        } label: {
                            SeerrLinkedAppRow(entry: entry)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = entry
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }

                            Button {
                                editorContext = .edit(entry)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(ServiceIdentity.seerr.brandColor)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                editorContext = .edit(entry)
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                pendingDelete = entry
                            }
                        }
                    }
                } footer: {
                    Text("Seerr forwards approved requests to these applications.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .refreshable { await viewModel.loadAll() }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Menu {
                    Button {
                        editorContext = .create(.sonarr)
                    } label: {
                        Label("Link Sonarr", systemImage: SeerrDVRKind.sonarr.serviceIdentity.systemImage)
                    }
                    Button {
                        editorContext = .create(.radarr)
                    } label: {
                        Label("Link Radarr", systemImage: SeerrDVRKind.radarr.serviceIdentity.systemImage)
                    }
                } label: {
                    Label("Add Linked App", systemImage: "plus")
                }
            }
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class SeerrLinkedApplicationsViewModel {
    private(set) var entries: [SeerrLinkedAppEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let apiClient: SeerrAPIClient
    private var hasLoaded = false

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadAll()
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil

        do {
            async let sonarrLoad = apiClient.getDVRSettings(.sonarr)
            async let radarrLoad = apiClient.getDVRSettings(.radarr)
            let sonarrItems = try await sonarrLoad
            let radarrItems = try await radarrLoad

            let combined = sonarrItems.map { SeerrLinkedAppEntry(kind: .sonarr, settings: $0) }
                + radarrItems.map { SeerrLinkedAppEntry(kind: .radarr, settings: $0) }
            withAnimation(.default) {
                entries = combined.sorted {
                    if $0.kind != $1.kind { return $0.kind.displayName < $1.kind.displayName }
                    return $0.settings.name.localizedCaseInsensitiveCompare($1.settings.name) == .orderedAscending
                }
            }
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func delete(_ entry: SeerrLinkedAppEntry) async {
        do {
            try await apiClient.deleteDVRSettings(entry.kind, id: entry.settings.id)
            withAnimation(.default) {
                entries.removeAll { $0.id == entry.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }
}

struct SeerrLinkedAppEntry: Identifiable {
    let kind: SeerrDVRKind
    let settings: SeerrDVRSettings

    var id: String { "\(kind.rawValue)-\(settings.id)" }
}

enum SeerrLinkedAppEditorContext: Identifiable {
    case create(SeerrDVRKind)
    case edit(SeerrLinkedAppEntry)

    var id: String {
        switch self {
        case .create(let kind): "create-\(kind.rawValue)"
        case .edit(let entry): "edit-\(entry.id)"
        }
    }

    var kind: SeerrDVRKind {
        switch self {
        case .create(let kind): kind
        case .edit(let entry): entry.kind
        }
    }
}

// MARK: - Row

private struct SeerrLinkedAppRow: View {
    let entry: SeerrLinkedAppEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.serviceIdentity.systemImage)
                .foregroundStyle(entry.kind.serviceIdentity.brandColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.settings.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if entry.settings.isDefault == true {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    if entry.settings.is4k == true {
                        Text("4K")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ServiceIdentity.seerr.brandColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(ServiceIdentity.seerr.brandColor)
                    }
                }

                Text(entry.settings.displayURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let profile = entry.settings.activeProfileName {
                    Text(profile)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
extension SeerrLinkedApplicationsView {
    init(
        apiClient: SeerrAPIClient = .preview(),
        previewViewModel: SeerrLinkedApplicationsViewModel
    ) {
        self.apiClient = apiClient
        self._viewModel = State(initialValue: previewViewModel)
    }
}

extension SeerrLinkedApplicationsViewModel {
    convenience init(
        previewEntries: [SeerrLinkedAppEntry],
        isLoading: Bool = false,
        errorMessage: String? = nil,
        apiClient: SeerrAPIClient = .preview()
    ) {
        self.init(apiClient: apiClient)
        self.entries = previewEntries
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.hasLoaded = true
    }
}

extension SeerrLinkedAppEntry {
    static let previewSonarr = SeerrLinkedAppEntry(
        kind: .sonarr,
        settings: .preview(id: 1, name: "Main Sonarr", port: 8989, activeProfileName: "HD-1080p")
    )
    static let previewRadarr = SeerrLinkedAppEntry(
        kind: .radarr,
        settings: .preview(id: 2, name: "Main Radarr", port: 7878, activeProfileName: "HD-1080p", isDefault: true)
    )
    static let preview4K = SeerrLinkedAppEntry(
        kind: .radarr,
        settings: .preview(id: 3, name: "Radarr 4K", port: 7879, activeProfileName: "Ultra-HD", is4k: true)
    )
    static let previewList: [SeerrLinkedAppEntry] = [previewSonarr, previewRadarr, preview4K]
}

extension SeerrDVRSettings {
    static func preview(
        id: Int,
        name: String,
        hostname: String = "192.168.1.50",
        port: Int,
        activeProfileName: String? = nil,
        is4k: Bool = false,
        isDefault: Bool = false
    ) -> SeerrDVRSettings {
        SeerrDVRSettings(
            id: id,
            name: name,
            hostname: hostname,
            port: port,
            apiKey: "preview-key",
            useSsl: false,
            baseUrl: nil,
            activeProfileId: 1,
            activeProfileName: activeProfileName,
            activeDirectory: "/media",
            is4k: is4k,
            isDefault: isDefault,
            externalUrl: nil,
            syncEnabled: true,
            preventSearch: false,
            tagRequests: true,
            tags: [1, 2],
            minimumAvailability: "released",
            activeAnimeProfileId: nil,
            activeAnimeDirectory: nil,
            activeLanguageProfileId: nil,
            activeAnimeLanguageProfileId: nil,
            enableSeasonFolders: true
        )
    }
}

#Preview("Seerr Linked Apps - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrLinkedApplicationsView(
                previewViewModel: SeerrLinkedApplicationsViewModel(
                    previewEntries: SeerrLinkedAppEntry.previewList
                )
            )
        }
    }
}

#Preview("Seerr Linked Apps - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrLinkedApplicationsView(
                previewViewModel: SeerrLinkedApplicationsViewModel(previewEntries: [])
            )
        }
    }
}

#Preview("Seerr Linked Apps - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        NavigationStack {
            SeerrLinkedApplicationsView(
                previewViewModel: SeerrLinkedApplicationsViewModel(
                    previewEntries: [],
                    isLoading: true
                )
            )
        }
    }
}

#Preview("Seerr Linked Apps - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to load linked apps."))) {
        NavigationStack {
            SeerrLinkedApplicationsView(
                previewViewModel: SeerrLinkedApplicationsViewModel(
                    previewEntries: [],
                    errorMessage: "The Seerr settings endpoint returned 401."
                )
            )
        }
    }
}
#endif
