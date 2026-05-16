import SwiftUI

struct UnifiedUserListView: View {
    let jellyfinClient: JellyfinAPIClient
    let seerrClient: SeerrAPIClient?
    let seerrBaseURL: String?

    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var viewModel: UnifiedUserViewModel?
    @State private var showingAddUser = false
    @State private var showingJellyfinImport = false

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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if viewModel == nil {
                viewModel = UnifiedUserViewModel(
                    jellyfinClient: jellyfinClient,
                    seerrClient: seerrClient
                )
            }
            await viewModel?.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func content(viewModel: UnifiedUserViewModel) -> some View {
        List {
            if viewModel.isLoading && viewModel.users.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if viewModel.users.isEmpty && viewModel.jellyfinLoadError == nil {
                ContentUnavailableView(
                    "No Users",
                    systemImage: "person.2.slash",
                    description: Text("No user accounts were found.")
                )
                .listRowBackground(Color.clear)
            } else {
                if let error = viewModel.jellyfinLoadError {
                    Section("Jellyfin") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = viewModel.seerrLoadError {
                    Section("Seerr") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.users.isEmpty {
                    Section {
                        ForEach(viewModel.users) { user in
                            NavigationLink {
                                UnifiedUserDetailView(
                                    user: user,
                                    jellyfinClient: jellyfinClient,
                                    seerrClient: seerrClient,
                                    seerrBaseURL: seerrBaseURL,
                                    onJellyfinUserUpdated: { viewModel.applyUpdatedJellyfinUser($0) },
                                    onSeerrUserUpdated: { viewModel.applyUpdatedSeerrUser($0) },
                                    onSeerrUserDeleted: {
                                        guard let seerr = user.seerrUser else { return }
                                        viewModel.removeSeerrUser(seerr)
                                    },
                                    onJellyfinUserDeleted: {
                                        guard let jf = user.jellyfinUser else { return }
                                        viewModel.removeJellyfinUser(jf)
                                    }
                                )
                            } label: {
                                UnifiedUserRowView(user: user, seerrBaseURL: seerrBaseURL)
                            }
                        }
                    } header: {
                        Text("\(viewModel.users.count) \(viewModel.users.count == 1 ? "user" : "users")")
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
        .refreshable { await viewModel.load() }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                HStack(spacing: 12) {
                    Button {
                        showingAddUser = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create User")

                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(viewModel.isLoading)

                    if seerrClient != nil {
                        Menu {
                            Button {
                                showingJellyfinImport = true
                            } label: {
                                Label("Import Jellyfin Users", systemImage: "person.crop.circle.badge.plus")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("User Actions")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddUser) {
            UnifiedAddUserSheet { name, password in
                let user = try await jellyfinClient.createUser(name: name, password: password)
                viewModel.addCreatedJellyfinUser(user)
                inAppNotificationCenter.showSuccess(
                    title: "User Added",
                    message: "\(user.name) was added to Jellyfin.",
                    source: .inApp
                )
                return user
            } onImportToSeerr: { jellyfinUser in
                guard let client = seerrClient else { return }
                let imported = try await client.importUsersFromJellyfin(jellyfinUserIds: [jellyfinUser.id])
                viewModel.applySeerrImport(imported)
            }
        }
        .sheet(isPresented: $showingJellyfinImport) {
            if let seerrClient {
                SeerrJellyfinImportSheet(apiClient: seerrClient) { ids in
                    Task { await importJellyfinUsers(ids, viewModel: viewModel, seerrClient: seerrClient) }
                }
            }
        }
        .moreDestinationBackground(.userManagement)
    }

    private func importJellyfinUsers(
        _ ids: [String],
        viewModel: UnifiedUserViewModel,
        seerrClient: SeerrAPIClient
    ) async {
        do {
            let imported = try await seerrClient.importUsersFromJellyfin(jellyfinUserIds: ids)
            viewModel.applySeerrImport(imported)
            inAppNotificationCenter.showSuccess(
                title: "Users Imported",
                message: "\(imported.count) \(imported.count == 1 ? "user was" : "users were") imported to Seerr.",
                source: .inApp
            )
        } catch {
            inAppNotificationCenter.showError(
                title: "Import Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }
}

private struct UnifiedAddUserSheet: View {
    let create: (String, String?) async throws -> JellyfinUser
    let onImportToSeerr: (JellyfinUser) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @State private var name = ""
    @State private var password = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var createdUser: JellyfinUser?
    @State private var showSyncAlert = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AppSheetShell(
            title: "Add User",
            confirmTitle: "Add",
            isConfirmDisabled: trimmedName.isEmpty,
            isConfirmLoading: isCreating,
            onConfirm: { Task { await createUser() } },
            detents: [.medium],
            dragIndicator: .visible
        ) {
            Form {
                Section("Account") {
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
        }
        .alert("Sync to Seerr?", isPresented: $showSyncAlert) {
            Button("Sync") {
                Task { await syncToSeerr() }
            }
            Button("Skip", role: .cancel) { dismiss() }
        } message: {
            if let user = createdUser {
                Text("Would you like to add \(user.name) to Seerr?")
            }
        }
    }

    private func createUser() async {
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        do {
            let user = try await create(trimmedName, password.isEmpty ? nil : password)
            isCreating = false
            if seerrServiceManager.isConnected {
                createdUser = user
                showSyncAlert = true
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }

    private func syncToSeerr() async {
        guard let user = createdUser else { return }
        try? await onImportToSeerr(user)
        dismiss()
    }
}

struct UnifiedUserRowView: View {
    let user: UnifiedUserViewModel.UnifiedUser
    let seerrBaseURL: String?

    var body: some View {
        HStack(spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if user.isInJellyfin {
                        serviceChip(
                            label: user.jellyfinUser?.isDisabled == true ? "Disabled" : "Jellyfin",
                            icon: ServiceIdentity.jellyfin.systemImage,
                            color: user.jellyfinUser?.isDisabled == true ? .red : ServiceIdentity.jellyfin.brandColor
                        )
                    } else {
                        serviceChip(label: "No Jellyfin", icon: ServiceIdentity.jellyfin.tabSystemImage, color: .secondary)
                    }

                    if user.isInSeerr {
                        serviceChip(
                            label: user.isInJellyfin ? (user.seerrUser?.permissionLevelLabel ?? "Seerr") : "Seerr only",
                            icon: ServiceIdentity.seerr.systemImage,
                            color: ServiceIdentity.seerr.brandColor
                        )
                    } else {
                        serviceChip(label: "No Seerr", icon: ServiceIdentity.seerr.tabSystemImage, color: .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatarView: some View {
        let avatarURL = user.avatarURL(seerrBaseURL: seerrBaseURL)
        ArrArtworkView(url: avatarURL) {
            Circle()
                .fill(avatarFillColor.opacity(0.15))
                .overlay {
                    Image(systemName: user.jellyfinUser?.isAdministrator == true ? "person.badge.key.fill" : "person.fill")
                        .font(.body)
                        .foregroundStyle(avatarFillColor)
                }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var avatarFillColor: Color {
        if user.jellyfinUser?.isAdministrator == true { return .indigo }
        if user.isInJellyfin { return .blue }
        return .secondary
    }

    private func serviceChip(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}
