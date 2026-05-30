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

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                avatarView

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.headline)

                    HStack(spacing: 6) {
                        if let jf = jellyfinUser {
                            if jf.isAdministrator {
                                statusChip("Admin", color: .indigo)
                            }
                            if jf.isDisabled {
                                statusChip("Disabled", color: .red)
                            }
                        }
                        if let seerr = seerrUser {
                            statusChip(seerr.permissionLevelLabel, color: ServiceIdentity.seerr.brandColor)
                            if let count = seerr.requestCount, count > 0 {
                                Text("\(count) \(count == 1 ? "request" : "requests")")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var jellyfinSection: some View {
        Section {
            if let jf = jellyfinUser {
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
                    jellyfinUserRow(jf)
                }
            } else {
                HStack {
                    Image(systemName: ServiceIdentity.jellyfin.tabSystemImage)
                        .foregroundStyle(.secondary)
                    Text("Not in Jellyfin")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: ServiceIdentity.jellyfin.systemImage)
                Text("Jellyfin")
            }
        }
    }

    @ViewBuilder
    private var seerrSection: some View {
        Section {
            if let seerr = seerrUser, let client = seerrClient {
                NavigationLink {
                    SeerrUserEditorView(user: seerr, apiClient: client) { updated in
                        seerrUser = updated
                        onSeerrUserUpdated(updated)
                    }
                } label: {
                    seerrUserRow(seerr)
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
                Label("Seerr not configured", systemImage: ServiceIdentity.seerr.tabSystemImage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: ServiceIdentity.seerr.systemImage)
                Text("Seerr")
            }
        }
    }

    @ViewBuilder
    private func jellyfinUserRow(_ user: JellyfinUser) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edit Jellyfin Account")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                if user.isAdministrator {
                    badgeText("Admin", color: .indigo)
                }
                if user.isDisabled {
                    badgeText("Disabled", color: .red)
                }
                if user.isHidden {
                    badgeText("Hidden", color: .secondary)
                }
                if let lastActivity = user.lastActivityDate, !lastActivity.isEmpty {
                    Text(relativeDate(from: lastActivity))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func seerrUserRow(_ user: SeerrUser) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edit Seerr Account")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                badgeText(user.permissionLevelLabel, color: ServiceIdentity.seerr.brandColor)
                if let count = user.requestCount {
                    Text("\(count) \(count == 1 ? "request" : "requests")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        let url = seerrUser?.avatarURL(baseURL: seerrBaseURL)
        ArrArtworkView(url: url) {
            Circle()
                .fill(avatarColor.opacity(0.15))
                .overlay {
                    Image(systemName: jellyfinUser?.isAdministrator == true ? "person.badge.key.fill" : "person.fill")
                        .font(.title3)
                        .foregroundStyle(avatarColor)
                }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
    }

    private var avatarColor: Color {
        if jellyfinUser?.isAdministrator == true { return .indigo }
        if jellyfinUser != nil { return .blue }
        return .secondary
    }

    private func statusChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func badgeText(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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
