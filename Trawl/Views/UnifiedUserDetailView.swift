import SwiftUI

struct UnifiedUserDetailView: View {
    let jellyfinClient: JellyfinAPIClient
    let seerrClient: SeerrAPIClient?
    let seerrBaseURL: String?
    let onJellyfinUserUpdated: (JellyfinUser) -> Void
    let onSeerrUserUpdated: (SeerrUser) -> Void
    let onSeerrUserDeleted: () -> Void
    let onJellyfinUserDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var jellyfinUser: JellyfinUser?
    @State private var seerrUser: SeerrUser?
    @State private var isImportingToSeerr = false
    @State private var importAlert: ImportAlert?
    @State private var showDeleteSeerrConfirmation = false

    init(
        user: UnifiedUserViewModel.UnifiedUser,
        jellyfinClient: JellyfinAPIClient,
        seerrClient: SeerrAPIClient?,
        seerrBaseURL: String?,
        onJellyfinUserUpdated: @escaping (JellyfinUser) -> Void,
        onSeerrUserUpdated: @escaping (SeerrUser) -> Void,
        onSeerrUserDeleted: @escaping () -> Void,
        onJellyfinUserDeleted: @escaping () -> Void
    ) {
        self.jellyfinClient = jellyfinClient
        self.seerrClient = seerrClient
        self.seerrBaseURL = seerrBaseURL
        self.onJellyfinUserUpdated = onJellyfinUserUpdated
        self.onSeerrUserUpdated = onSeerrUserUpdated
        self.onSeerrUserDeleted = onSeerrUserDeleted
        self.onJellyfinUserDeleted = onJellyfinUserDeleted
        self._jellyfinUser = State(initialValue: user.jellyfinUser)
        self._seerrUser = State(initialValue: user.seerrUser)
    }

    private var displayName: String {
        jellyfinUser?.name ?? seerrUser?.displayName ?? "Unknown"
    }

