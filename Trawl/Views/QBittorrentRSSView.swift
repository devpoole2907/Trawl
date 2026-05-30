import SwiftUI

struct QBittorrentRSSView: View {
    @Environment(TorrentService.self) private var torrentService
    @Environment(AppServices.self) private var appServices

    @State private var rssItems: [String: JSONValue] = [:]
    @State private var isLoading = false
    @State private var actionErrorAlert: ErrorAlertItem?
    
    @State private var showCreateFeedAlert = false
    @State private var newFeedURL = ""
    @State private var itemPendingDeletion: String?
    @State private var showingRulesSheet = false
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init() {}

    var body: some View {
        List {
            if isLoading && rssItems.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if rssItems.isEmpty {
                ContentUnavailableView(
                    "No RSS Feeds",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Add RSS feed URLs to automatically monitor trackers.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Feeds & Folders") {
                    ForEach(rssItemKeys, id: \.self) { key in
                        rssItemRow(name: key, path: key, value: rssItems[key])
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .navigationTitle("RSS Feeds")
        .navigationSubtitle("qBittorrent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRulesSheet = true
                } label: {
                    Label("Auto-Download Rules", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateFeedAlert = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingRulesSheet) {
            QBittorrentRSSRulesSheet(feedOptions: feedOptions)
        }
        .alert("Add RSS Feed", isPresented: $showCreateFeedAlert) {
            TextField("Feed URL", text: $newFeedURL)
                #if os(iOS)
                .keyboardType(.URL)
                .autocapitalization(.none)
                #endif
            Button("Add") {
                Task { await addFeed() }
            }
            .disabled(newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                newFeedURL = ""
            }
        } message: {
            Text("Enter the direct URL to the RSS feed.")
        }
        .alert("Delete Item?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                guard let itemPendingDeletion else { return }
                Task { await deleteItem(itemPendingDeletion) }
            }
            Button("Cancel", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            Text("This will remove the RSS feed/folder from qBittorrent.")
        }
        .errorAlert(item: $actionErrorAlert)
        .task {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            await loadRSSItems()
        }
        .refreshable {
            await loadRSSItems()
        }
    }

    private var rssItemKeys: [String] {
        rssItems.keys.sorted()
    }

    private var feedOptions: [QBittorrentRSSFeedOption] {
        var options: [QBittorrentRSSFeedOption] = []
        collectFeedOptions(in: rssItems, parentPath: "", into: &options)
        return options.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func collectFeedOptions(
        in dictionary: [String: JSONValue],
        parentPath: String,
        into options: inout [QBittorrentRSSFeedOption]
    ) {
        for key in sortedKeys(in: dictionary) {
            let path = rssItemPath(parentPath: parentPath, name: key)
            switch dictionary[key] {
            case .string(let url):
                options.append(QBittorrentRSSFeedOption(path: path, url: url))
            case .object(let child):
                if case let .string(url) = child["url"] {
                    options.append(QBittorrentRSSFeedOption(path: path, url: url))
                } else {
                    collectFeedOptions(in: child, parentPath: path, into: &options)
                }
            default:
                continue
            }
        }
    }

    private func rssItemPath(parentPath: String, name: String) -> String {
        guard !parentPath.isEmpty else { return name }
        guard !name.isEmpty else { return parentPath }
        return "\(parentPath)/\(name)"
    }

    private func sortedKeys(in dictionary: [String: JSONValue]) -> [String] {
        dictionary.keys.sorted()
    }
    
    private func rssItemRow(name: String, path: String, value: JSONValue?) -> AnyView {
        if case let .object(dict) = value {
            if case let .string(url) = dict["url"] {
                return AnyView(
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.cyan)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(name)
                                .font(.body.weight(.medium))
                            Text(url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            itemPendingDeletion = path
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                )
            }

            return AnyView(
                DisclosureGroup {
                    ForEach(sortedKeys(in: dict), id: \.self) { subKey in
                        rssItemRow(
                            name: subKey,
                            path: rssItemPath(parentPath: path, name: subKey),
                            value: dict[subKey]
                        )
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.cyan)
                            .frame(width: 20)
                        Text(name)
                            .font(.body.weight(.medium))
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        itemPendingDeletion = path
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            )
        }

        return AnyView(
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.cyan)
                    .frame(width: 20)
                Text(name)
                    .font(.body.weight(.medium))
            }
            .padding(.vertical, 2)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    itemPendingDeletion = path
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { itemPendingDeletion != nil },
            set: { if !$0 { itemPendingDeletion = nil } }
        )
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [Color.cyan.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.cyan.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }
    
    private func loadRSSItems() async {
        isLoading = true
        do {
            rssItems = try await appServices.apiClient.getRSSItems(withData: false)
        } catch {
            actionErrorAlert = ErrorAlertItem(title: "Failed to Load RSS", message: error.localizedDescription)
        }
        isLoading = false
    }
    
    private func addFeed() async {
        let url = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        
        do {
            try await appServices.apiClient.addRSSFeed(url: url)
            newFeedURL = ""
            await loadRSSItems()
        } catch {
            actionErrorAlert = ErrorAlertItem(title: "Failed to Add Feed", message: error.localizedDescription)
        }
    }
    
    private func deleteItem(_ path: String) async {
        do {
            try await appServices.apiClient.removeRSSItem(path: path)
            await loadRSSItems()
        } catch {
            actionErrorAlert = ErrorAlertItem(title: "Failed to Delete", message: error.localizedDescription)
        }
    }
}

#if DEBUG
extension QBittorrentRSSView {
    init(
        previewRSSItems rssItems: [String: JSONValue],
        isLoading: Bool = false,
        actionErrorAlert: ErrorAlertItem? = nil
    ) {
        self.init()
        self._rssItems = State(initialValue: rssItems)
        self._isLoading = State(initialValue: isLoading)
        self._actionErrorAlert = State(initialValue: actionErrorAlert)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Loaded") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentRSSView(previewRSSItems: [
                "linux": .object([
                    "Ubuntu Releases": .object(["url": .string("https://releases.ubuntu.com/rss.xml")]),
                    "Fedora": .object(["url": .string("https://fedoraproject.org/rss.xml")])
                ]),
                "Movies Feed": .object(["url": .string("https://tracker.example.org/movies/rss")])
            ])
        }
    }
}

#Preview("Empty") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentRSSView(previewRSSItems: [:])
        }
    }
}

#Preview("Loading") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentRSSView(previewRSSItems: [:], isLoading: true)
        }
    }
}

#Preview("Error") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentRSSView(
                previewRSSItems: [:],
                actionErrorAlert: ErrorAlertItem(
                    title: "Failed to Load RSS",
                    message: "qBittorrent returned 403 Forbidden."
                )
            )
        }
    }
}
#endif
