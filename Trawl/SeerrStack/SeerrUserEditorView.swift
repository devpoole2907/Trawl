import Observation
import SwiftUI

struct SeerrUserEditorView: View {
    let onSave: (SeerrUser) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SeerrUserEditorViewModel
    @State private var isEditing = false
    @State private var errorAlert: ErrorAlertItem?

    init(user: SeerrUser, apiClient: SeerrAPIClient, onSave: @escaping (SeerrUser) -> Void) {
        self.onSave = onSave
        self._viewModel = State(initialValue: SeerrUserEditorViewModel(user: user, apiClient: apiClient))
    }

    var body: some View {
        Form {
            Section("User") {
                LabeledContent("Name", value: viewModel.user.displayName)
                if let email = viewModel.user.email {
                    LabeledContent("Email", value: email)
                }
                LabeledContent("Role", value: viewModel.permissionLevelLabel)
            }

            if isEditing {
                editingContent
            } else {
                viewContent
            }
        }
        .navigationTitle(viewModel.user.displayName)
        .navigationSubtitle("Seerr")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.reset()
                        withAnimation { isEditing = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                if let updatedUser = await viewModel.save() {
                                    onSave(updatedUser)
                                    withAnimation { isEditing = false }
                                }
                            }
                        }
                        .disabled(!viewModel.hasChanges)
                    }
                }
            } else {
                ToolbarItem(placement: .automatic) {
                    Button("Edit") {
                        withAnimation { isEditing = true }
                    }
                }
            }
        }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Save Failed", message: message)
            viewModel.clearError()
        }
    }

    // MARK: - View Mode

    @ViewBuilder
    private var viewContent: some View {
        let activeGroups = SeerrPermission.editableGroups
            .map { (category: $0.category, permissions: $0.permissions.filter { viewModel.contains($0) }) }
            .filter { !$0.permissions.isEmpty }

        if activeGroups.isEmpty {
            Section("Permissions") {
                Text("No permissions granted")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(activeGroups, id: \.category.id) { group in
                Section(group.category.rawValue) {
                    ForEach(group.permissions) { permission in
                        Label(permission.title, systemImage: permission.symbolName)
                    }
                }
            }
        }
    }

    // MARK: - Edit Mode

    @ViewBuilder
    private var editingContent: some View {
        if viewModel.isAdminEnabled {
            Section {
                Label("Admin includes every other permission automatically.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        ForEach(SeerrPermission.editableGroups, id: \.category.id) { group in
            Section(group.category.rawValue) {
                ForEach(group.permissions) { permission in
                    Toggle(isOn: Binding(
                        get: { viewModel.contains(permission) },
                        set: { viewModel.set(permission, enabled: $0) }
                    )) {
                        Label(permission.title, systemImage: permission.symbolName)
                    }
                    .disabled(viewModel.isAdminEnabled && permission != .admin)
                }
            }
        }
    }
}

#if DEBUG
extension SeerrUserEditorView {
    init(
        previewViewModel: SeerrUserEditorViewModel,
        isEditing: Bool = false,
        onSave: @escaping (SeerrUser) -> Void = { _ in }
    ) {
        self.onSave = onSave
        self._viewModel = State(initialValue: previewViewModel)
        self._isEditing = State(initialValue: isEditing)
    }
}

#Preview("Seerr User Editor - Standard") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrUserEditorView(
                previewViewModel: SeerrUserEditorViewModel(previewUser: .previewRequester)
            )
        }
    }
}

#Preview("Seerr User Editor - Editing") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrUserEditorView(
                previewViewModel: SeerrUserEditorViewModel(previewUser: .previewRequester),
                isEditing: true
            )
        }
    }
}

#Preview("Seerr User Editor - Admin") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrUserEditorView(
                previewViewModel: SeerrUserEditorViewModel(previewUser: .previewAdmin),
                isEditing: true
            )
        }
    }
}

#Preview("Seerr User Editor - Long Name") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrUserEditorView(
                previewViewModel: SeerrUserEditorViewModel(previewUser: .previewLongName)
            )
        }
    }
}
#endif
