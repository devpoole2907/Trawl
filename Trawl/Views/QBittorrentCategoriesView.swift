import SwiftUI

struct QBittorrentCategoriesView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService

    @State private var showCreateAlert = false
    @State private var newCategoryName = ""
    @State private var newCategorySavePath = ""
    @State private var categoryPendingDeletion: String?
    @State private var isSubmitting = false
    @State private var actionErrorAlert: ErrorAlertItem?

    var body: some View {
        List {
            if syncService.sortedCategoryNames.isEmpty {
                ContentUnavailableView(
                    "No Categories",
                    systemImage: "tag",
                    description: Text("Create categories here, then assign them from torrent detail views.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Categories") {
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
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .navigationTitle("Categories")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateAlert = true
                } label: {
                    Label("New Category", systemImage: "plus")
                }
                .disabled(isSubmitting)
            }
        }
        .alert("Create Category", isPresented: $showCreateAlert) {
            TextField("Name", text: $newCategoryName)
            TextField("Save Path (Optional)", text: $newCategorySavePath)
            Button("Create") {
                Task { await createCategory() }
            }
            .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            Button("Cancel", role: .cancel) {
                resetCreateInputs()
            }
        } message: {
            Text("Leave the save path empty to use qBittorrent's default behavior.")
        }
        .alert("Delete Category?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                guard let categoryPendingDeletion else { return }
                Task { await deleteCategory(categoryPendingDeletion) }
            }
            Button("Cancel", role: .cancel) {
                categoryPendingDeletion = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(item: $actionErrorAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            await syncService.refreshNow()
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { categoryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    categoryPendingDeletion = nil
                }
            }
        )
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.blue.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }

    private var deleteConfirmationMessage: String {
        guard let categoryPendingDeletion else { return "" }
        return "This removes the category \"\(categoryPendingDeletion)\" from qBittorrent."
    }

    @ViewBuilder
    private func categoryRow(name: String) -> some View {
        let category = syncService.categories[name]

        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .foregroundStyle(.blue)
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
            resetCreateInputs()
        } catch {
            resetCreateInputs()
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

    private func resetCreateInputs() {
        newCategoryName = ""
        newCategorySavePath = ""
        showCreateAlert = false
    }
}