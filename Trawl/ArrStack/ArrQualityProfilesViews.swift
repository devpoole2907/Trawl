import SwiftUI

struct ArrQualityProfilesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var selectedService: ArrServiceType = .sonarr
    @State private var editorSession: ArrQualityProfileEditorSession?
    @State private var profilePendingDelete: ArrQualityProfile?
    @State private var isSaving = false

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var profiles: [ArrQualityProfile] {
        switch selectedService {
        case .sonarr:
            serviceManager.sonarrQualityProfiles
        case .radarr:
            serviceManager.radarrQualityProfiles
        case .prowlarr, .bazarr:
            []
        }
    }

    private var sortedProfiles: [ArrQualityProfile] {
        profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedProfiles) { profile in
                    NavigationLink {
                        ArrQualityProfileDetailView(
                            serviceType: selectedService,
                            profile: profile,
                            onEdit: {
                                editorSession = .edit(profile)
                            },
                            onDuplicate: {
                                editorSession = .duplicate(from: profile)
                            },
                            onDelete: {
                                profilePendingDelete = profile
                            }
                        )
                    } label: {
                        ArrQualityProfileSummaryRow(profile: profile)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            profilePendingDelete = profile
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            editorSession = .duplicate(from: profile)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.blue)

                        Button {
                            editorSession = .edit(profile)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") {
                            editorSession = .edit(profile)
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            editorSession = .duplicate(from: profile)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            profilePendingDelete = profile
                        }
                    }
                }
            } footer: {
                Text("Quality profiles define which releases qualify, whether upgrades are allowed, and where upgrades stop.")
            }
        }
        .navigationTitle("Quality Profiles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedService },
                    set: { newService in withAnimation { selectedService = newService } }
                ),
                items: availableServices.map(\.segmentBarItem),
                alignment: .center
            )
        }
        .toolbar {
            if let firstProfile = sortedProfiles.first {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button {
                        editorSession = .duplicate(from: firstProfile)
                    } label: {
                        Label("Duplicate Profile", systemImage: "plus")
                    }
                    .disabled(isSaving)
                }
            }
        }
        .sheet(item: $editorSession) { session in
            NavigationStack {
                ArrQualityProfileEditorView(
                    serviceType: selectedService,
                    session: session,
                    isSaving: isSaving,
                    onSave: { draft in
                        await save(draft)
                    }
                )
            }
        }
        .alert(
            "Delete Quality Profile?",
            isPresented: Binding(
                get: { profilePendingDelete != nil },
                set: { if !$0 { profilePendingDelete = nil } }
            ),
            presenting: profilePendingDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                Task { await delete(profile) }
            }
            Button("Cancel", role: .cancel) {
                profilePendingDelete = nil
            }
        } message: { profile in
            Text("Delete '\(profile.name)' from \(selectedService.displayName)?")
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    private func save(_ draft: ArrQualityProfileDraft) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let profile = draft.makeProfile()

        do {
            switch selectedService {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return false }
                if draft.apiID == nil {
                    _ = try await client.createQualityProfile(profile)
                } else {
                    _ = try await client.updateQualityProfile(profile)
                }
            case .radarr:
                guard let client = serviceManager.radarrClient else { return false }
                if draft.apiID == nil {
                    _ = try await client.createQualityProfile(profile)
                } else {
                    _ = try await client.updateQualityProfile(profile)
                }
            case .prowlarr, .bazarr:
                return false
            }

            await serviceManager.refreshConfiguration()
            editorSession = nil
            let verb = draft.apiID == nil ? "created" : "updated"
            inAppNotificationCenter.showSuccess(title: "Saved", message: "Quality profile \(verb) in \(selectedService.displayName).")
            return true
        } catch {
            inAppNotificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    private func delete(_ profile: ArrQualityProfile) async {
        guard !isSaving else { return }
        isSaving = true
        defer {
            isSaving = false
            profilePendingDelete = nil
        }

        do {
            switch selectedService {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                try await client.deleteQualityProfile(id: profile.id)
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                try await client.deleteQualityProfile(id: profile.id)
            case .prowlarr, .bazarr:
                return
            }

            await serviceManager.refreshConfiguration()
            inAppNotificationCenter.showSuccess(title: "Deleted", message: "Removed '\(profile.name)' from \(selectedService.displayName).")
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

struct ArrQualityProfileDetailView: View {
    let serviceType: ArrServiceType
    let profile: ArrQualityProfile
    var onEdit: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var allowedQualities: [ArrQualityProfileQuality] {
        profile.flattenedQualities.filter(\.allowed)
    }

    private var blockedQualities: [ArrQualityProfileQuality] {
        profile.flattenedQualities.filter { !$0.allowed }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Service") {
                    HStack(spacing: 4) {
                        Image(systemName: serviceType.systemImage)
                        Text(serviceType.displayName)
                    }
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Upgrade Allowed") {
                    Text(profile.upgradeAllowed == true ? "Yes" : "No")
                        .foregroundStyle(profile.upgradeAllowed == true ? .green : .secondary)
                }

                LabeledContent("Cutoff") {
                    Text(profile.cutoffDisplayName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Allowed Qualities") {
                    Text("\(allowedQualities.count)")
                        .foregroundStyle(.secondary)
                }

                if !blockedQualities.isEmpty {
                    LabeledContent("Blocked Qualities") {
                        Text("\(blockedQualities.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(profile.name)
            } footer: {
                Text("Use this profile when adding or editing library items to control what release qualities are accepted.")
            }

            if !allowedQualities.isEmpty {
                Section("Allowed Qualities") {
                    ForEach(allowedQualities) { quality in
                        qualityRow(for: quality, tint: .green)
                    }
                }
            }

            if !blockedQualities.isEmpty {
                Section("Blocked Qualities") {
                    ForEach(blockedQualities) { quality in
                        qualityRow(for: quality, tint: .orange)
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let onEdit {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button("Edit") {
                        onEdit()
                    }
                }
            }

            if onDuplicate != nil || onDelete != nil {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Menu {
                        if let onDuplicate {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                onDuplicate()
                            }
                        }
                        if let onDelete {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                onDelete()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Profile Actions")
                }
            }
        }
    }

    private func qualityRow(for quality: ArrQualityProfileQuality, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: quality.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(quality.displayName)
                if let detail = quality.detailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ArrQualityProfileSummaryRow: View {
    let profile: ArrQualityProfile

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("\(profile.allowedQualityCount) allowed")
                    }
                    .foregroundStyle(.green)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle")
                        Text(profile.upgradeAllowed == true ? "Upgrades On" : "Upgrades Off")
                    }
                    .foregroundStyle(profile.upgradeAllowed == true ? .blue : .secondary)
                }
                .font(.caption)
            }

            Spacer(minLength: 0)

            Text(profile.cutoffDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ArrQualityProfileQuality: Identifiable, Hashable {
    let id: String
    let displayName: String
    let qualityID: Int?
    let detailText: String?
    let allowed: Bool
}

private struct ArrQualityProfileEditorSession: Identifiable {
    let id = UUID()
    let draft: ArrQualityProfileDraft

    static func edit(_ profile: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(draft: ArrQualityProfileDraft(profile: profile))
    }

    static func duplicate(from profile: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(draft: ArrQualityProfileDraft(
            apiID: nil,
            name: "\(profile.name) Copy",
            upgradeAllowed: profile.upgradeAllowed ?? true,
            cutoff: profile.cutoff,
            items: profile.items ?? [],
            minFormatScore: profile.minFormatScore,
            cutoffFormatScore: profile.cutoffFormatScore,
            minUpgradeFormatScore: profile.minUpgradeFormatScore,
            formatItems: profile.formatItems,
            language: profile.language
        ))
    }
}

private struct ArrQualityProfileDraft: Sendable {
    var apiID: Int?
    var name: String
    var upgradeAllowed: Bool
    var cutoff: Int?
    var items: [ArrQualityProfileItem]
    var minFormatScore: Int?
    var cutoffFormatScore: Int?
    var minUpgradeFormatScore: Int?
    var formatItems: [ArrQualityProfileFormatItem]?
    var language: ArrQualityProfileLanguage?

    init(profile: ArrQualityProfile) {
        apiID = profile.id
        name = profile.name
        upgradeAllowed = profile.upgradeAllowed ?? true
        cutoff = profile.cutoff
        items = profile.items ?? []
        minFormatScore = profile.minFormatScore
        cutoffFormatScore = profile.cutoffFormatScore
        minUpgradeFormatScore = profile.minUpgradeFormatScore
        formatItems = profile.formatItems
        language = profile.language
    }

    init(
        apiID: Int?,
        name: String,
        upgradeAllowed: Bool,
        cutoff: Int?,
        items: [ArrQualityProfileItem],
        minFormatScore: Int? = nil,
        cutoffFormatScore: Int? = nil,
        minUpgradeFormatScore: Int? = nil,
        formatItems: [ArrQualityProfileFormatItem]? = nil,
        language: ArrQualityProfileLanguage? = nil
    ) {
        self.apiID = apiID
        self.name = name
        self.upgradeAllowed = upgradeAllowed
        self.cutoff = cutoff
        self.items = items
        self.minFormatScore = minFormatScore
        self.cutoffFormatScore = cutoffFormatScore
        self.minUpgradeFormatScore = minUpgradeFormatScore
        self.formatItems = formatItems
        self.language = language
    }

    func makeProfile() -> ArrQualityProfile {
        ArrQualityProfile(
            id: apiID ?? 0,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            upgradeAllowed: upgradeAllowed,
            cutoff: cutoff,
            items: items,
            minFormatScore: minFormatScore,
            cutoffFormatScore: cutoffFormatScore,
            minUpgradeFormatScore: minUpgradeFormatScore,
            formatItems: formatItems,
            language: language
        )
    }
}

private struct ArrQualityProfileEditorView: View {
    let serviceType: ArrServiceType
    let session: ArrQualityProfileEditorSession
    let isSaving: Bool
    let onSave: @Sendable (ArrQualityProfileDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ArrQualityProfileDraft

    init(
        serviceType: ArrServiceType,
        session: ArrQualityProfileEditorSession,
        isSaving: Bool,
        onSave: @escaping @Sendable (ArrQualityProfileDraft) async -> Bool
    ) {
        self.serviceType = serviceType
        self.session = session
        self.isSaving = isSaving
        self.onSave = onSave
        _draft = State(initialValue: session.draft)
    }

    private var sortedQualities: [ArrQualityProfileQuality] {
        draft.makeProfile().flattenedQualities.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var allowedQualityChoices: [ArrQualityProfileQuality] {
        sortedQualities.filter(\.allowed)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let flattenedQualities = draft.makeProfile().flattenedQualities
        Form {
            Section {
                TextField("Name", text: $draft.name)
                Toggle("Allow Upgrades", isOn: $draft.upgradeAllowed)

                Picker("Cutoff", selection: cutoffBinding) {
                    Text("None").tag(Optional<Int>.none)
                    ForEach(allowedQualityChoices) { quality in
                        let qualityTag: Int? = quality.qualityID
                        Text(quality.displayName).tag(qualityTag)
                    }
                }
                .disabled(allowedQualityChoices.isEmpty || !draft.upgradeAllowed)
            } header: {
                Text("Profile")
            } footer: {
                Text("Cutoff determines the best quality \(serviceType.displayName) should keep upgrading toward.")
            }

            Section {
                ForEach(sortedQualities) { quality in
                    Toggle(isOn: allowedBinding(for: quality)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.displayName)
                            if let detail = quality.detailText {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Allowed Qualities")
            }
        }
        .navigationTitle(session.draft.apiID == nil ? "Duplicate Profile" : "Edit Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: platformCancellationPlacement) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button("Save") {
                    Task {
                        if await onSave(draft) {
                            dismiss()
                        }
                    }
                }
                .disabled(!canSave || isSaving)
            }
        }
        .onChange(of: draft.upgradeAllowed) { _, isEnabled in
            if isEnabled, draft.cutoff == nil {
                draft.cutoff = allowedQualityChoices.first?.qualityID
            }
        }
        .onChange(of: flattenedQualities) { _, _ in
            if let cutoff = draft.cutoff,
               !allowedQualityChoices.contains(where: { $0.qualityID == cutoff }) {
                draft.cutoff = allowedQualityChoices.first?.qualityID
            }
        }
    }

    private var cutoffBinding: Binding<Int?> {
        Binding(
            get: { draft.cutoff },
            set: { draft.cutoff = $0 }
        )
    }

    private func allowedBinding(for quality: ArrQualityProfileQuality) -> Binding<Bool> {
        Binding(
            get: { quality.qualityID.flatMap { draft.isQualityAllowed(id: $0) } ?? quality.allowed },
            set: { newValue in
                guard let qualityID = quality.qualityID else { return }
                draft.setQualityAllowed(id: qualityID, allowed: newValue)
                if draft.cutoff == qualityID, !newValue {
                    draft.cutoff = allowedQualityChoices.first(where: { $0.qualityID != qualityID })?.qualityID
                } else if draft.cutoff == nil, newValue, draft.upgradeAllowed {
                    draft.cutoff = qualityID
                }
            }
        )
    }
}

private extension ArrQualityProfile {
    var flattenedQualities: [ArrQualityProfileQuality] {
        var seen = Set<String>()
        return flatten(items: items, inheritedAllowed: nil).filter { seen.insert($0.id).inserted }
    }

    var allowedQualityCount: Int {
        flattenedQualities.filter(\.allowed).count
    }

    var cutoffDisplayName: String {
        guard let cutoff else { return "None" }
        if let matched = flattenedQualities.first(where: { $0.id.hasPrefix("quality-\(cutoff)-") }) {
            return matched.displayName
        }
        return "Quality #\(cutoff)"
    }

    private func flatten(items: [ArrQualityProfileItem]?, inheritedAllowed: Bool?) -> [ArrQualityProfileQuality] {
        guard let items else { return [] }

        return items.reduce(into: [ArrQualityProfileQuality]()) { result, item in
            let resolvedAllowed = item.allowed ?? inheritedAllowed
            let childItems = flatten(items: item.items, inheritedAllowed: resolvedAllowed)

            guard let quality = item.quality else {
                result.append(contentsOf: childItems)
                return
            }

            let name = quality.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let qualityName = (name?.isEmpty == false ? name : nil) ?? "Quality #\(quality.id ?? 0)"
            let source = quality.source?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolution = quality.resolution.map { "\($0)p" }
            let detailParts = [source, resolution].reduce(into: [String]()) { partialResult, value in
                if let value, !value.isEmpty {
                    partialResult.append(value)
                }
            }

            let qualityID = "quality-\(quality.id ?? -1)-\(qualityName)"
            let entry = ArrQualityProfileQuality(
                id: qualityID,
                displayName: qualityName,
                qualityID: quality.id,
                detailText: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
                allowed: resolvedAllowed ?? false
            )

            result.append(entry)
            result.append(contentsOf: childItems)
        }
    }
}

private extension ArrQualityProfileDraft {
    mutating func setQualityAllowed(id: Int, allowed: Bool) {
        items = items.map { $0.settingAllowed(id: id, allowed: allowed) }
    }

    func isQualityAllowed(id: Int) -> Bool {
        items.firstAllowedValue(for: id) ?? false
    }
}

private extension Array where Element == ArrQualityProfileItem {
    func firstAllowedValue(for qualityID: Int, inheritedAllowed: Bool? = nil) -> Bool? {
        for item in self {
            let resolved = item.allowed ?? inheritedAllowed
            if item.quality?.id == qualityID {
                return resolved
            }
            if let nested = item.items?.firstAllowedValue(for: qualityID, inheritedAllowed: resolved) {
                return nested
            }
        }
        return nil
    }
}

private extension ArrQualityProfileItem {
    func settingAllowed(id qualityID: Int, allowed: Bool) -> ArrQualityProfileItem {
        var updated = self
        if updated.quality?.id == qualityID {
            updated.allowed = allowed
        }
        if let nestedItems = updated.items {
            updated.items = nestedItems.map { $0.settingAllowed(id: qualityID, allowed: allowed) }
        }
        return updated
    }
}