    var body: some View {
        List {
            headerSection

            jellyfinSection

            seerrSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .navigationTitle(displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Remove Seerr User?", isPresented: $showDeleteSeerrConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await deleteSeerrUser() }
            }
        } message: {
            Text("This removes \(displayName) from Seerr.")
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// Opens with the person, not with a field. In a detail pane this is also the
    /// only thing that names them: macOS draws one title for the whole window and
    /// the list column beside this one has already claimed it for "Users".
    @ViewBuilder
    private var headerSection: some View {
        Section {
            TrawlEntityHeader(
                title: displayName,
                subtitle: membershipSummary,
                systemImage: jellyfinUser?.isAdministrator == true
                    ? "person.badge.key.fill"
                    : "person.fill",
                tint: avatarColor,
                artworkURL: seerrUser?.avatarURL(baseURL: seerrBaseURL),
                shape: .circle,
                badges: headerBadges
            )
        }
        .listRowBackground(Color.clear)
    }

    /// Which of the two services this account exists on. The pair is the point of
    /// this screen - an account that is in Jellyfin but not Seerr cannot request
    /// anything, and that is worth saying before any field is read.
    private var membershipSummary: String {
        switch (jellyfinUser != nil, seerrUser != nil) {
        case (true, true): "Jellyfin · Seerr"
        case (true, false): "Jellyfin only"
        case (false, true): "Seerr only"
        case (false, false): "No linked accounts"
        }
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        if let jf = jellyfinUser {
            if jf.isAdministrator {
                badges.append(ArrDetailBadge(icon: "key.fill", label: "Administrator", color: .indigo))
            }
            if jf.isDisabled {
                badges.append(ArrDetailBadge(icon: "nosign", label: "Disabled", color: .red))
            }
            if jf.isHidden {
                badges.append(ArrDetailBadge(icon: "eye.slash", label: "Hidden", color: .secondary))
            }
        }
        if let seerr = seerrUser {
            badges.append(ArrDetailBadge(
                icon: "person.badge.shield.checkmark",
                label: seerr.permissionLevelLabel,
                color: ServiceIdentity.seerr.brandColor
            ))
            if let count = seerr.requestCount, count > 0 {
                badges.append(ArrDetailBadge(
                    icon: "square.and.arrow.down",
                    label: "\(count) \(count == 1 ? "request" : "requests")",
                    color: .teal
                ))
            }
        }
        return badges
    }

    /// What the account *is* on Jellyfin, then the way to change it.
    ///
    /// This screen used to answer "what can this person do?" with a single row
    /// labelled "Edit Jellyfin Account" - the answer was only reachable by opening
    /// the editor, which is the wrong way round for a pane you are looking at
    /// precisely because you wanted to know.
    @ViewBuilder
    private var jellyfinSection: some View {
        Section {
            if let jf = jellyfinUser {
                LabeledContent("Username", value: jf.name)

                LabeledContent("Role") {
                    Text(jf.isAdministrator ? "Administrator" : "User")
                        .foregroundStyle(jf.isAdministrator ? .indigo : .secondary)
                }

                LabeledContent("Status") {
                    Text(jellyfinStatusLabel(jf))
                        .foregroundStyle(jf.isDisabled ? .red : .secondary)
                }

                LabeledContent("Password") {
                    Text(jf.hasConfiguredPassword == true ? "Set" : "Not set")
                        .foregroundStyle(.secondary)
                }

                if let access = libraryAccessLabel(jf) {
                    LabeledContent("Library Access") {
                        Text(access)
                            .foregroundStyle(.secondary)
                    }
                }

                if jf.policy?.enableRemoteAccess != nil {
                    LabeledContent("Remote Access") {
                        Text(jf.policy?.enableRemoteAccess == true ? "Allowed" : "Blocked")
                            .foregroundStyle(jf.policy?.enableRemoteAccess == true ? Color.secondary : .orange)
                    }
                }

                if let lastActivity = jf.lastActivityDate, !lastActivity.isEmpty {
                    LabeledContent("Last Active") {
                        Text(relativeDate(from: lastActivity))
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastLogin = jf.lastLoginDate, !lastLogin.isEmpty {
                    LabeledContent("Last Sign-In") {
                        Text(relativeDate(from: lastLogin))
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    JellyfinUserEditorView(
                        user: jf,
                        apiClient: jellyfinClient
                    ) { updated in
                        jellyfinUser = updated
                        onJellyfinUserUpdated(updated)
                    } onDelete: {
                        jellyfinUser = nil
                        onJellyfinUserDeleted()
                    }
                    .environment(inAppNotificationCenter)
                } label: {
                    Label("Edit Jellyfin Account", systemImage: "pencil")
                }
            } else {
                Label("Not in Jellyfin", systemImage: ServiceIdentity.jellyfin.tabSystemImage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: ServiceIdentity.jellyfin.systemImage)
                Text("Jellyfin")
            }
        }
    }

    private func jellyfinStatusLabel(_ user: JellyfinUser) -> String {
        if user.isDisabled { return "Disabled" }
        if user.isHidden { return "Enabled · Hidden" }
        return "Enabled"
    }

    /// Jellyfin says either "everything" or names the folders, so the count is the
    /// only honest summary of the second case. A policy that says neither is not
    /// "no libraries" - it is a server that did not answer, and the row is dropped
    /// rather than guessed at.
    private func libraryAccessLabel(_ user: JellyfinUser) -> String? {
        guard let policy = user.policy else { return nil }
        if policy.enableAllFolders == true { return "All libraries" }
        guard let folders = policy.enabledFolders else { return nil }
        if folders.isEmpty { return "No libraries" }
        return "\(folders.count) \(folders.count == 1 ? "library" : "libraries")"
    }

    @ViewBuilder
    private var seerrSection: some View {
        Section {
            if let seerr = seerrUser, let client = seerrClient {
                LabeledContent("Display Name", value: seerr.displayName)

                if let username = seerr.username ?? seerr.jellyfinUsername, !username.isEmpty {
                    LabeledContent("Username", value: username)
                }

                if let email = seerr.email, !email.isEmpty {
                    LabeledContent("Email") {
                        Text(email)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                LabeledContent("Permissions") {
                    Text(seerr.permissionLevelLabel)
                        .foregroundStyle(ServiceIdentity.seerr.brandColor)
                }

                LabeledContent("Auto-Approve") {
                    Text(seerr.canAutoApprove ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }

                if let count = seerr.requestCount {
                    LabeledContent("Requests") {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                    }
                }

                if let created = seerr.createdAt, !created.isEmpty {
                    LabeledContent("Member Since") {
                        Text(relativeDate(from: created))
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    SeerrUserEditorView(user: seerr, apiClient: client) { updated in
                        seerrUser = updated
                        onSeerrUserUpdated(updated)
                    }
                } label: {
                    Label("Edit Seerr Account", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    showDeleteSeerrConfirmation = true
                } label: {
                    Label("Remove from Seerr", systemImage: "trash")
                }
            } else if seerrClient != nil {
                if let jf = jellyfinUser {
                    if isImportingToSeerr {
                        HStack {
                            ProgressView()
                            Text("Importing…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            Task { await importToSeerr(jellyfinUser: jf) }
                        } label: {
                            Label("Import to Seerr", systemImage: "person.crop.circle.badge.plus")
                        }
                        .tint(ServiceIdentity.seerr.brandColor)
                    }
                } else {
                    HStack {
                        Image(systemName: ServiceIdentity.seerr.tabSystemImage)
                            .foregroundStyle(.secondary)
                        Text("Not in Seerr")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Seerr Not Set Up", systemImage: ServiceIdentity.seerr.tabSystemImage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: ServiceIdentity.seerr.systemImage)
                Text("Seerr")
            }
        }
    }

    private var avatarColor: Color {
        if jellyfinUser?.isAdministrator == true { return .indigo }
        if jellyfinUser != nil { return .blue }
        return .secondary
    }

    private func relativeDate(from raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func importToSeerr(jellyfinUser: JellyfinUser) async {
        guard let client = seerrClient else { return }
        isImportingToSeerr = true
        importAlert = nil
        do {
            let imported = try await client.importUsersFromJellyfin(jellyfinUserIds: [jellyfinUser.id])
            seerrUser = imported.first
            if let importedUser = imported.first {
                onSeerrUserUpdated(importedUser)
                importAlert = ImportAlert(
                    title: "Imported to Seerr",
                    message: "\(importedUser.displayName) was added to Seerr."
                )
            } else {
                importAlert = ImportAlert(
                    title: "No User Imported",
                    message: "Seerr completed the import request, but did not return a user account."
                )
            }
        } catch {
            importAlert = ImportAlert(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
        isImportingToSeerr = false
    }

    private func deleteSeerrUser() async {
        guard let seerrUser, let client = seerrClient else { return }
        do {
            try await client.deleteUser(id: seerrUser.id)
            self.seerrUser = nil
            onSeerrUserDeleted()
            inAppNotificationCenter.showSuccess(
                title: "Seerr User Removed",
                message: "\(seerrUser.displayName) was removed from Seerr.",
                source: .inApp
            )
            if jellyfinUser == nil {
                dismiss()
            }
        } catch {
            inAppNotificationCenter.showError(
                title: "Remove Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }
}

#if DEBUG
#Preview("User Detail - Linked") {
    PreviewHost(profiles: .allServices) {
        NavigationStack {
            UnifiedUserDetailView(
                user: .previewLinkedAdmin,
                jellyfinClient: .preview(),
                seerrClient: .preview(),
                seerrBaseURL: "http://seerr.preview",
                onJellyfinUserUpdated: { _ in },
                onSeerrUserUpdated: { _ in },
                onSeerrUserDeleted: {},
                onJellyfinUserDeleted: {}
            )
        }
    }
}

#Preview("User Detail - Jellyfin Only") {
    PreviewHost(profiles: .allServices) {
        NavigationStack {
            UnifiedUserDetailView(
                user: .previewJellyfinOnly,
                jellyfinClient: .preview(),
                seerrClient: .preview(),
                seerrBaseURL: "http://seerr.preview",
                onJellyfinUserUpdated: { _ in },
                onSeerrUserUpdated: { _ in },
                onSeerrUserDeleted: {},
                onJellyfinUserDeleted: {}
            )
        }
    }
}

#Preview("User Detail - Seerr Only") {
    PreviewHost(profiles: .allServices) {
        NavigationStack {
            UnifiedUserDetailView(
                user: .previewSeerrOnly,
                jellyfinClient: .preview(),
                seerrClient: .preview(),
                seerrBaseURL: "http://seerr.preview",
                onJellyfinUserUpdated: { _ in },
                onSeerrUserUpdated: { _ in },
                onSeerrUserDeleted: {},
                onJellyfinUserDeleted: {}
            )
        }
    }
}

#Preview("User Detail - No Seerr") {
    PreviewHost(profiles: .jellyfinOnly, seerr: .preview(.notConfigured)) {
        NavigationStack {
            UnifiedUserDetailView(
                user: .previewDisabledJellyfin,
                jellyfinClient: .preview(),
                seerrClient: nil,
                seerrBaseURL: nil,
                onJellyfinUserUpdated: { _ in },
                onSeerrUserUpdated: { _ in },
                onSeerrUserDeleted: {},
                onJellyfinUserDeleted: {}
            )
        }
    }
}
#endif

private struct ImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
