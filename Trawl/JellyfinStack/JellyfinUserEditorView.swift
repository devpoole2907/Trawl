import SwiftUI

struct JellyfinUserEditorView: View {
    let onSave: (JellyfinUser) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @State private var viewModel: JellyfinUserEditorViewModel
    @State private var isEditing = false
    @State private var errorAlert: ErrorAlertItem?
    @State private var showResetPassword = false
    @State private var showDeleteConfirmation = false
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var syncIsError = false

    private enum PolicyField {
        case isAdministrator
        case isDisabled
        case isHidden
        case enableContentDeletion
        case enableMediaPlayback
        case enableLiveTvAccess
        case enableLiveTvManagement
        case enableRemoteAccess
        case enableSharedDeviceControl

        var allowsEditWhenAdmin: Bool {
            switch self {
            case .isAdministrator, .isDisabled, .isHidden:
                true
            default:
                false
            }
        }
    }

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
                    Label("Remove User", systemImage: "trash")
                }
            }

            if seerrServiceManager.isConnected || seerrServiceManager.isConnecting || seerrServiceManager.connectionError != nil {
                Section("Seerr") {
                    Button {
                        Task { await syncToSeerr() }
                    } label: {
                        HStack {
                            Label("Sync to Seerr", systemImage: "arrow.triangle.merge")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isSyncing || !seerrServiceManager.isConnected)

                    if let syncMessage {
                        Text(syncMessage)
                            .font(.caption)
                            .foregroundStyle(syncIsError ? .red : .secondary)
                    }
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
        .alert("Remove User?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
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
            policyToggle("Administrator", field: .isAdministrator, binding: viewModel.policyBinding(\.isAdministrator), systemImage: "person.badge.key")
            policyToggle("Disabled", field: .isDisabled, binding: viewModel.policyBinding(\.isDisabled), systemImage: "person.slash")
            policyToggle("Hidden", field: .isHidden, binding: viewModel.policyBinding(\.isHidden), systemImage: "eye.slash")
        }

        Section("Permissions") {
            policyToggle("Content Deletion", field: .enableContentDeletion, binding: viewModel.policyBinding(\.enableContentDeletion), systemImage: "trash")
            policyToggle("Media Playback", field: .enableMediaPlayback, binding: viewModel.policyBinding(\.enableMediaPlayback), systemImage: "play.circle")
            policyToggle("Live TV Access", field: .enableLiveTvAccess, binding: viewModel.policyBinding(\.enableLiveTvAccess), systemImage: "tv")
            policyToggle("Live TV Management", field: .enableLiveTvManagement, binding: viewModel.policyBinding(\.enableLiveTvManagement), systemImage: "tv.badge.wifi")
            policyToggle("Remote Access", field: .enableRemoteAccess, binding: viewModel.policyBinding(\.enableRemoteAccess), systemImage: "wifi")
            policyToggle("Shared Device Control", field: .enableSharedDeviceControl, binding: viewModel.policyBinding(\.enableSharedDeviceControl), systemImage: "rectangle.on.rectangle")
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

    private func policyToggle(_ label: String, field: PolicyField, binding: Binding<Bool>, systemImage: String) -> some View {
        Toggle(isOn: binding) {
            Label(label, systemImage: systemImage)
        }
        .disabled(viewModel.policy.isAdministrator == true && !field.allowsEditWhenAdmin)
    }

    private func syncToSeerr() async {
        guard let client = seerrServiceManager.activeClient else { return }
        isSyncing = true
        syncMessage = nil
        do {
            let importedUsers = try await client.importUsersFromJellyfin(jellyfinUserIds: [viewModel.user.id])
            let importedName = importedUsers.first?.displayName ?? viewModel.user.name
            syncMessage = "Synced \(importedName) to Seerr."
            syncIsError = false
            inAppNotificationCenter.showSuccess(
                title: "Seerr Sync Complete",
                message: syncMessage ?? "Synced to Seerr.",
                source: .inApp
            )
        } catch {
            syncMessage = error.localizedDescription
            syncIsError = true
        }
        isSyncing = false
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
        AppSheetShell(
            title: "Reset Password",
            confirmTitle: "Reset",
            isConfirmDisabled: newPassword.isEmpty || currentPassword.isEmpty,
            isConfirmLoading: isResetting,
            onConfirm: { Task { await resetPassword() } },
            detents: [.medium]
        ) {
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
            .presentationDragIndicator(.visible)
        }
    }

    private func resetPassword() async {
        isResetting = true
        errorMessage = nil
        do {
            try await apiClient.updateUserPassword(
                id: userId,
                currentPassword: currentPassword,
                newPassword: newPassword,
                resetPassword: false
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isResetting = false
    }
}
