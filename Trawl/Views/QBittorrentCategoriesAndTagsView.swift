import SwiftUI

struct QBittorrentCategoriesAndTagsView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    
    @State private var selectedTab: Int = 0 // 0 = Categories, 1 = Tags
    
    // Categories State
    @State private var showCreateCategoryAlert = false
    @State private var newCategoryName = ""
    @State private var newCategorySavePath = ""
    @State private var categoryPendingDeletion: String?
    
    // Tags State
    @State private var showCreateTagAlert = false
    @State private var newTagName = ""
    @State private var tagPendingDeletion: String?
    
    // Shared State
    @State private var isSubmitting = false
    @State private var actionErrorAlert: ErrorAlertItem?

    var body: some View {
        Group {
            List {
                if selectedTab == 0 {
                    categoriesList
                } else {
                    tagsList
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
        }
        .moreDestinationBackground(.categoriesAndTags)
        .navigationTitle(selectedTab == 0 ? "Categories" : "Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if selectedTab == 0 {
                        showCreateCategoryAlert = true
                    } else {
                        showCreateTagAlert = true
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .disabled(isSubmitting)
            }
        }
        .alert("Create Category", isPresented: $showCreateCategoryAlert) {
            TextField("Name", text: $newCategoryName)
            TextField("Save Path (Optional)", text: $newCategorySavePath)
            Button("Create") {
                Task { await createCategory() }
            }
            .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            Button("Cancel", role: .cancel) {
                resetCategoryInputs()
            }
        } message: {
            Text("Leave the save path empty to use qBittorrent's default behavior.")
        }
        .alert("Delete Category?", isPresented: deleteCategoryAlertBinding) {
            Button("Delete", role: .destructive) {
                guard let categoryPendingDeletion else { return }
                Task { await deleteCategory(categoryPendingDeletion) }
            }
            Button("Cancel", role: .cancel) {
                categoryPendingDeletion = nil
            }
        } message: {
            Text("This removes the category \"\(categoryPendingDeletion ?? "")\" from qBittorrent.")
        }
        .alert("Create Tag", isPresented: $showCreateTagAlert) {
            TextField("Name", text: $newTagName)
            Button("Create") {
                Task { await createTag() }
            }
            .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            Button("Cancel", role: .cancel) {
                resetTagInputs()
            }
        } message: {
            Text("Tags help you group and filter torrents across categories.")
        }
        .alert("Delete Tag?", isPresented: deleteTagAlertBinding) {
            Button("Delete", role: .destructive) {
                guard let tagPendingDeletion else { return }
                Task { await deleteTag(tagPendingDeletion) }
            }
            Button("Cancel", role: .cancel) {
                tagPendingDeletion = nil
            }
        } message: {
            Text("This removes the tag \"\(tagPendingDeletion ?? "")\" from qBittorrent.")
        }
        .errorAlert(item: $actionErrorAlert)
        .task {
            await syncService.refreshNow()
        }
        .safeAreaInset(edge: .top) {
            Picker("View", selection: Binding(
                get: { selectedTab },
                set: { newValue in withAnimation { selectedTab = newValue } }
            )) {
                Text("Categories").tag(0)
                Text("Tags").tag(1)
            }
            .pickerStyle(.segmented)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, 48)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    
    // MARK: - Categories Subviews
    
    @ViewBuilder
    private var categoriesList: some View {
        if syncService.sortedCategoryNames.isEmpty {
            ContentUnavailableView(
                "No Categories",
                systemImage: "tag",
                description: Text("Create categories here, then assign them from torrent detail views.")
            )
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(syncService.sortedCategoryNames, id: \.self) { category in
                    categoryRow(name: category)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                categoryPendingDeletion = category
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
    
    @ViewBuilder
    private func categoryRow(name: String) -> some View {
        let category = syncService.categories[name]

        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .foregroundStyle(MoreDestinationAccent.categoriesAndTags.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.weight(.medium))
                if let savePath = category?.savePath, !savePath.isEmpty {
                    Text(savePath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Uses default save path")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Tags Subviews

    @ViewBuilder
    private var tagsList: some View {
        if syncService.sortedTags.isEmpty {
            ContentUnavailableView(
                "No Tags",
                systemImage: "number",
                description: Text("Create tags here, then assign them from torrent detail views.")
            )
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(syncService.sortedTags, id: \.self) { tag in
                    tagRow(name: tag)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                tagPendingDeletion = tag
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
    
    @ViewBuilder
    private func tagRow(name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .foregroundStyle(MoreDestinationAccent.categoriesAndTags.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.weight(.medium))
                Text("Available for torrent assignment")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions
    
    private func createCategory() async {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let savePath = newCategorySavePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isSubmitting = true
        do {
            try await torrentService.createCategory(
                name: name,
                savePath: savePath.isEmpty ? nil : savePath
            )
            syncService.addCategoryLocally(name: name, savePath: savePath.isEmpty ? nil : savePath)
            await syncService.refreshNow()
            actionErrorAlert = nil
            resetCategoryInputs()
        } catch {
            resetCategoryInputs()
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Create Category",
                message: error.localizedDescription
            )
        }
        isSubmitting = false
    }

    private func deleteCategory(_ category: String) async {
        isSubmitting = true
        do {
            try await torrentService.removeCategories(names: [category])
            syncService.removeCategoriesLocally(names: [category])
            await syncService.refreshNow()
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Delete Category",
                message: error.localizedDescription
            )
        }
        categoryPendingDeletion = nil
        isSubmitting = false
    }

    private func createTag() async {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await torrentService.createTags(tags: [name])
            syncService.addTagLocally(name: name)
            await syncService.refreshNow()
            actionErrorAlert = nil
            resetTagInputs()
        } catch {
            resetTagInputs()
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Create Tag",
                message: error.localizedDescription
            )
        }
    }

    private func deleteTag(_ tag: String) async {
        isSubmitting = true
        do {
            try await torrentService.deleteTags(tags: [tag])
            syncService.removeTagsLocally(names: [tag])
            await syncService.refreshNow()
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Delete Tag",
                message: error.localizedDescription
            )
        }
        tagPendingDeletion = nil
        isSubmitting = false
    }

    // MARK: - Helpers

    private func resetCategoryInputs() {
        newCategoryName = ""
        newCategorySavePath = ""
        showCreateCategoryAlert = false
    }
    
    private func resetTagInputs() {
        newTagName = ""
        showCreateTagAlert = false
    }

    private var deleteCategoryAlertBinding: Binding<Bool> {
        Binding(
            get: { categoryPendingDeletion != nil },
            set: { if !$0 { categoryPendingDeletion = nil } }
        )
    }
    
    private var deleteTagAlertBinding: Binding<Bool> {
        Binding(
            get: { tagPendingDeletion != nil },
            set: { if !$0 { tagPendingDeletion = nil } }
        )
    }
}
