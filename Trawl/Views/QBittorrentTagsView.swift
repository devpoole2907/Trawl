import SwiftUI

struct QBittorrentTagsView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService

    @State private var showCreateAlert = false
    @State private var newTagName = ""
    @State private var tagPendingDeletion: String?
    @State private var isSubmitting = false
    @State private var actionErrorAlert: ErrorAlertItem?

    var body: some View {
        List {
            if syncService.sortedTags.isEmpty {
                ContentUnavailableView(
                    "No Tags",
                    systemImage: "number",
                    description: Text("Create tags here, then assign them from torrent detail views.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Tags") {
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .navigationTitle("Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateAlert = true
                } label: {
                    Label("New Tag", systemImage: "plus")
                }
                .disabled(isSubmitting)
            }
        }
        .alert("Create Tag", isPresented: $showCreateAlert) {
            TextField("Name", text: $newTagName)
            Button("Create") {
                Task { await createTag() }
            }
            .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            Button("Cancel", role: .cancel) {
                resetCreateInputs()
            }
        } message: {
            Text("Tags help you group and filter torrents across categories.")
        }
        .alert("Delete Tag?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                guard let tagPendingDeletion else { return }
                Task { await deleteTag(tagPendingDeletion) }
            }
            Button("Cancel", role: .cancel) {
                tagPendingDeletion = nil
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
            get: { tagPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    tagPendingDeletion = nil
                }
            }
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

    private var deleteConfirmationMessage: String {
        guard let tagPendingDeletion else { return "" }
        return "This removes the tag \"\(tagPendingDeletion)\" from qBittorrent."
    }

    @ViewBuilder
    private func tagRow(name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .foregroundStyle(.cyan)
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

    private func createTag() async {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isSubmitting = true
        do {
            try await torrentService.createTags(tags: [name])
            syncService.addTagLocally(name: name)
            await syncService.refreshNow()
            actionErrorAlert = nil
            resetCreateInputs()
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Create Tag",
                message: error.localizedDescription
            )
        }
        isSubmitting = false
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

    private func resetCreateInputs() {
        newTagName = ""
        showCreateAlert = false
    }
}
