import SwiftUI

struct SeerrUserManagementView: View {
    let apiClient: SeerrAPIClient

    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @State private var viewModel: SeerrUserManagementViewModel?
    @State private var errorAlert: ErrorAlertItem?
    @State private var userPendingDeletion: SeerrUser?
    @State private var showingJellyfinImport = false

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    private var subtitle: String? {
        let count = viewModel?.totalUserCount ?? seerrServiceManager.cachedUserCount
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
        .navigationTitle("User Management")
        .modifier(SeerrUserSubtitleModifier(subtitle: subtitle))
        .task {
            if viewModel == nil {
                viewModel = SeerrUserManagementViewModel(
                    apiClient: apiClient,
                    serviceManager: seerrServiceManager
                )
            }
            await viewModel?.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func content(viewModel: SeerrUserManagementViewModel) -> some View {
        List {
            if !viewModel.users.isEmpty {
                Section {
                    LabeledContent("Imported Users", value: "\(viewModel.totalUserCount)")
                    LabeledContent("Permission Scope", value: "Admin only")
                }
            }

            if viewModel.isLoading && viewModel.users.isEmpty {
                Section {
                    ProgressView("Loading users...")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if viewModel.users.isEmpty {
                Section {
                    ContentUnavailableView("No Users", systemImage: "person.2.slash", description: Text("No imported users were returned by Seerr."))
                }
            } else {
                Section {
                    ForEach(viewModel.users) { user in
                        NavigationLink {
                            SeerrUserEditorView(user: user, apiClient: apiClient) { updatedUser in
                                viewModel.applyUpdatedUser(updatedUser)
                            }
                        } label: {
                            SeerrUserRow(user: user, baseURL: apiClient.baseURL)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                userPendingDeletion = user
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                    if viewModel.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task { await viewModel.loadMore() }
                    }
                } header: {
                    Text("Users")
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
            ToolbarItem(placement: .automatic) {
                if viewModel.isImporting {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            showingJellyfinImport = true
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Import Jellyfin Users")
                                    Text("Pick which Jellyfin accounts to add as Seerr users.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "person.crop.circle.badge.plus")
                            }
                        }

                        Button {
                            Task { await viewModel.loadUsers() }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Refresh User List")
                                    Text("Reload the imported users from Seerr.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.isLoading)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("User Management Actions")
                }
            }
        }
        .sheet(isPresented: $showingJellyfinImport) {
            SeerrJellyfinImportSheet(apiClient: apiClient) { ids in
                Task { await viewModel.importJellyfinUsers(ids: ids) }
            }
        }
        .confirmationDialog("Delete User?", isPresented: deleteDialogPresented) {
            if let user = userPendingDeletion {
                Button("Delete \(user.displayName)", role: .destructive) {
                    Task { await viewModel.deleteUser(user) }
                    userPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                userPendingDeletion = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Admin Action Failed", message: message)
            viewModel.clearError()
        }
    }
}

private struct SeerrUserRow: View {
    let user: SeerrUser
    let baseURL: String

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: user.avatarURL(baseURL: baseURL)) {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if let email = user.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text("\(user.requestCount ?? 0) requests")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(SeerrPermission.permissionLevelLabel(for: user.permissions))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.blue)
                }

                if let username = user.username ?? user.jellyfinUsername, !username.isEmpty {
                    Text(username)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension SeerrUserManagementView {
    var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { userPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    userPendingDeletion = nil
                }
            }
        )
    }

    var deleteMessage: String {
        guard let userPendingDeletion else { return "This removes the selected user from Seerr." }
        return "This removes \(userPendingDeletion.displayName) from Seerr."
    }
}

private struct SeerrUserSubtitleModifier: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        if let subtitle {
            #if os(iOS) || os(macOS)
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack {
                        Text("User Management").font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            #else
            content
            #endif
        } else {
            content
        }
    }
}
