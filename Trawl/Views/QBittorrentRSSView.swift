import SwiftUI

struct QBittorrentRSSView: View {
    @Environment(TorrentService.self) private var torrentService
    @Environment(AppServices.self) private var appServices

    @State private var rssItems: [String: Any] = [:]
    @State private var isLoading = false
    @State private var actionErrorAlert: ErrorAlertItem?
    
    @State private var showCreateFeedAlert = false
    @State private var newFeedURL = ""
    @State private var itemPendingDeletion: String?

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
                        rssItemRow(name: key, value: rssItems[key])
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateFeedAlert = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
            }
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
            await loadRSSItems()
        }
    }

    private var rssItemKeys: [String] {
        rssItems.keys.sorted()
    }

    private func sortedKeys(in dictionary: [String: Any]) -> [String] {
        dictionary.keys.sorted()
    }
    
    private func rssItemRow(name: String, value: Any?) -> AnyView {
        if let dict = value as? [String: Any] {
            if let url = dict["url"] as? String {
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
                            itemPendingDeletion = name
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                )
            }

            return AnyView(
                DisclosureGroup {
                    ForEach(sortedKeys(in: dict), id: \.self) { subKey in
                        rssItemRow(name: subKey, value: dict[subKey])
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
                        itemPendingDeletion = name
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
                    itemPendingDeletion = name
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
