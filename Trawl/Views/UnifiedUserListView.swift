import SwiftUI

struct UnifiedUserListView: View {
    let jellyfinClient: JellyfinAPIClient
    let seerrClient: SeerrAPIClient?
    let seerrBaseURL: String?

    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(UnifiedUserBrowserState.self) private var sharedBrowser: UnifiedUserBrowserState?
    @State private var localBrowser = UnifiedUserBrowserState()
    private var browser: UnifiedUserBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var viewModel: UnifiedUserViewModel? { browser.viewModel }
    @State private var showingAddUser = false
    @State private var showingJellyfinImport = false
    @State private var pendingDeletion: PendingUserDeletion?

    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var seerrClientID: ObjectIdentifier? {
        seerrClient.map(ObjectIdentifier.init)
    }

    var body: some View {
        Group {
            if let viewModel {
                // Two panes at regular width. A user is read across two services at
                // once - what Jellyfin allows them and what Seerr lets them request -
                // and a layout that replaces the list with one account turns every
                // comparison between two accounts into a round trip.
                TrawlListDetailPanes(title: "Users") {
                    content(viewModel: viewModel)
                } detail: {
                    selectedUserDetail(viewModel: viewModel)
                }
            } else if sidebarColumn == .detail {
                listDetailPlaceholder("Select a User", systemImage: "person.2")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: seerrClientID) {
            // The detail column reads the list column's model rather than fetching
            // the same accounts a second time.
            guard sidebarColumn != .detail else { return }
            if browser.viewModel == nil || browser.viewModelSeerrClientID != seerrClientID {
                browser.viewModel = UnifiedUserViewModel(
                    jellyfinClient: jellyfinClient,
                    seerrClient: seerrClient
                )
                browser.viewModelSeerrClientID = seerrClientID
                await browser.viewModel?.load()
            } else {
                await browser.viewModel?.loadIfNeeded()
            }
        }
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func userRow(
        _ user: UnifiedUserViewModel.UnifiedUser,
        viewModel: UnifiedUserViewModel
    ) -> some View {
        if showsDetailPane {
            UnifiedUserRowView(user: user, seerrBaseURL: seerrBaseURL)
                .tag(user.id)
        } else {
            NavigationLink {
                userDetail(user, viewModel: viewModel)
            } label: {
                UnifiedUserRowView(user: user, seerrBaseURL: seerrBaseURL)
            }
        }
    }

    /// The right-hand pane: whichever user is selected.
    ///
    /// Looked up by id rather than captured, so an account edited in the pane
    /// repaints from the reloaded list instead of showing the state it had when the
    /// row was clicked.
    @ViewBuilder
    private func selectedUserDetail(viewModel: UnifiedUserViewModel) -> some View {
        if let id = browser.selectedUserID,
           let user = viewModel.users.first(where: { $0.id == id }) {
            userDetail(user, viewModel: viewModel)
                .id(user.id)
        } else {
            listDetailPlaceholder("Select a User", systemImage: "person.2")
        }
    }

    /// The same detail the row pushes without a pane, given the same actions, so an
    /// account edited either way goes through one path.
    private func userDetail(
        _ user: UnifiedUserViewModel.UnifiedUser,
        viewModel: UnifiedUserViewModel
    ) -> some View {
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
    }

    private func content(viewModel: UnifiedUserViewModel) -> some View {
        @Bindable var browser = self.browser
        return List(selection: $browser.selectedUserID) {
            if viewModel.isLoading && viewModel.users.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if viewModel.users.isEmpty && viewModel.jellyfinLoadError == nil && viewModel.seerrLoadError == nil {
                ContentUnavailableView(
                    "No Users",
                    systemImage: "person.2.slash",
                    description: Text("No user accounts were found.")
                )
                .listRowBackground(Color.clear)
            } else {
                if let error = viewModel.jellyfinLoadError {
                    ServiceErrorView(
                        title: "Jellyfin Users Unavailable",
                        message: error,
                        identity: .jellyfin,
                        hasContent: !viewModel.users.isEmpty,
                        onRetry: { await viewModel.load() }
                    )
                }

                if let error = viewModel.seerrLoadError {
                    ServiceErrorView(
                        title: "Seerr Users Unavailable",
                        message: error,
                        identity: .seerr,
                        hasContent: !viewModel.users.isEmpty,
                        onRetry: { await viewModel.load() }
                    )
                }

                if !viewModel.users.isEmpty {
                    Section {
                        ForEach(viewModel.users) { user in
                            userRow(user, viewModel: viewModel)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let seerr = user.seerrUser, seerrClient != nil {
                                        Button(role: .destructive) {
                                            pendingDeletion = .seerr(seerr)
                                        } label: {
                                            Label("Remove from Seerr", systemImage: "person.badge.minus")
                                        }
                                    }
                                    if let jf = user.jellyfinUser, !user.isInSeerr {
                                        Button(role: .destructive) {
                                            pendingDeletion = .jellyfin(jf)
                                        } label: {
                                            Label("Delete from Jellyfin", systemImage: "trash")
                                        }
                                    }
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
        .alert(
            pendingDeletion?.title ?? "Delete User?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { deletion in
            Button("Cancel", role: .cancel) {}
            Button(deletion.confirmationTitle, role: .destructive) {
                Task { await confirmDeletion(deletion, viewModel: viewModel) }
            }
        } message: { deletion in
            Text(deletion.message)
        }
        .moreDestinationBackground(.userManagement)
    }

    private func confirmDeletion(
        _ deletion: PendingUserDeletion,
        viewModel: UnifiedUserViewModel
    ) async {
        pendingDeletion = nil

        do {
            switch deletion {
            case .seerr(let user):
                guard let seerrClient else { return }
                try await seerrClient.deleteUser(id: user.id)
                viewModel.removeSeerrUser(user)
            case .jellyfin(let user):
                try await jellyfinClient.deleteUser(id: user.id)
                viewModel.removeJellyfinUser(user)
            }
        } catch {
            inAppNotificationCenter.showError(
                title: deletion.failureTitle,
                message: error.localizedDescription,
                source: .inApp
            )
        }
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

private enum PendingUserDeletion: Identifiable {
    case seerr(SeerrUser)
    case jellyfin(JellyfinUser)

    var id: String {
        switch self {
        case .seerr(let user):
            "seerr-\(user.id)"
        case .jellyfin(let user):
            "jellyfin-\(user.id)"
        }
    }

    var title: String {
        switch self {
        case .seerr:
            "Remove Seerr User?"
        case .jellyfin:
            "Delete Jellyfin User?"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .seerr:
            "Remove"
        case .jellyfin:
            "Delete"
        }
    }

    var message: String {
        switch self {
        case .seerr(let user):
            "This removes \(user.displayName) from Seerr."
        case .jellyfin(let user):
            "This permanently deletes \(user.name) from Jellyfin."
        }
    }

    var failureTitle: String {
        switch self {
        case .seerr:
            "Remove Failed"
        case .jellyfin:
            "Delete Failed"
        }
    }
}

#if DEBUG
extension UnifiedUserListView {
    init(
        previewUsers: [UnifiedUserViewModel.UnifiedUser],
        isLoading: Bool = false,
        jellyfinLoadError: String? = nil,
        seerrLoadError: String? = nil,
        jellyfinClient: JellyfinAPIClient = .preview(),
        seerrClient: SeerrAPIClient? = .preview(),
        seerrBaseURL: String? = "http://seerr.preview"
    ) {
        self.jellyfinClient = jellyfinClient
        self.seerrClient = seerrClient
        self.seerrBaseURL = seerrBaseURL
        let browser = UnifiedUserBrowserState()
        browser.viewModel = UnifiedUserViewModel(
            jellyfinClient: jellyfinClient,
            seerrClient: seerrClient,
            users: previewUsers,
            isLoading: isLoading,
            jellyfinLoadError: jellyfinLoadError,
            seerrLoadError: seerrLoadError
        )
        browser.viewModelSeerrClientID = seerrClient.map(ObjectIdentifier.init)
        self._localBrowser = State(initialValue: browser)
    }
}

#Preview("Users - Linked Services") {
    PreviewHost(profiles: .allServices) {
        NavigationStack {
            UnifiedUserListView(previewUsers: UnifiedUserViewModel.UnifiedUser.previewList)
        }
    }
}

#Preview("Users - Jellyfin Only") {
    PreviewHost(profiles: .jellyfinOnly, seerr: .preview(.notConfigured)) {
        NavigationStack {
            UnifiedUserListView(
                previewUsers: [.previewJellyfinOnly, .previewDisabledJellyfin],
                seerrClient: nil,
                seerrBaseURL: nil
            )
        }
    }
}

#Preview("Users - Loading") {
    PreviewHost(profiles: .allServices) {
        NavigationStack {
            UnifiedUserListView(previewUsers: [], isLoading: true)
        }
    }
}

#Preview("Users - Partial Error") {
    PreviewHost(profiles: .allServices) {
        NavigationStack {
            UnifiedUserListView(
                previewUsers: [.previewLinked, .previewSeerrOnly],
                seerrLoadError: "Seerr returned a gateway timeout."
            )
        }
    }
}
#endif

private struct UnifiedAddUserSheet: View {
    let create: (String, String?) async throws -> JellyfinUser
    let onImportToSeerr: (JellyfinUser) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var name = ""
    @State private var password = ""
    @State private var isCreating = false
    @State private var isSyncingToSeerr = false
    @State private var errorMessage: String?
    @State private var createdUser: JellyfinUser?
    @State private var showSyncAlert = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AppSheetShell(
            title: "Add User",
            confirmTitle: "Add",
            isConfirmDisabled: trimmedName.isEmpty || createdUser != nil,
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

                if let createdUser {
                    Section("Jellyfin") {
                        Label("\(createdUser.name) was added to Jellyfin.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)

                        if seerrServiceManager.isConnected {
                            Button {
                                Task { await syncToSeerr() }
                            } label: {
                                HStack {
                                    if isSyncingToSeerr {
                                        ProgressView()
                                    }
                                    Text("Sync to Seerr")
                                }
                            }
                            .disabled(isSyncingToSeerr)
                        }
                    }
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
        guard let user = createdUser, !isSyncingToSeerr else { return }
        isSyncingToSeerr = true
        errorMessage = nil
        do {
            try await onImportToSeerr(user)
            dismiss()
        } catch {
            errorMessage = "Seerr sync failed: \(error.localizedDescription)"
            inAppNotificationCenter.showError(
                title: "Sync Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
        isSyncingToSeerr = false
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
