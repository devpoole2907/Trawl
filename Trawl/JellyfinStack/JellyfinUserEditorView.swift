import SwiftUI

struct JellyfinUserEditorView: View {
    let onSave: (JellyfinUser) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var viewModel: JellyfinUserEditorViewModel
    @State private var isEditing = false
    @State private var errorAlert: ErrorAlertItem?
    @State private var showResetPassword = false
    @State private var showDeleteConfirmation = false

    init(
        user: JellyfinUser,
        apiClient: JellyfinAPIClient,
        onSave: @escaping (JellyfinUser) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self._viewModel = State(initialValue: JellyfinUserEditorViewModel(user: user, apiClient: apiClient))
    }

    var body: some View {
        Form {
            Section("User") {
                LabeledContent("Name", value: viewModel.user.name)

                if let serverId = viewModel.user.serverId {
                    LabeledContent("Server ID", value: serverId)
                        .font(.caption)
                }

                if let lastActivity = viewModel.user.lastActivityDate, !lastActivity.isEmpty {
                    LabeledContent("Last Activity", value: formattedDate(lastActivity))
                }

                if let lastLogin = viewModel.user.lastLoginDate, !lastLogin.isEmpty {
                    LabeledContent("Last Login", value: formattedDate(lastLogin))
                }
            }

            if isEditing {
                editingContent
            } else {
                viewContent
            }

            Section {
                Button {
                    showResetPassword = true
                } label: {
                    Label("Reset Password", systemImage: "key")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete User", systemImage: "trash")
                }
            }
        }
        .navigationTitle(viewModel.user.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isEditing {
                ToolbarItem(placement: platformCancellationPlacement) {
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
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button("Edit") {
                        withAnimation { isEditing = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showResetPassword) {
            JellyfinResetPasswordSheet(userId: viewModel.user.id, apiClient: viewModel.apiClient)
        }
        .alert("Delete User?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.deleteUser() {
                        onDelete?()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This permanently removes \(viewModel.user.name) from Jellyfin.")
        }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "User Action Failed", message: message)
            viewModel.clearError()
        }
    }

    @ViewBuilder
    private var viewContent: some View {
        Section("Permissions") {
            policyRow("Administrator", value: viewModel.policy.isAdministrator, systemImage: "person.badge.key")
            policyRow("Disabled", value: viewModel.policy.isDisabled, systemImage: "person.slash")
            policyRow("Hidden", value: viewModel.policy.isHidden, systemImage: "eye.slash")
            policyRow("Content Deletion", value: viewModel.policy.enableContentDeletion, systemImage: "trash")
            policyRow("Media Playback", value: viewModel.policy.enableMediaPlayback, systemImage: "play.circle")
            policyRow("Live TV Access", value: viewModel.policy.enableLiveTvAccess, systemImage: "tv")
            policyRow("Live TV Management", value: viewModel.policy.enableLiveTvManagement, systemImage: "tv.badge.wifi")
            policyRow("Remote Access", value: viewModel.policy.enableRemoteAccess, systemImage: "wifi")
            policyRow("Shared Device Control", value: viewModel.policy.enableSharedDeviceControl, systemImage: "rectangle.on.rectangle")
        }
    }

    @ViewBuilder
    private var editingContent: some View {
        Section {
            if viewModel.policy.isAdministrator == true {
                Label("Admin includes every other permission automatically.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Access") {
            policyToggle("Administrator", binding: viewModel.policyBinding(\.isAdministrator), systemImage: "person.badge.key")
            policyToggle("Disabled", binding: viewModel.policyBinding(\.isDisabled), systemImage: "person.slash")
            policyToggle("Hidden", binding: viewModel.policyBinding(\.isHidden), systemImage: "eye.slash")
        }

        Section("Permissions") {
            policyToggle("Content Deletion", binding: viewModel.policyBinding(\.enableContentDeletion), systemImage: "trash")
            policyToggle("Media Playback", binding: viewModel.policyBinding(\.enableMediaPlayback), systemImage: "play.circle")
            policyToggle("Live TV Access", binding: viewModel.policyBinding(\.enableLiveTvAccess), systemImage: "tv")
            policyToggle("Live TV Management", binding: viewModel.policyBinding(\.enableLiveTvManagement), systemImage: "tv.badge.wifi")
            policyToggle("Remote Access", binding: viewModel.policyBinding(\.enableRemoteAccess), systemImage: "wifi")
            policyToggle("Shared Device Control", binding: viewModel.policyBinding(\.enableSharedDeviceControl), systemImage: "rectangle.on.rectangle")
        }
    }

    @ViewBuilder
    private func policyRow(_ label: String, value: Bool?, systemImage: String) -> some View {
        let enabled = value == true
        LabeledContent {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(enabled ? .green : .secondary)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    private func policyToggle(_ label: String, binding: Binding<Bool>, systemImage: String) -> some View {
        Toggle(isOn: binding) {
            Label(label, systemImage: systemImage)
        }
        .disabled(viewModel.policy.isAdministrator == true && label != "Administrator" && label != "Disabled" && label != "Hidden")
    }

    private func formattedDate(_ raw: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Reset Password Sheet

private struct JellyfinResetPasswordSheet: View {
    let userId: String
    let apiClient: JellyfinAPIClient

    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var isResetting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Password") {
                    SecureField("Required", text: $currentPassword)
                        .textContentType(.password)
                }

                Section("New Password") {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Reset Password")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: platformCancellationPlacement) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isResetting {
                        ProgressView()
                    } else {
                        Button("Reset") {
                            Task { await resetPassword() }
                        }
                        .disabled(newPassword.isEmpty || currentPassword.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func resetPassword() async {
        isResetting = true
        errorMessage = nil
        do {
            try await apiClient.updateUserPassword(
                id: userId,
                currentPassword: currentPassword,
                newPassword: newPassword,
                resetPassword: true
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isResetting = false
    }
}
