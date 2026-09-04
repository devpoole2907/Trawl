import SwiftUI

struct ArrQualityProfilesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    /// Quality profiles are per-server, and an HD/4K pair's are the whole point
    /// of running two servers - one cuts off at 1080p, the other starts at 2160p.
    @State private var selectedInstanceID: UUID?
    /// Which profile the detail pane is showing, at regular width. Nil on iPhone,
    /// where the row pushes instead.
    @State private var selectedProfileID: ArrQualityProfile.ID?
    @State private var editorSession: ArrQualityProfileEditorSession?
    @State private var profilePendingDelete: ArrQualityProfile?
    @State private var isSaving = false
    /// Add has to ask the server what qualities it has before it can offer a
    /// blank profile, so the button spins rather than opening an empty sheet.
    @State private var isLoadingSchema = false

    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances.map(\.ref)
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private var selectedService: ArrServiceType {
        selectedInstance?.serviceType ?? .sonarr
    }

    private var profiles: [ArrQualityProfile] {
        guard let instance = selectedInstance else { return [] }
        return serviceManager.qualityProfilesByInstance
            .first { $0.ref.id == instance.id }?.values ?? []
    }

    /// Every mutation on this screen goes to the selected server.
    private var scopedClient: (any SharedArrClient)? {
        selectedInstance.flatMap { serviceManager.sharedClient(for: $0) }
    }

    private var selectedLabel: String {
        selectedInstance.map { serviceManager.scopeLabel(for: $0) } ?? ""
    }

    private var sortedProfiles: [ArrQualityProfile] {
        profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    private var showsDetailPane: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    private var selectedProfile: ArrQualityProfile? {
        sortedProfiles.first { $0.id == selectedProfileID }
    }

    /// The right-hand pane: whichever profile is selected.
    ///
    /// The same detail view the row pushes on iPhone, given the same actions - the
    /// editor and the delete confirmation are presented by this screen either way,
    /// so a profile edited from the pane and one edited from a push go through one
    /// path.
    @ViewBuilder
    private var selectedProfileDetail: some View {
        if let profile = selectedProfile {
            ArrQualityProfileDetailView(
                serviceType: selectedService,
                profile: profile,
                instance: selectedInstance,
                onEdit: { editorSession = .edit(profile) },
                onDuplicate: { editorSession = .duplicate(from: profile) },
                onDelete: { profilePendingDelete = profile }
            )
            .id(profile.id)
        } else {
            listDetailPlaceholder("Select a Quality Profile", systemImage: "slider.horizontal.3")
        }
    }

    /// Keeps the pane pointed at something that is still there.
    ///
    /// The list is rebuilt whenever the scope bar changes server, and the two halves
    /// of an HD/4K pair do not share profile ids - so a selection carried across a
    /// scope change names a profile the new server has never heard of, and the pane
    /// goes blank while a row still looks selected. Nothing is auto-selected in its
    /// place: which profile matters is the user's choice, not the list's order.
    private func reconcileSelection() {
        guard showsDetailPane else {
            selectedProfileID = nil
            return
        }
        if let selectedProfileID, !sortedProfiles.contains(where: { $0.id == selectedProfileID }) {
            self.selectedProfileID = nil
        }
    }

    var body: some View {
        // Two panes at regular width. A quality profile is read by comparing it with
        // the ones beside it - which cutoff, whether upgrades are allowed, where they
        // stop - and a layout that shows one at a time turns every comparison into a
        // round trip through the list.
        TrawlListDetailPanes(title: "Quality Profiles") {
            profileList
        } detail: {
            selectedProfileDetail
        }
        .toolbar {
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button {
                    Task { await beginNewProfile() }
                } label: {
                    if isLoadingSchema {
                        ProgressView()
                    } else {
                        Label("New Profile", systemImage: "plus")
                    }
                }
                .disabled(isSaving || isLoadingSchema || scopedClient == nil)
            }
        }
        .sheet(item: $editorSession) { session in
            NavigationStack {
                ArrQualityProfileEditorView(
                    serviceType: selectedService,
                    serverLabel: selectedInstance.map { serviceManager.scopeLabel(for: $0) },
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
            Text("Delete '\(profile.name)' from \(selectedLabel)?")
        }
        .onAppear {
            selectedInstanceID = serviceManager.defaultScopeInstanceID(preferring: selectedInstanceID)
            reconcileSelection()
        }
        // The scope bar rebuilds the list from a different server, and a profile is
        // deleted out from under the pane; both leave a selection naming something
        // that is no longer there.
        .onChange(of: selectedInstanceID) { reconcileSelection() }
        .onChange(of: sortedProfiles.map(\.id)) { reconcileSelection() }
    }


    private var profileList: some View {
        List(selection: $selectedProfileID) {
            Section {
                ForEach(sortedProfiles) { profile in
                    profileRow(profile)
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
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .moreDestinationBackground(.qualityProfiles)
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(instances: availableInstances, selection: $selectedInstanceID)
        }
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func profileRow(_ profile: ArrQualityProfile) -> some View {
        if showsDetailPane {
            ArrQualityProfileSummaryRow(profile: profile)
                .tag(profile.id)
        } else {
            NavigationLink {
                ArrQualityProfileDetailView(
                    serviceType: selectedService,
                    profile: profile,
                    instance: selectedInstance,
                    onEdit: { editorSession = .edit(profile) },
                    onDuplicate: { editorSession = .duplicate(from: profile) },
                    onDelete: { profilePendingDelete = profile }
                )
            } label: {
                ArrQualityProfileSummaryRow(profile: profile)
            }
        }
    }

    /// Asks the selected server for a blank profile shaped by its own quality
    /// definitions, then opens the editor on it.
    ///
    /// The round trip is why this is a button action rather than a plain sheet
    /// presentation: the qualities belong to the server, and the two halves of an
    /// HD/4K pair do not necessarily have the same ones.
    private func beginNewProfile() async {
        guard !isLoadingSchema, let client = scopedClient else { return }
        isLoadingSchema = true
        defer { isLoadingSchema = false }

        do {
            let schema = try await client.getQualityProfileSchema()
            editorSession = .new(from: schema)
        } catch {
            inAppNotificationCenter.showError(
                title: "Could Not Start",
                message: "\(selectedLabel) did not return its quality options. \(error.localizedDescription)"
            )
        }
    }

    private func save(_ draft: ArrQualityProfileDraft) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let profile = draft.makeProfile()

        do {
            guard let client = scopedClient else { return false }
            if draft.apiID == nil {
                _ = try await client.createQualityProfile(profile)
            } else {
                _ = try await client.updateQualityProfile(profile)
            }

            await serviceManager.refreshConfiguration()
            editorSession = nil
            let verb = draft.apiID == nil ? "created" : "updated"
            inAppNotificationCenter.showSuccess(title: "Saved", message: "Quality profile \(verb) in \(selectedLabel).")
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
            guard let client = scopedClient else { return }
            try await client.deleteQualityProfile(id: profile.id)

            await serviceManager.refreshConfiguration()
            inAppNotificationCenter.showSuccess(title: "Deleted", message: "Removed '\(profile.name)' from \(selectedLabel).")
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

struct ArrQualityProfileDetailView: View {
    let serviceType: ArrServiceType
    let profile: ArrQualityProfile
    var instance: ArrInstanceRef? = nil
    var onEdit: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var allowedQualities: [ArrQualityProfileQuality] {
        profile.flattenedQualities.filter(\.allowed)
    }

    private var blockedQualities: [ArrQualityProfileQuality] {
        profile.flattenedQualities.filter { !$0.allowed }
    }

    private var hasFormatScoring: Bool {
        profile.minFormatScore != nil || profile.cutoffFormatScore != nil ||
        profile.minUpgradeFormatScore != nil || !(profile.formatItems?.isEmpty ?? true)
    }

    var body: some View {
        List {
            Section {
                if let instance {
                    LabeledContent("Server") {
                        ArrInstanceBadge(label: instance.qualifiedLabel, ordinal: instance.ordinal)
                    }
                }

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

            if hasFormatScoring {
                Section("Custom Format Scoring") {
                    if let min = profile.minFormatScore {
                        LabeledContent("Minimum Score") {
                            Text("\(min)").foregroundStyle(.secondary)
                        }
                    }
                    if let cutoff = profile.cutoffFormatScore {
                        LabeledContent("Cutoff Score") {
                            Text("\(cutoff)").foregroundStyle(.secondary)
                        }
                    }
                    if let minUpgrade = profile.minUpgradeFormatScore {
                        LabeledContent("Minimum Upgrade Score") {
                            Text("\(minUpgrade)").foregroundStyle(.secondary)
                        }
                    }
                    if let items = profile.formatItems, !items.isEmpty {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            let name = item.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Format #\(item.format ?? 0)"
                            LabeledContent(name) {
                                if let score = item.score {
                                    Text(score > 0 ? "+\(score)" : "\(score)")
                                        .foregroundStyle(score > 0 ? .green : score < 0 ? .red : .secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
        .paneAwareNavigationTitle(profile.name, subtitle: serviceType.displayName)
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

                    if profile.hasActiveCustomFormatScoring {
                        HStack(spacing: 4) {
                            Image(systemName: "star.circle")
                            Text("CF")
                        }
                        .foregroundStyle(.purple)
                    }
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
    /// Why the sheet is open. Previously inferred from `apiID == nil`, which
    /// cannot tell a new profile from a duplicate - so everything that wasn't an
    /// edit was titled "Duplicate Profile".
    enum Kind {
        case new
        case duplicate
        case edit

        var title: String {
            switch self {
            case .new: "New Profile"
            case .duplicate: "Duplicate Profile"
            case .edit: "Edit Profile"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let draft: ArrQualityProfileDraft

    static func edit(_ profile: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(kind: .edit, draft: ArrQualityProfileDraft(profile: profile))
    }

    /// Built from the server's own `/qualityprofile/schema`, so the draft carries
    /// exactly the qualities this server knows about - the reason a blank profile
    /// cannot simply be constructed here.
    static func new(from schema: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(kind: .new, draft: ArrQualityProfileDraft(
            apiID: nil,
            name: "",
            upgradeAllowed: schema.upgradeAllowed ?? true,
            cutoff: schema.cutoff,
            items: schema.items ?? [],
            minFormatScore: schema.minFormatScore,
            cutoffFormatScore: schema.cutoffFormatScore,
            minUpgradeFormatScore: schema.minUpgradeFormatScore,
            formatItems: schema.formatItems,
            language: schema.language
        ))
    }

    static func duplicate(from profile: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(kind: .duplicate, draft: ArrQualityProfileDraft(
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
    let serverLabel: String?
    let session: ArrQualityProfileEditorSession
    let isSaving: Bool
    let onSave: @Sendable (ArrQualityProfileDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ArrQualityProfileDraft

    init(
        serviceType: ArrServiceType,
        serverLabel: String? = nil,
        session: ArrQualityProfileEditorSession,
        isSaving: Bool,
        onSave: @escaping @Sendable (ArrQualityProfileDraft) async -> Bool
    ) {
        self.serviceType = serviceType
        self.serverLabel = serverLabel
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
            if let serverLabel {
                Section {
                    LabeledContent("Server", value: serverLabel)
                }
            }

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
        .navigationTitle(session.kind.title)
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
    var hasActiveCustomFormatScoring: Bool {
        if (minFormatScore ?? 0) > 0 || (cutoffFormatScore ?? 0) > 0 { return true }
        return formatItems?.contains { ($0.score ?? 0) != 0 } ?? false
    }

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

#if DEBUG
#Preview("Quality Profiles - List") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrQualityProfilesListView()
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Quality Profile - Detail") {
    NavigationStack {
        ArrQualityProfileDetailView(serviceType: .sonarr, profile: .preview)
    }
}

#Preview("Quality Profile - Editor") {
    NavigationStack {
        ArrQualityProfileEditorView(
            serviceType: .sonarr,
            session: .edit(.preview),
            isSaving: false
        ) { _ in true }
    }
}
#endif
