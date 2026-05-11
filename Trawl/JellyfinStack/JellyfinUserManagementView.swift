import SwiftUI

struct JellyfinUserManagementView: View {
    let apiClient: JellyfinAPIClient

    @Environment(JellyfinServiceManager.self) private var serviceManager
    @State private var viewModel: JellyfinUserManagementViewModel?
    @State private var errorAlert: ErrorAlertItem?
    @State private var userPendingDeletion: JellyfinUser?
    @State private var showingAddUser = false

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    private var subtitle: String? {
        let count = viewModel?.totalUserCount ?? serviceManager.cachedUserCount
        guard let count else { return nil }
        return "\(count) \(count == 1 ? "user" : "users")"
    }

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text("Users").font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = JellyfinUserManagementViewModel(
                    apiClient: apiClient,
                    serviceManager: serviceManager
                )
            }
            await viewModel?.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func content(viewModel: JellyfinUserManagementViewModel) -> some View {
        List {
            if viewModel.isLoading && viewModel.users.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if viewModel.users.isEmpty {
                ContentUnavailableView(
                    "No Users",
                    systemImage: "person.2.slash",
                    description: Text("No users were returned by Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.users) { user in
                        NavigationLink {
                            JellyfinUserEditorView(user: user, apiClient: apiClient) { updatedUser in
                                viewModel.applyUpdatedUser(updatedUser)
                            } onDelete: {
                                viewModel.removeUser(user)
                            }
                        } label: {
                            jellyfinUserRow(user)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                userPendingDeletion = user
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
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await viewModel.loadUsers() }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                HStack(spacing: 12) {
                    Button {
                        showingAddUser = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add User")

                    Button {
                        Task { await viewModel.loadUsers() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Users")
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .sheet(isPresented: $showingAddUser) {
            JellyfinAddUserSheet { name, password in
                try await viewModel.createUser(name: name, password: password)
            }
        }
        .confirmationDialog("Delete User?", isPresented: deleteDialogPresented) {
            if let user = userPendingDeletion {
                Button("Delete \(user.name)", role: .destructive) {
                    Task { await viewModel.deleteUser(user) }
                    userPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                userPendingDeletion = nil
            }
        } message: {
            Text("This permanently removes the user from Jellyfin.")
        }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Admin Action Failed", message: message)
            viewModel.clearError()
        }
    }

    @ViewBuilder
    private func jellyfinUserRow(_ user: JellyfinUser) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(user.isAdministrator ? Color.indigo.opacity(0.15) : Color.blue.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: user.isAdministrator ? "person.badge.key.fill" : "person.fill")
                        .font(.body)
                        .foregroundStyle(user.isAdministrator ? .indigo : .blue)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(user.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if user.isAdministrator {
                        BadgeLabel("Admin", color: .indigo)
                    }
                    if user.isDisabled {
                        BadgeLabel("Disabled", color: .red)
                    }
                    if user.isHidden {
                        BadgeLabel("Hidden", color: .secondary)
                    }

                    if let lastActivity = user.lastActivityDate, !lastActivity.isEmpty {
                        Text(relativeDate(from: lastActivity))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func relativeDate(from raw: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { userPendingDeletion != nil },
            set: { if !$0 { userPendingDeletion = nil } }
        )
    }
}

private struct JellyfinAddUserSheet: View {
    let create: (String, String?) async throws -> JellyfinUser

    @Environment(\.dismiss) private var dismiss
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @State private var name = ""
    @State private var password = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var createdUser: JellyfinUser?
    @State private var showSyncAlert = false
    @State private var isSyncing = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("User") {
                    TextField("Username", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
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
            .navigationTitle("Add User")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: platformCancellationPlacement) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Add") {
                            Task { await addUser() }
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .alert("Sync to Seerr?", isPresented: $showSyncAlert) {
            Button("Sync") {
                Task { await performSyncToSeerr() }
            }
            Button("Skip", role: .cancel) {
                dismiss()
            }
        } message: {
            if let user = createdUser {
                Text("Would you like to add \(user.name) to Seerr?")
            }
        }
    }

    private func addUser() async {
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil

        do {
            let created = try await create(
                trimmedName,
                password.isEmpty ? nil : password
            )
            isCreating = false
            inAppNotificationCenter.showSuccess(
                title: "User Added",
                message: "\(created.name) was added to Jellyfin.",
                source: .inApp
            )
            if seerrServiceManager.isConnected {
                createdUser = created
                showSyncAlert = true
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }

    private func performSyncToSeerr() async {
        guard let user = createdUser, let client = seerrServiceManager.activeClient else { return }
        isSyncing = true
        do {
            _ = try await client.importUsersFromJellyfin(jellyfinUserIds: [user.id])
        } catch {
            inAppNotificationCenter.showError(
                title: "Seerr Sync Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
        isSyncing = false
        dismiss()
    }
}

private struct BadgeLabel: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
