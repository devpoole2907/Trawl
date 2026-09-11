import SwiftUI

/// The shared organization controls for qBittorrent and SABnzbd.
///
/// Categories belong together because both clients expose them, while tags and
/// scripts remain separate because each is owned by only one client. On a regular
/// width window this is the middle column of Trawl's root split view; compact
/// navigation pushes the same detail screens.
enum DownloadOrganizationDestination: Hashable {
    case categories
    case tags
    case scripts
}

struct DownloadOrganizationManagementView: View {
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(TrawlColumnSelection<DownloadOrganizationDestination>.self) private var sharedSelection: TrawlColumnSelection<DownloadOrganizationDestination>?
    @State private var localSelection = TrawlColumnSelection<DownloadOrganizationDestination>()

    private var selectionStore: TrawlColumnSelection<DownloadOrganizationDestination> {
        sidebarColumn == nil ? localSelection : (sharedSelection ?? localSelection)
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    @ViewBuilder
    var body: some View {
        if sidebarColumn == nil {
            panes
                .navigationDestination(for: DownloadOrganizationDestination.self) { destination in
                    detail(for: destination)
                }
        } else {
            panes
        }
    }

    private var panes: some View {
        TrawlListDetailPanes(title: "Categories, Tags & Scripts") {
            List(selection: showsDetailPane ? selectionStore.binding : nil) {
                Section {
                    organizationRow(.categories) {
                        NavigationMenuRow(
                            icon: "tag.fill",
                            color: MoreDestinationAccent.categoriesAndTags.color,
                            title: "Categories",
                            subtitle: "qBittorrent and SABnzbd download rules"
                        )
                    }

                    organizationRow(.tags) {
                        NavigationMenuRow(
                            icon: "number",
                            color: MoreDestinationAccent.categoriesAndTags.color,
                            title: "Tags",
                            subtitle: "qBittorrent torrent labels"
                        )
                    }

                    organizationRow(.scripts) {
                        NavigationMenuRow(
                            icon: "terminal",
                            color: ServiceIdentity.sabnzbd.brandColor,
                            title: "Scripts",
                            subtitle: "SABnzbd post-processing scripts"
                        )
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        } detail: {
            selectedDetail
        }
    }

    @ViewBuilder
    private func organizationRow<Label: View>(
        _ destination: DownloadOrganizationDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if showsDetailPane {
            label().tag(destination)
        } else {
            NavigationLink(value: destination, label: label)
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let selection = selectionStore.selection {
            detail(for: selection)
        } else {
            listDetailPlaceholder("Select a Setting", systemImage: "tag")
        }
    }

    @ViewBuilder
    private func detail(for destination: DownloadOrganizationDestination) -> some View {
        switch destination {
        case .categories:
            DownloadOrganizationCategoriesView()
        case .tags:
            QBittorrentCategoriesAndTagsView(section: .tags)
                .navigationTitle("Tags")
                .navigationSubtitle("qBittorrent")
        case .scripts:
            SABnzbdCategoriesView(section: .scripts)
                .navigationTitle("Scripts")
                .navigationSubtitle("SABnzbd")
        }
    }
}

private struct DownloadOrganizationCategoriesView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager

    @State private var selectedClient = ServiceIdentity.qbittorrent
    @State private var newQBittorrentCategoryName = ""
    @State private var newQBittorrentCategoryPath = ""
    @State private var showingNewQBittorrentCategory = false
    @State private var qBittorrentCategoryPendingDeletion: String?
    @State private var sabnzbdEditorTarget: SABnzbdCategoryEditorTarget?
    @State private var sabnzbdCategoryPendingDeletion: SABnzbdCategory?
    @State private var actionError: ErrorAlertItem?
    @State private var isSubmitting = false

    var body: some View {
        List {
            if selectedClient == .qbittorrent {
                qbittorrentCategories
            } else {
                sabnzbdCategories
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .moreDestinationBackground(.categoriesAndTags)
        .navigationTitle("Categories")
        .navigationSubtitle(selectedClient.displayName)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Client",
                selection: $selectedClient,
                items: [
                    TrawlSegmentBarItem("qBittorrent", value: .qbittorrent),
                    TrawlSegmentBarItem("SABnzbd", value: .sabnzbd)
                ],
                alignment: .center
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Category", systemImage: "plus", action: addCategory)
                    .disabled(isSubmitting)
            }
        }
        .task {
            await refreshCategories()
        }
        .onChange(of: selectedClient) { _, _ in
            Task { await refreshCategories() }
        }
        .refreshable {
            await refreshCategories()
        }
        .alert("Add Category", isPresented: $showingNewQBittorrentCategory) {
            TextField("Name", text: $newQBittorrentCategoryName)
            TextField("Save Path (Optional)", text: $newQBittorrentCategoryPath)
            Button("Add") { Task { await createQBittorrentCategory() } }
                .disabled(newQBittorrentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            Button("Cancel", role: .cancel, action: resetQBittorrentCategoryInputs)
        } message: {
            Text("Leave the save path empty to use qBittorrent's default behavior.")
        }
        .alert("Delete Category?", isPresented: qBittorrentDeletionPresented) {
            Button("Delete", role: .destructive) {
                guard let name = qBittorrentCategoryPendingDeletion else { return }
                Task { await deleteQBittorrentCategory(name) }
            }
            Button("Cancel", role: .cancel) { qBittorrentCategoryPendingDeletion = nil }
        } message: {
            Text("This removes the category from qBittorrent.")
        }
        .alert("Delete Category?", isPresented: sabnzbdDeletionPresented) {
            Button("Delete", role: .destructive) {
                guard let category = sabnzbdCategoryPendingDeletion else { return }
                Task { await deleteSABnzbdCategory(category) }
            }
            Button("Cancel", role: .cancel) { sabnzbdCategoryPendingDeletion = nil }
        } message: {
            Text("This removes the category from SABnzbd. Existing downloads keep their folders.")
        }
        .sheet(item: $sabnzbdEditorTarget) { target in
            SABnzbdCategoryEditorSheet(existingCategory: target.category) {
                sabnzbdEditorTarget = nil
            }
            .environment(sabnzbdServiceManager)
        }
        .errorAlert(item: $actionError)
    }

    @ViewBuilder private var qbittorrentCategories: some View {
        if syncService.sortedCategoryNames.isEmpty {
            ContentUnavailableView("No Categories", systemImage: "tag", description: Text("Create categories here, then assign them from torrent detail views."))
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(syncService.sortedCategoryNames, id: \.self) { name in
                    categoryRow(name, path: qBittorrentSavePath(for: name))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { qBittorrentCategoryPendingDeletion = name }
                        }
                }
            }
        }
    }

    @ViewBuilder private var sabnzbdCategories: some View {
        let categories = sabnzbdServiceManager.categoryConfigs.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if categories.isEmpty {
            ContentUnavailableView("No Categories", systemImage: "tag", description: Text("SABnzbd has no categories configured."))
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(categories) { category in
                    Button { sabnzbdEditorTarget = .init(category: category) } label: {
                        categoryRow(category.displayName, path: category.directory?.isEmpty == false ? category.directory! : "Uses default save path")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !category.isDefault {
                            Button("Delete", systemImage: "trash", role: .destructive) { sabnzbdCategoryPendingDeletion = category }
                        }
                    }
                }
            } footer: {
                Text("Select a category to edit its folder, script, and priority.")
            }
        }
    }

    private func categoryRow(_ name: String, path: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill").foregroundStyle(MoreDestinationAccent.categoriesAndTags.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.medium))
                Text(path)
                    .font(.footnote)
                    .foregroundStyle(path == "Uses default save path" ? .tertiary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func qBittorrentSavePath(for name: String) -> String {
        guard let path = syncService.categories[name]?.savePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return "Uses default save path"
        }
        return path
    }

    private func addCategory() {
        if selectedClient == .qbittorrent { showingNewQBittorrentCategory = true }
        else { sabnzbdEditorTarget = .init(category: nil) }
    }

    private func refreshCategories() async {
        if selectedClient == .qbittorrent { await syncService.refreshNow() }
        else { await sabnzbdServiceManager.refreshCategoryConfigs() }
    }

    private func createQBittorrentCategory() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let name = newQBittorrentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = newQBittorrentCategoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await torrentService.createCategory(name: name, savePath: path.isEmpty ? nil : path)
            syncService.addCategoryLocally(name: name, savePath: path.isEmpty ? nil : path)
            await syncService.refreshNow()
            resetQBittorrentCategoryInputs()
        } catch { actionError = ErrorAlertItem(title: "Couldn't Create Category", message: error.localizedDescription) }
    }

    private func deleteQBittorrentCategory(_ name: String) async {
        do {
            try await torrentService.removeCategories(names: [name])
            syncService.removeCategoriesLocally(names: [name])
            await syncService.refreshNow()
        } catch { actionError = ErrorAlertItem(title: "Couldn't Delete Category", message: error.localizedDescription) }
        qBittorrentCategoryPendingDeletion = nil
    }

    private func deleteSABnzbdCategory(_ category: SABnzbdCategory) async {
        do { try await sabnzbdServiceManager.deleteCategory(name: category.name) }
        catch { actionError = ErrorAlertItem(title: "Couldn't Delete Category", message: error.localizedDescription) }
        sabnzbdCategoryPendingDeletion = nil
    }

    private func resetQBittorrentCategoryInputs() {
        newQBittorrentCategoryName = ""
        newQBittorrentCategoryPath = ""
        showingNewQBittorrentCategory = false
    }

    private var qBittorrentDeletionPresented: Binding<Bool> { Binding(get: { qBittorrentCategoryPendingDeletion != nil }, set: { if !$0 { qBittorrentCategoryPendingDeletion = nil } }) }
    private var sabnzbdDeletionPresented: Binding<Bool> { Binding(get: { sabnzbdCategoryPendingDeletion != nil }, set: { if !$0 { sabnzbdCategoryPendingDeletion = nil } }) }
}

private struct SABnzbdCategoryEditorTarget: Identifiable {
    let category: SABnzbdCategory?
    var id: String { category?.id ?? "new-category" }
}
