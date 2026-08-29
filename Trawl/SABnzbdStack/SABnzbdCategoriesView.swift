import SwiftUI

/// SABnzbd's categories and post-processing scripts.
///
/// Mirrors `QBittorrentCategoriesAndTagsView`'s shape - one list, a segmented
/// switch, add in the toolbar, swipe to delete - so the two clients' management
/// screens read the same. The halves differ where the services do: a SABnzbd
/// category carries a folder, a script and a priority rather than just a save
/// path, and scripts are files on SABnzbd's disk with no API to create them, so
/// that half is a read-only list rather than an editor.
struct SABnzbdCategoriesView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager

    @State private var selectedTab = 0 // 0 = Categories, 1 = Scripts
    @State private var editorTarget: EditorTarget?
    @State private var categoryPendingDeletion: SABnzbdCategory?
    @State private var actionError: String?

    private struct EditorTarget: Identifiable {
        let category: SABnzbdCategory?
        var id: String { category?.id ?? "new-category" }
    }

    private var categories: [SABnzbdCategory] {
        serviceManager.categoryConfigs.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var scripts: [String] { serviceManager.scripts }

    var body: some View {
        List {
            if let error = serviceManager.categoryConfigsError {
                Section("Unavailable") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if selectedTab == 0 {
                categoriesList
            } else {
                scriptsList
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Section",
                selection: Binding(
                    get: { selectedTab },
                    set: { newValue in withAnimation { selectedTab = newValue } }
                ),
                items: [
                    TrawlSegmentBarItem("Categories", value: 0),
                    TrawlSegmentBarItem("Scripts", value: 1)
                ],
                alignment: .center
            )
        }
        .navigationTitle(selectedTab == 0 ? "Categories" : "Scripts")
        .navigationSubtitle("SABnzbd")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if selectedTab == 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorTarget = EditorTarget(category: nil)
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
            }
        }
        .refreshable { await serviceManager.refreshCategoryConfigs() }
        .task { await serviceManager.refreshCategoryConfigs() }
        .sheet(item: $editorTarget) { target in
            SABnzbdCategoryEditorSheet(existingCategory: target.category) {
                editorTarget = nil
            }
            .environment(serviceManager)
        }
        .alert(
            "Delete Category?",
            isPresented: Binding(
                get: { categoryPendingDeletion != nil },
                set: { if !$0 { categoryPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let category = categoryPendingDeletion else { return }
                categoryPendingDeletion = nil
                Task { await delete(category) }
            }
            Button("Cancel", role: .cancel) { categoryPendingDeletion = nil }
        } message: {
            Text("This removes the category from SABnzbd. Existing downloads keep their folders.")
        }
        .alert(
            "Couldn't Delete Category",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var categoriesList: some View {
        if categories.isEmpty {
            Section {
                if serviceManager.isLoadingCategoryConfigs {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading categories…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if serviceManager.categoryConfigsError == nil {
                    Text("SABnzbd has no categories configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Section {
                ForEach(categories) { category in
                    Button {
                        editorTarget = EditorTarget(category: category)
                    } label: {
                        categoryRow(category)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // SABnzbd's catch-all can be configured but not removed.
                        if !category.isDefault {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                categoryPendingDeletion = category
                            }
                        }
                    }
                }
            } footer: {
                Text("Categories decide where a download lands, which script runs afterwards, and its priority.")
            }
        }
    }

    @ViewBuilder
    private var scriptsList: some View {
        if scripts.isEmpty {
            Section {
                Text("SABnzbd has no post-processing scripts installed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Scripts are files in SABnzbd's scripts folder. They have to be added on the server itself.")
            }
        } else {
            Section {
                ForEach(scripts, id: \.self) { script in
                    Label(script, systemImage: "terminal")
                        .font(.subheadline)
                }
            } footer: {
                Text("Scripts are files in SABnzbd's scripts folder, so they're listed here but managed on the server itself.")
            }
        }
    }

    private func categoryRow(_ category: SABnzbdCategory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(category.displayName)
                .font(.subheadline.weight(.semibold))

            if let directory = category.directory, !directory.isEmpty {
                Text(directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 6) {
                ForEach(chips(for: category), id: \.self) { chip in
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

    private func chips(for category: SABnzbdCategory) -> [String] {
        var chips: [String] = []
        if let pp = category.postProcessing, let level = SABnzbdPostProcessing(rawValue: pp) {
            chips.append(level.title)
        }
        if let priority = category.priority,
           let named = SABnzbdCategoryPriority(rawValue: priority),
           named != .default {
            chips.append(named.title)
        }
        if let script = category.realScriptName {
            chips.append(script)
        }
        return chips
    }

    private func delete(_ category: SABnzbdCategory) async {
        do {
            try await serviceManager.deleteCategory(name: category.name)
        } catch {
            actionError = error.localizedDescription
        }
    }
}
