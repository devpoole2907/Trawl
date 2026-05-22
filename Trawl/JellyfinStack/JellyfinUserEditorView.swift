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
    @State private var scheduleEditorSession: JellyfinAccessScheduleEditorSession?
    @State private var tagEditorContext: JellyfinTagEditorContext?
    @State private var policySelectorContext: JellyfinPolicySelectorContext?

    private enum PolicyField {
        case isAdministrator
        case isDisabled
        case isHidden
        case enableContentDeletion
        case enableMediaPlayback
        case enableAudioPlaybackTranscoding
        case enableVideoPlaybackTranscoding
        case enablePlaybackRemuxing
        case enableLiveTvAccess
        case enableLiveTvManagement
        case enableSyncTranscoding
        case enableMediaConversion
        case enableContentDownloading
        case enableCollectionManagement
        case enableSubtitleManagement
        case enableLyricManagement
        case enablePublicSharing
        case enableAllDevices
        case enableAllChannels
        case enableAllFolders
        case enableRemoteAccess
        case enableRemoteControlOfOtherUsers
        case enableSharedDeviceControl
        case enableUserPreferenceAccess
        case forceRemoteSourceTranscoding

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
        .navigationSubtitle("Jellyfin")
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
        .sheet(item: $scheduleEditorSession) { session in
            JellyfinAccessScheduleEditorSheet(session: session) { schedule, index in
                viewModel.upsertAccessSchedule(schedule, at: index)
                scheduleEditorSession = nil
            }
        }
        .sheet(item: $tagEditorContext) { context in
            JellyfinPolicyTagEditorSheet(
                context: context,
                selectedTags: tagBinding(for: context.kind),
                availableTags: knownPolicyTags(excluding: context.kind)
            )
        }
        .sheet(item: $policySelectorContext) { context in
            JellyfinPolicySelectorSheet(
                selectedIds: policyIdsBinding(for: context.kind),
                title: context.kind.title,
                selectedSectionTitle: context.kind.selectedSectionTitle,
                emptySelectedText: context.kind.emptySelectedText,
                emptyAvailableText: context.kind.emptyAvailableText,
                availableItems: policyItems(for: context.kind)
            )
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
        .task {
            await viewModel.loadParentalRatings()
            await viewModel.loadVirtualFolders()
            await viewModel.loadDevices()
            await viewModel.loadChannels()
        }
        .refreshable {
            async let ratings: Void = viewModel.loadParentalRatings()
            async let folders: Void = viewModel.loadVirtualFolders()
            async let devices: Void = viewModel.loadDevices()
            async let channels: Void = viewModel.loadChannels()
            _ = await (ratings, folders, devices, channels)
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
            policyRow("Content Downloading", value: viewModel.policy.enableContentDownloading, systemImage: "arrow.down.circle")
            policyRow("Collection Management", value: viewModel.policy.enableCollectionManagement, systemImage: "rectangle.stack")
            policyRow("Subtitle Management", value: viewModel.policy.enableSubtitleManagement, systemImage: "captions.bubble")
            policyRow("Lyric Management", value: viewModel.policy.enableLyricManagement, systemImage: "music.mic")
            policyRow("Public Sharing", value: viewModel.policy.enablePublicSharing, systemImage: "square.and.arrow.up")
            policyRow("Remote Access", value: viewModel.policy.enableRemoteAccess, systemImage: "wifi")
            policyRow("User Preferences", value: viewModel.policy.enableUserPreferenceAccess, systemImage: "slider.horizontal.3")
        }

        Section("Playback") {
            policyRow("Audio Transcoding", value: viewModel.policy.enableAudioPlaybackTranscoding, systemImage: "waveform")
            policyRow("Video Transcoding", value: viewModel.policy.enableVideoPlaybackTranscoding, systemImage: "film")
            policyRow("Playback Remuxing", value: viewModel.policy.enablePlaybackRemuxing, systemImage: "arrow.triangle.2.circlepath")
            policyRow("Sync Transcoding", value: viewModel.policy.enableSyncTranscoding, systemImage: "arrow.triangle.2.circlepath.circle")
            policyRow("Media Conversion", value: viewModel.policy.enableMediaConversion, systemImage: "wand.and.stars")
            policyRow("Force Remote Source Transcoding", value: viewModel.policy.forceRemoteSourceTranscoding, systemImage: "network")
            policyValueRow("Remote Bitrate Limit", value: bitrateText(viewModel.policy.remoteClientBitrateLimit), systemImage: "speedometer")
        }

        Section("Live TV") {
            policyRow("Live TV Access", value: viewModel.policy.enableLiveTvAccess, systemImage: "tv")
            policyRow("Live TV Management", value: viewModel.policy.enableLiveTvManagement, systemImage: "tv.badge.wifi")
        }

        Section("Library Access") {
            policyRow("All Libraries", value: viewModel.policy.enableAllFolders, systemImage: "folder")
            policyValueRow("Enabled Libraries", value: viewModel.libraryDisplayNames(for: viewModel.policy.enabledFolders), systemImage: "folder.badge.person.crop")
            policyValueRow("Blocked Libraries", value: viewModel.libraryDisplayNames(for: viewModel.policy.blockedMediaFolders), systemImage: "folder.badge.questionmark")
            policyValueRow("Deletion Libraries", value: viewModel.libraryDisplayNames(for: viewModel.policy.enableContentDeletionFromFolders), systemImage: "folder.badge.minus")
        }

        Section("Device Control") {
            policyRow("Shared Device Control", value: viewModel.policy.enableSharedDeviceControl, systemImage: "rectangle.on.rectangle")
            policyRow("Remote Control Others", value: viewModel.policy.enableRemoteControlOfOtherUsers, systemImage: "dot.radiowaves.left.and.right")
            policyRow("All Devices", value: viewModel.policy.enableAllDevices, systemImage: "macbook.and.iphone")
            policyValueRow("Enabled Devices", value: viewModel.deviceDisplayNames(for: viewModel.policy.enabledDevices), systemImage: "iphone")
            policyRow("All Channels", value: viewModel.policy.enableAllChannels, systemImage: "play.rectangle.on.rectangle")
            policyValueRow("Enabled Channels", value: viewModel.channelDisplayNames(for: viewModel.policy.enabledChannels), systemImage: "play.rectangle")
            policyValueRow("Blocked Channels", value: viewModel.channelDisplayNames(for: viewModel.policy.blockedChannels), systemImage: "play.slash")
        }

        Section("Parental Controls") {
            policyValueRow("Max Rating", value: viewModel.parentalRatingName(for: viewModel.policy.maxParentalRating), systemImage: "shield.lefthalf.filled")
            policyValueRow("Max Sub-Rating", value: optionalText(viewModel.policy.maxParentalSubRating), systemImage: "shield.righthalf.filled")
            policyValueRow("Allowed Tags", value: listText(viewModel.policy.allowedTags), systemImage: "tag")
            policyValueRow("Blocked Tags", value: listText(viewModel.policy.blockedTags), systemImage: "tag.slash")
            policyValueRow("Block Unrated", value: listText(viewModel.policy.blockUnratedItems), systemImage: "questionmark.circle")
            policyValueRow("Access Schedules", value: accessScheduleText(viewModel.policy.accessSchedules), systemImage: "calendar.badge.clock")
        }

        Section("Security") {
            policyValueRow("Max Active Sessions", value: optionalText(viewModel.policy.maxActiveSessions), systemImage: "person.2")
            policyValueRow("Lockout Attempts", value: optionalText(viewModel.policy.loginAttemptsBeforeLockout), systemImage: "lock")
            policyValueRow("Invalid Login Attempts", value: optionalText(viewModel.policy.invalidLoginAttemptCount), systemImage: "exclamationmark.lock")
            policyValueRow("SyncPlay Access", value: viewModel.policy.syncPlayAccess, systemImage: "person.2.wave.2")
            policyValueRow("Auth Provider", value: viewModel.policy.authenticationProviderId, systemImage: "key.horizontal")
            policyValueRow("Password Reset Provider", value: viewModel.policy.passwordResetProviderId, systemImage: "key.viewfinder")
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
            policyToggle("Remote Access", field: .enableRemoteAccess, binding: viewModel.policyBinding(\.enableRemoteAccess), systemImage: "wifi")
            policyToggle("User Preferences", field: .enableUserPreferenceAccess, binding: viewModel.policyBinding(\.enableUserPreferenceAccess), systemImage: "slider.horizontal.3")
        }

        Section("Permissions") {
            policyToggle("Content Deletion", field: .enableContentDeletion, binding: viewModel.policyBinding(\.enableContentDeletion), systemImage: "trash")
            policyToggle("Content Downloading", field: .enableContentDownloading, binding: viewModel.policyBinding(\.enableContentDownloading), systemImage: "arrow.down.circle")
            policyToggle("Collection Management", field: .enableCollectionManagement, binding: viewModel.policyBinding(\.enableCollectionManagement), systemImage: "rectangle.stack")
            policyToggle("Subtitle Management", field: .enableSubtitleManagement, binding: viewModel.policyBinding(\.enableSubtitleManagement), systemImage: "captions.bubble")
            policyToggle("Lyric Management", field: .enableLyricManagement, binding: viewModel.policyBinding(\.enableLyricManagement), systemImage: "music.mic")
            policyToggle("Public Sharing", field: .enablePublicSharing, binding: viewModel.policyBinding(\.enablePublicSharing), systemImage: "square.and.arrow.up")
            policyToggle("Media Playback", field: .enableMediaPlayback, binding: viewModel.policyBinding(\.enableMediaPlayback), systemImage: "play.circle")
        }

        Section("Playback") {
            policyToggle("Audio Transcoding", field: .enableAudioPlaybackTranscoding, binding: viewModel.policyBinding(\.enableAudioPlaybackTranscoding), systemImage: "waveform")
            policyToggle("Video Transcoding", field: .enableVideoPlaybackTranscoding, binding: viewModel.policyBinding(\.enableVideoPlaybackTranscoding), systemImage: "film")
            policyToggle("Playback Remuxing", field: .enablePlaybackRemuxing, binding: viewModel.policyBinding(\.enablePlaybackRemuxing), systemImage: "arrow.triangle.2.circlepath")
            policyToggle("Sync Transcoding", field: .enableSyncTranscoding, binding: viewModel.policyBinding(\.enableSyncTranscoding), systemImage: "arrow.triangle.2.circlepath.circle")
            policyToggle("Media Conversion", field: .enableMediaConversion, binding: viewModel.policyBinding(\.enableMediaConversion), systemImage: "wand.and.stars")
            policyToggle("Force Remote Source Transcoding", field: .forceRemoteSourceTranscoding, binding: viewModel.policyBinding(\.forceRemoteSourceTranscoding), systemImage: "network")
            policyTextField("Remote Bitrate Limit", text: viewModel.policyIntegerBinding(\.remoteClientBitrateLimit), systemImage: "speedometer", prompt: "Kbps")
        }

        Section("Live TV") {
            policyToggle("Live TV Access", field: .enableLiveTvAccess, binding: viewModel.policyBinding(\.enableLiveTvAccess), systemImage: "tv")
            policyToggle("Live TV Management", field: .enableLiveTvManagement, binding: viewModel.policyBinding(\.enableLiveTvManagement), systemImage: "tv.badge.wifi")
        }

        Section("Library Access") {
            policyToggle("All Libraries", field: .enableAllFolders, binding: viewModel.policyBinding(\.enableAllFolders), systemImage: "folder")
            policyNavigationRow("Enabled Libraries", count: viewModel.policy.enabledFolders?.count ?? 0, systemImage: "folder.badge.person.crop") {
                withAnimation { policySelectorContext = .init(kind: .enabledLibraries) }
            }
            .disabled(viewModel.policy.isAdministrator == true || viewModel.policy.enableAllFolders == true)
            policyNavigationRow("Blocked Libraries", count: viewModel.policy.blockedMediaFolders?.count ?? 0, systemImage: "folder.badge.questionmark") {
                withAnimation { policySelectorContext = .init(kind: .blockedLibraries) }
            }
            .disabled(viewModel.policy.isAdministrator == true || viewModel.policy.enableAllFolders == true)
            policyNavigationRow("Deletion Libraries", count: viewModel.policy.enableContentDeletionFromFolders?.count ?? 0, systemImage: "folder.badge.minus") {
                withAnimation { policySelectorContext = .init(kind: .deletionLibraries) }
            }
            .disabled(viewModel.policy.isAdministrator == true)
        }

        Section("Device Control") {
            policyToggle("Shared Device Control", field: .enableSharedDeviceControl, binding: viewModel.policyBinding(\.enableSharedDeviceControl), systemImage: "rectangle.on.rectangle")
            policyToggle("Remote Control Others", field: .enableRemoteControlOfOtherUsers, binding: viewModel.policyBinding(\.enableRemoteControlOfOtherUsers), systemImage: "dot.radiowaves.left.and.right")
            policyToggle("All Devices", field: .enableAllDevices, binding: viewModel.policyBinding(\.enableAllDevices), systemImage: "macbook.and.iphone")
            policyNavigationRow("Enabled Devices", count: viewModel.policy.enabledDevices?.count ?? 0, systemImage: "iphone") {
                withAnimation { policySelectorContext = .init(kind: .enabledDevices) }
            }
            .disabled(viewModel.policy.isAdministrator == true || viewModel.policy.enableAllDevices == true)
            policyToggle("All Channels", field: .enableAllChannels, binding: viewModel.policyBinding(\.enableAllChannels), systemImage: "play.rectangle.on.rectangle")
            policyNavigationRow("Enabled Channels", count: viewModel.policy.enabledChannels?.count ?? 0, systemImage: "play.rectangle") {
                withAnimation { policySelectorContext = .init(kind: .enabledChannels) }
            }
            .disabled(viewModel.policy.isAdministrator == true || viewModel.policy.enableAllChannels == true)
            policyNavigationRow("Blocked Channels", count: viewModel.policy.blockedChannels?.count ?? 0, systemImage: "play.slash") {
                withAnimation { policySelectorContext = .init(kind: .blockedChannels) }
            }
            .disabled(viewModel.policy.isAdministrator == true || viewModel.policy.enableAllChannels == true)
        }

        Section("Parental Controls") {
            parentalRatingPickerRow
            policyTextField("Max Sub-Rating", text: viewModel.policyIntegerBinding(\.maxParentalSubRating), systemImage: "shield.righthalf.filled", prompt: "Numeric score")
            policyNavigationRow("Allowed Tags", count: viewModel.policy.allowedTags?.count ?? 0, systemImage: "tag") {
                tagEditorContext = .init(kind: .allowed)
            }
            .disabled(viewModel.policy.isAdministrator == true)
            policyNavigationRow("Blocked Tags", count: viewModel.policy.blockedTags?.count ?? 0, systemImage: "tag.slash") {
                tagEditorContext = .init(kind: .blocked)
            }
            .disabled(viewModel.policy.isAdministrator == true)
            policyTextField("Block Unrated", text: viewModel.policyStringListBinding(\.blockUnratedItems), systemImage: "questionmark.circle", prompt: "Types")
            accessScheduleEditorRows
        }

        Section("Security") {
            policyTextField("Max Active Sessions", text: viewModel.policyIntegerBinding(\.maxActiveSessions), systemImage: "person.2", prompt: "Sessions")
            policyTextField("Lockout Attempts", text: viewModel.policyIntegerBinding(\.loginAttemptsBeforeLockout), systemImage: "lock", prompt: "Attempts")
            policyValueRow("Invalid Login Attempts", value: optionalText(viewModel.policy.invalidLoginAttemptCount), systemImage: "exclamationmark.lock")
            policyTextField("SyncPlay Access", text: viewModel.policyStringBinding(\.syncPlayAccess), systemImage: "person.2.wave.2", prompt: "Access")
            policyTextField("Auth Provider", text: viewModel.policyStringBinding(\.authenticationProviderId), systemImage: "key.horizontal", prompt: "Provider ID")
            policyTextField("Password Reset Provider", text: viewModel.policyStringBinding(\.passwordResetProviderId), systemImage: "key.viewfinder", prompt: "Provider ID")
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

    @ViewBuilder
    private func policyValueRow(_ label: String, value: String?, systemImage: String) -> some View {
        LabeledContent {
            Text(value?.nilIfEmpty ?? "None")
                .foregroundStyle(value?.nilIfEmpty == nil ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    private func policyTextField(_ label: String, text: Binding<String>, systemImage: String, prompt: String) -> some View {
        LabeledContent {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
        } label: {
            Label(label, systemImage: systemImage)
        }
        .disabled(viewModel.policy.isAdministrator == true)
    }

    @ViewBuilder
    private var parentalRatingPickerRow: some View {
        if viewModel.parentalRatings.isEmpty {
            policyTextField(
                "Max Rating",
                text: viewModel.policyIntegerBinding(\.maxParentalRating),
                systemImage: "shield.lefthalf.filled",
                prompt: "Numeric score"
            )
        } else {
            LabeledContent {
                Picker("Max Rating", selection: viewModel.policyOptionalIntBinding(\.maxParentalRating)) {
                    Text("None").tag(Int?.none)
                    ForEach(viewModel.parentalRatings.filter { $0.score != nil }) { rating in
                        Text(rating.displayName).tag(Int?.some(rating.score!))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } label: {
                Label("Max Rating", systemImage: "shield.lefthalf.filled")
            }
            .disabled(viewModel.policy.isAdministrator == true)
        }
    }

    private func policyNavigationRow(_ label: String, count: Int, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                Text(count == 0 ? "None" : "\(count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var accessScheduleEditorRows: some View {
        let schedules = viewModel.policy.accessSchedules ?? []

        if schedules.isEmpty {
            policyValueRow("Access Schedules", value: nil, systemImage: "calendar.badge.clock")
        } else {
            ForEach(Array(schedules.enumerated()), id: \.offset) { index, schedule in
                Button {
                    scheduleEditorSession = .edit(schedule, at: index)
                } label: {
                    HStack {
                        Label("Access Schedule", systemImage: "calendar.badge.clock")
                        Spacer()
                        Text(accessScheduleText(schedule))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.removeAccessSchedule(at: index)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(viewModel.policy.isAdministrator == true)
                }
                .disabled(viewModel.policy.isAdministrator == true)
            }
        }

        Button {
            scheduleEditorSession = .add()
        } label: {
            Label("Add Schedule", systemImage: "plus")
        }
        .disabled(viewModel.policy.isAdministrator == true)
    }

    private func listText(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }

    private func optionalText(_ value: Int?) -> String? {
        value.map(String.init)
    }

    private func bitrateText(_ value: Int?) -> String? {
        guard let value else { return nil }
        return value == 0 ? "Unlimited" : "\(value) Kbps"
    }

    private func accessScheduleText(_ schedules: [JellyfinAccessSchedule]?) -> String? {
        guard let schedules, !schedules.isEmpty else { return nil }
        return schedules.map(accessScheduleText).joined(separator: ", ")
    }

    private func accessScheduleText(_ schedule: JellyfinAccessSchedule) -> String {
        let day = schedule.dayOfWeek ?? "Any"
        let start = schedule.startHour.map(formatHour) ?? "?"
        let end = schedule.endHour.map(formatHour) ?? "?"
        return "\(day) \(start)-\(end)"
    }

    private func formatHour(_ hour: Double) -> String {
        let hours = Int(hour)
        let minutes = Int((hour - Double(hours)) * 60)
        return String(format: "%02d:%02d", hours, minutes)
    }

    private func tagBinding(for kind: JellyfinPolicyTagEditorKind) -> Binding<[String]> {
        switch kind {
        case .allowed:
            Binding(
                get: { viewModel.policy.allowedTags ?? [] },
                set: { viewModel.policy.allowedTags = $0.normalizedTags.nilIfEmpty }
            )
        case .blocked:
            Binding(
                get: { viewModel.policy.blockedTags ?? [] },
                set: { viewModel.policy.blockedTags = $0.normalizedTags.nilIfEmpty }
            )
        }
    }

    private func knownPolicyTags(excluding kind: JellyfinPolicyTagEditorKind) -> [String] {
        var tags: [String] = []
        switch kind {
        case .allowed:
            tags.append(contentsOf: viewModel.policy.blockedTags ?? [])
        case .blocked:
            tags.append(contentsOf: viewModel.policy.allowedTags ?? [])
        }
        return tags.normalizedTags
    }

    private func policyIdsBinding(for kind: JellyfinPolicySelectorKind) -> Binding<[String]> {
        switch kind {
        case .enabledLibraries:
            Binding(get: { viewModel.policy.enabledFolders ?? [] }, set: { viewModel.policy.enabledFolders = $0.nilIfEmpty })
        case .blockedLibraries:
            Binding(get: { viewModel.policy.blockedMediaFolders ?? [] }, set: { viewModel.policy.blockedMediaFolders = $0.nilIfEmpty })
        case .deletionLibraries:
            Binding(get: { viewModel.policy.enableContentDeletionFromFolders ?? [] }, set: { viewModel.policy.enableContentDeletionFromFolders = $0.nilIfEmpty })
        case .enabledDevices:
            Binding(get: { viewModel.policy.enabledDevices ?? [] }, set: { viewModel.policy.enabledDevices = $0.nilIfEmpty })
        case .enabledChannels:
            Binding(get: { viewModel.policy.enabledChannels ?? [] }, set: { viewModel.policy.enabledChannels = $0.nilIfEmpty })
        case .blockedChannels:
            Binding(get: { viewModel.policy.blockedChannels ?? [] }, set: { viewModel.policy.blockedChannels = $0.nilIfEmpty })
        }
    }

    private func policyItems(for kind: JellyfinPolicySelectorKind) -> [JellyfinPolicySelectorItem] {
        switch kind {
        case .enabledLibraries, .blockedLibraries, .deletionLibraries:
            viewModel.virtualFolders.map { JellyfinPolicySelectorItem(id: $0.itemId, name: $0.name, icon: $0.collectionIcon) }
        case .enabledDevices:
            viewModel.devices.map { JellyfinPolicySelectorItem(id: $0.id, name: $0.displayName, icon: "desktopcomputer") }
        case .enabledChannels, .blockedChannels:
            viewModel.channels.map { JellyfinPolicySelectorItem(id: $0.id, name: $0.name ?? $0.id, icon: "play.rectangle") }
        }
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

private struct JellyfinAccessScheduleEditorSession: Identifiable {
    let id = UUID()
    let index: Int?
    let schedule: JellyfinAccessSchedule

    static func add() -> JellyfinAccessScheduleEditorSession {
        JellyfinAccessScheduleEditorSession(
            index: nil,
            schedule: JellyfinAccessSchedule(
                dayOfWeek: JellyfinAccessScheduleDay.monday.rawValue,
                startHour: 0,
                endHour: 24
            )
        )
    }

    static func edit(_ schedule: JellyfinAccessSchedule, at index: Int) -> JellyfinAccessScheduleEditorSession {
        JellyfinAccessScheduleEditorSession(index: index, schedule: schedule)
    }
}

private struct JellyfinAccessScheduleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let session: JellyfinAccessScheduleEditorSession
    let onSave: (JellyfinAccessSchedule, Int?) -> Void

    @State private var selectedDay: JellyfinAccessScheduleDay
    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int

    private var startDecimalHour: Double {
        Double(startHour) + Double(startMinute) / 60
    }

    private var endDecimalHour: Double {
        Double(endHour) + Double(endMinute) / 60
    }

    private var canSave: Bool {
        startDecimalHour < endDecimalHour
    }

    private var title: String {
        session.index == nil ? "Add Schedule" : "Edit Schedule"
    }

    init(
        session: JellyfinAccessScheduleEditorSession,
        onSave: @escaping (JellyfinAccessSchedule, Int?) -> Void
    ) {
        self.session = session
        self.onSave = onSave

        let schedule = session.schedule
        let day = JellyfinAccessScheduleDay(rawValue: schedule.dayOfWeek ?? "") ?? .monday
        let startComponents = Self.timeComponents(from: schedule.startHour ?? 0)
        let endComponents = Self.timeComponents(from: schedule.endHour ?? 24)

        self._selectedDay = State(initialValue: day)
        self._startHour = State(initialValue: startComponents.hour)
        self._startMinute = State(initialValue: startComponents.minute)
        self._endHour = State(initialValue: endComponents.hour)
        self._endMinute = State(initialValue: endComponents.minute)
    }

    var body: some View {
        AppSheetShell(
            title: title,
            confirmTitle: "Save",
            isConfirmDisabled: !canSave,
            onConfirm: save
        ) {
            Form {
                Section {
                    LabeledContent("Day") {
                        Picker("Day", selection: $selectedDay) {
                            ForEach(JellyfinAccessScheduleDay.allCases) { day in
                                Text(day.displayName).tag(day)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }

                Section("Start") {
                    HStack {
                        Picker("Hour", selection: $startHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(Self.twoDigit(hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)

                        Picker("Minute", selection: $startMinute) {
                            ForEach(Self.minuteOptions, id: \.self) { minute in
                                Text(Self.twoDigit(minute)).tag(minute)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                    .frame(height: 120)
                }

                Section {
                    HStack {
                        Picker("Hour", selection: $endHour) {
                            ForEach(0...24, id: \.self) { hour in
                                Text(Self.twoDigit(hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)
                        .onChange(of: endHour) { _, newValue in
                            if newValue == 24 {
                                endMinute = 0
                            }
                        }

                        Picker("Minute", selection: $endMinute) {
                            ForEach(Self.minuteOptions, id: \.self) { minute in
                                Text(Self.twoDigit(minute)).tag(minute)
                            }
                        }
                        .pickerStyle(.wheel)
                        .disabled(endHour == 24)
                    }
                    .frame(height: 120)
                } header: {
                    Text("End")
                } footer: {
                    Text("Schedules define the allowed access window for the selected day.")
                }

                if !canSave {
                    Section {
                        Text("End time must be later than start time.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func save() {
        let schedule = JellyfinAccessSchedule(
            dayOfWeek: selectedDay.rawValue,
            startHour: startDecimalHour,
            endHour: endDecimalHour
        )
        onSave(schedule, session.index)
        dismiss()
    }

    private static let minuteOptions = [0, 15, 30, 45]

    private static func timeComponents(from decimalHour: Double) -> (hour: Int, minute: Int) {
        let clamped = min(max(decimalHour, 0), 24)
        let hour = min(Int(clamped), 24)
        let rawMinute = Int(((clamped - Double(hour)) * 60).rounded())
        let minute = minuteOptions.min(by: { abs($0 - rawMinute) < abs($1 - rawMinute) }) ?? 0
        return hour == 24 ? (24, 0) : (hour, minute)
    }

    private static func twoDigit(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}

private enum JellyfinAccessScheduleDay: String, CaseIterable, Identifiable {
    case sunday = "Sunday"
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

private struct JellyfinTagEditorContext: Identifiable {
    let id = UUID()
    let kind: JellyfinPolicyTagEditorKind
}

private enum JellyfinPolicyTagEditorKind {
    case allowed
    case blocked

    var title: String {
        switch self {
        case .allowed: "Allowed Tags"
        case .blocked: "Blocked Tags"
        }
    }

    var selectedSectionTitle: String {
        switch self {
        case .allowed: "Allowed"
        case .blocked: "Blocked"
        }
    }

    var availableSectionTitle: String { "Available" }

    var emptySelectedText: String {
        switch self {
        case .allowed: "No allowed tags selected."
        case .blocked: "No blocked tags selected."
        }
    }
}

private struct JellyfinPolicyTagEditorSheet: View {
    @Binding var selectedTags: [String]

    let context: JellyfinTagEditorContext
    let availableTags: [String]

    @State private var newTag = ""

    private var selected: [String] {
        selectedTags.normalizedTags
    }

    private var available: [String] {
        availableTags
            .normalizedTags
            .filter { tag in !selected.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) }
    }

    init(
        context: JellyfinTagEditorContext,
        selectedTags: Binding<[String]>,
        availableTags: [String]
    ) {
        self.context = context
        self._selectedTags = selectedTags
        self.availableTags = availableTags
    }

    var body: some View {
        AppSheetShell(title: context.kind.title, cancelTitle: "Done") {
            List {
                Section(context.kind.selectedSectionTitle) {
                    if selected.isEmpty {
                        Text(context.kind.emptySelectedText)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selected, id: \.self) { tag in
                            tagRow(tag, systemImage: "minus.circle.fill", tint: .red) {
                                remove(tag)
                            }
                        }
                    }
                }

                Section {
                    ForEach(available, id: \.self) { tag in
                        tagRow(tag, systemImage: "plus.circle.fill", tint: .green) {
                            add(tag)
                        }
                    }

                    HStack {
                        TextField("Tag", text: $newTag)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        Button {
                            add(newTag)
                            newTag = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text(context.kind.availableSectionTitle)
                } footer: {
                    Text("Jellyfin does not expose a complete tag catalog here yet, so this list uses known policy tags and manual entry.")
                }
            }
        }
    }

    private func tagRow(_ tag: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Text(tag)
                .foregroundStyle(.primary)
        }
    }

    private func add(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !selectedTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        selectedTags = (selectedTags + [trimmed]).normalizedTags
    }

    private func remove(_ tag: String) {
        selectedTags = selectedTags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }.normalizedTags
    }
}

// MARK: - Policy Item Selector

private struct JellyfinPolicySelectorContext: Identifiable {
    let id = UUID()
    let kind: JellyfinPolicySelectorKind
}

private enum JellyfinPolicySelectorKind {
    case enabledLibraries
    case blockedLibraries
    case deletionLibraries
    case enabledDevices
    case enabledChannels
    case blockedChannels

    var title: String {
        switch self {
        case .enabledLibraries: "Enabled Libraries"
        case .blockedLibraries: "Blocked Libraries"
        case .deletionLibraries: "Deletion Libraries"
        case .enabledDevices: "Enabled Devices"
        case .enabledChannels: "Enabled Channels"
        case .blockedChannels: "Blocked Channels"
        }
    }

    var selectedSectionTitle: String {
        switch self {
        case .enabledLibraries: "Enabled"
        case .blockedLibraries: "Blocked"
        case .deletionLibraries: "Deletion Enabled"
        case .enabledDevices: "Enabled"
        case .enabledChannels: "Enabled"
        case .blockedChannels: "Blocked"
        }
    }

    var emptySelectedText: String {
        switch self {
        case .enabledLibraries: "No libraries enabled."
        case .blockedLibraries: "No libraries blocked."
        case .deletionLibraries: "No libraries set for deletion."
        case .enabledDevices: "No devices enabled."
        case .enabledChannels: "No channels enabled."
        case .blockedChannels: "No channels blocked."
        }
    }

    var emptyAvailableText: String {
        switch self {
        case .enabledLibraries, .blockedLibraries, .deletionLibraries: "No libraries found on server."
        case .enabledDevices: "No devices found on server."
        case .enabledChannels, .blockedChannels: "No channels found on server."
        }
    }
}

private struct JellyfinPolicySelectorItem: Identifiable {
    let id: String
    let name: String
    let icon: String
}

private struct JellyfinPolicySelectorSheet: View {
    @Binding var selectedIds: [String]

    let title: String
    let selectedSectionTitle: String
    let emptySelectedText: String
    let emptyAvailableText: String
    let availableItems: [JellyfinPolicySelectorItem]

    private var selectedItems: [JellyfinPolicySelectorItem] {
        selectedIds.compactMap { id in availableItems.first(where: { $0.id == id }) }
    }

    private var orphanIds: [String] {
        selectedIds.filter { id in !availableItems.contains(where: { $0.id == id }) }
    }

    private var unselectedItems: [JellyfinPolicySelectorItem] {
        availableItems.filter { !selectedIds.contains($0.id) }
    }

    var body: some View {
        AppSheetShell(title: title, cancelTitle: "Done", detents: [.medium]) {
            List {
                Section(selectedSectionTitle) {
                    if selectedIds.isEmpty {
                        Text(emptySelectedText)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedItems) { item in
                            selectorRow(name: item.name, icon: item.icon, tint: .red) { remove(item.id) }
                        }
                        ForEach(orphanIds, id: \.self) { id in
                            selectorRow(name: id, icon: "questionmark", tint: .red) { remove(id) }
                        }
                    }
                }

                Section("Available") {
                    if availableItems.isEmpty {
                        Text(emptyAvailableText)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(unselectedItems) { item in
                            selectorRow(name: item.name, icon: item.icon, tint: .green) { add(item.id) }
                        }
                    }
                }
            }
        }
    }

    private func selectorRow(name: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: tint == .red ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(tint)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Label(name, systemImage: icon)
                .foregroundStyle(.primary)
        }
    }

    private func add(_ id: String) {
        guard !selectedIds.contains(id) else { return }
        selectedIds.append(id)
    }

    private func remove(_ id: String) {
        selectedIds.removeAll { $0 == id }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element == String {
    var normalizedTags: [String] {
        reduce(into: [String]()) { result, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            result.append(trimmed)
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var nilIfEmpty: [String]? {
        isEmpty ? nil : self
    }
}
