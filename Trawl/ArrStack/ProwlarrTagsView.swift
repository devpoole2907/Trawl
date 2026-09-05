import SwiftUI

struct ProwlarrTagsListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var viewModel: ProwlarrTagsViewModel
    @State private var showCreateTagAlert = false
    @State private var newTagName = ""
    @State private var tagPendingDelete: ArrTag?
    private let loadsDataOnAppear: Bool

    init(loadsDataOnAppear: Bool = true) {
        // Initialize synchronously so the view model is available immediately.
        let placeholder = ProwlarrTagsViewModel(serviceManager: ArrServiceManager())
        _viewModel = State(initialValue: placeholder)
        self.loadsDataOnAppear = loadsDataOnAppear
    }

    var body: some View {
        content
        .navigationTitle("Tags")
        .navigationSubtitle("Prowlarr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard loadsDataOnAppear else { return }
            viewModel = ProwlarrTagsViewModel(serviceManager: serviceManager)
            await viewModel.loadTags()
        }
        .toolbar {
            ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button {
                    showCreateTagAlert = true
                } label: {
                    Label("Add Tag", systemImage: "plus")
                }
                .disabled(!serviceManager.prowlarrConnected || viewModel.isSubmitting)
            }
        }
        .alert("Add Tag", isPresented: $showCreateTagAlert) {
            TextField("Name", text: $newTagName)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button("Add") {
                Task { await createTag() }
            }
            .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSubmitting)
            Button("Cancel", role: .cancel) {
                resetTagInput()
            }
        } message: {
            Text("Create a tag, then assign it to indexers and a proxy so the indexers route through that proxy.")
        }
        .alert(
            "Delete Tag?",
            isPresented: Binding(
                get: { tagPendingDelete != nil },
                set: { if !$0 { tagPendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let tag = tagPendingDelete else { return }
                self.tagPendingDelete = nil

                Task {
                    let removed = await viewModel.deleteTag(tag)
                    if removed {
                        InAppNotificationCenter.shared.showSuccess(title: "Tag Deleted", message: "\(tag.label) was removed from Prowlarr.")
                    } else if let error = viewModel.errorMessage {
                        InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
                        viewModel.clearError()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                tagPendingDelete = nil
            }
        } message: {
            Text("This removes the tag \"\(tagPendingDelete?.label ?? "")\" from Prowlarr. Indexers and proxies using it will lose the tag.")
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if viewModel.isLoading && viewModel.tags.isEmpty {
                Section {
                    ProgressView("Loading tags…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if let errorMessage = viewModel.errorMessage, !viewModel.isLoading, viewModel.tags.isEmpty {
                ServiceErrorView(
                    title: "Could Not Load Tags",
                    message: errorMessage,
                    identity: .prowlarr,
                    onRetry: { await viewModel.loadTags() }
                )
                .listRowBackground(Color.clear)
            } else if viewModel.tags.isEmpty {
                ContentUnavailableView(
                    "No Tags",
                    systemImage: "tag",
                    description: Text("Create a tag, then assign it to indexers and a proxy to route those indexers through the proxy.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.sortedTags) { tag in
                        tagRow(tag)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    tagPendingDelete = tag
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    tagPendingDelete = tag
                                }
                            }
                    }
                } footer: {
                    Text("Indexers route through a proxy when they share one of its tags.")
                }
            }
        }
        .refreshable {
            await viewModel.loadTags()
        }
    }

    private func tagRow(_ tag: ArrTag) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tag")
                .foregroundStyle(.teal)
                .frame(width: 24)

            Text(tag.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func createTag() async {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let created = await viewModel.createTag(label: name)
        if created {
            InAppNotificationCenter.shared.showSuccess(title: "Tag Created", message: "\(name) was added to Prowlarr.")
            resetTagInput()
        } else if let error = viewModel.errorMessage {
            InAppNotificationCenter.shared.showError(title: "Couldn't Create Tag", message: error)
            viewModel.clearError()
            resetTagInput()
        }
    }

    private func resetTagInput() {
        newTagName = ""
        showCreateTagAlert = false
    }
}

#if DEBUG
extension ProwlarrTagsListView {
    init(previewViewModel: ProwlarrTagsViewModel) {
        self.init(loadsDataOnAppear: false)
        self._viewModel = State(initialValue: previewViewModel)
    }
}

#Preview("Loaded") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrTagsViewModel(previewTags: ArrTag.previewList, serviceManager: manager)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrTagsListView(previewViewModel: viewModel)
        }
    }
}

#Preview("Empty") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrTagsViewModel(previewTags: [], serviceManager: manager)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrTagsListView(previewViewModel: viewModel)
        }
    }
}

#Preview("Error") {
    let manager = ArrServiceManager.preview(.allConfigured)
    let viewModel = ProwlarrTagsViewModel(
        previewTags: [],
        errorMessage: "Prowlarr returned 401 Unauthorized.",
        serviceManager: manager
    )
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager), arr: manager) {
        NavigationStack {
            ProwlarrTagsListView(previewViewModel: viewModel)
        }
    }
}
#endif
