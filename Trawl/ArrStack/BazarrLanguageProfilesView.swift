import SwiftUI

struct BazarrLanguageProfilesView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var profiles: [BazarrLanguageProfile] = []
    @State private var availableLanguages: [BazarrLanguage] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var addSheetPresented = false
    @State private var deleteTarget: BazarrLanguageProfile?

    private var client: BazarrAPIClient? {
        serviceManager.activeBazarrEntry?.client
    }

    private var filteredProfiles: [BazarrLanguageProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if !serviceManager.hasBazarrInstance {
                ContentUnavailableView(
                    "Bazarr Not Set Up",
                    systemImage: "captions.bubble",
                    description: Text("Add a Bazarr server in Settings to manage language profiles.")
                )
            } else if client == nil {
                ContentUnavailableView(
                    "Bazarr Unreachable",
                    systemImage: "network.slash",
                    description: Text(serviceManager.bazarrConnectionError ?? "Unable to reach your configured Bazarr server.")
                )
            } else {
                contentView
            }
        }
        .navigationTitle("Language Profiles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $searchText, prompt: "Search profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addSheetPresented = true
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .disabled(client == nil)
            }
        }
        .sheet(isPresented: $addSheetPresented) {
            LanguageProfileEditorView(
                mode: .add,
                availableLanguages: availableLanguages
            ) { draft in
                await save(draft: draft, existing: nil)
                addSheetPresented = false
            }
        }
        .alert(
            "Delete Profile?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await delete(target) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This will permanently remove the language profile from Bazarr.")
        }
        .task(id: serviceManager.activeBazarrProfileID) {
            await load()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        List {
            if let errorMessage {
                Section("Unavailable") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && profiles.isEmpty {
                loadingRows
            } else if filteredProfiles.isEmpty {
                emptyState
            } else {
                Section("Profiles") {
                    ForEach(filteredProfiles) { profile in
                        NavigationLink {
                            LanguageProfileDetailView(
                                profile: profile,
                                availableLanguages: availableLanguages,
                                allProfiles: profiles,
                                onSave: { draft in await save(draft: draft, existing: profile) }
                            )
                        } label: {
                            LanguageProfileRowView(profile: profile, availableLanguages: availableLanguages)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = profile
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTarget = profile
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
        .background(backgroundGradient)
        .refreshable { await load() }
    }

    private var loadingRows: some View {
        Section("Profiles") {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 4, height: 42)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 160, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 120, height: 11)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            searchText.isEmpty ? "No Language Profiles" : "No Results",
            systemImage: searchText.isEmpty ? "globe" : "magnifyingglass",
            description: Text(searchText.isEmpty
                ? "No language profiles are configured in Bazarr."
                : "No profiles match your search.")
        )
        .listRowBackground(Color.clear)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [MoreDestinationAccent.languageProfiles.color.opacity(0.10), Color.indigo.opacity(0.05), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [MoreDestinationAccent.languageProfiles.color.opacity(0.12), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }

    private func load() async {
        guard let client else {
            profiles = []
            return
        }
        profiles = serviceManager.activeBazarrEntry?.languageProfiles ?? []
        isLoading = profiles.isEmpty
        errorMessage = nil
        do {
            async let profilesLoad = client.getLanguageProfiles()
            async let languagesLoad = client.getLanguages()
            let fetchedProfiles = try await profilesLoad
            let fetchedLanguages = (try? await languagesLoad) ?? []
            profiles = fetchedProfiles
            availableLanguages = fetchedLanguages
            if let id = serviceManager.activeBazarrEntry?.id {
                serviceManager.updateBazarrLanguageProfiles(for: id, profiles: fetchedProfiles, languages: fetchedLanguages)
            }
        } catch {
            if profiles.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func save(draft: LanguageProfileDraft, existing: BazarrLanguageProfile?) async {
        guard let client else { return }
        do {
            // Send new items with bazarrId 0; the server assigns IDs on save.
            let items: [BazarrLanguageProfileItem] = draft.items.map { item in
                BazarrLanguageProfileItem(
                    bazarrId: item.bazarrId,
                    language: item.language,
                    hi: item.hi,
                    forced: item.forced,
                    audioExclude: item.audioExclude,
                    audioOnlyInclude: item.audioOnlyInclude
                )
            }
            let itemsData = try JSONEncoder().encode(items)
            let itemsString = String(data: itemsData, encoding: .utf8) ?? "[]"

            let profileId = existing?.profileId ?? ((profiles.map(\.profileId).max() ?? 0) + 1)

            // Resolve cutoff by language identity so it survives reordering/renumbering.
            let cutoff: Int? = {
                guard let existing,
                      let existingCutoffId = existing.cutoff,
                      let cutoffItem = existing.parsedItems.first(where: { $0.bazarrId == existingCutoffId })
                else { return nil }
                return items.first(where: {
                    $0.language == cutoffItem.language && $0.hi == cutoffItem.hi && $0.forced == cutoffItem.forced
                })?.bazarrId
            }()
            let updated = BazarrLanguageProfile(
                profileId: profileId,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                cutoff: cutoff,
                itemsJSON: itemsString,
                mustContain: draft.mustContain.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                mustNotContain: draft.mustNotContain.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                originalFormat: existing?.originalFormat,
                tag: existing?.tag
            )

            var next = profiles
            if let idx = next.firstIndex(where: { $0.profileId == profileId }) {
                next[idx] = updated
            } else {
                next.append(updated)
            }

            try await client.saveLanguageProfiles(next)
            InAppNotificationCenter.shared.showSuccess(
                title: existing == nil ? "Profile Added" : "Profile Saved",
                message: "\"\(updated.name)\" has been saved."
            )
            await load()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Save Failed", message: error.localizedDescription)
        }
    }

    private func delete(_ profile: BazarrLanguageProfile) async {
        guard let client else { return }
        let remaining = profiles.filter { $0.profileId != profile.profileId }
        do {
            try await client.saveLanguageProfiles(remaining)
            InAppNotificationCenter.shared.showSuccess(
                title: "Profile Deleted",
                message: "\"\(profile.name)\" has been removed."
            )
            await load()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - Row

private struct LanguageProfileRowView: View {
    let profile: BazarrLanguageProfile
    let availableLanguages: [BazarrLanguage]

    private var subtitle: String {
        let items = profile.parsedItems
        guard !items.isEmpty else { return "No languages" }
        return items.map { item in
            var label = BazarrLanguageProfileSupport.displayName(for: item.language, availableLanguages: availableLanguages)
            var flags: [String] = []
            if item.hi { flags.append("HI") }
            if item.forced { flags.append("Forced") }
            if !flags.isEmpty { label += " (\(flags.joined(separator: ", ")))" }
            return label
        }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(MoreDestinationAccent.languageProfiles.color)
                .frame(width: 4, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(MoreDestinationAccent.languageProfiles.color)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

private struct LanguageProfileDetailView: View {
    let profile: BazarrLanguageProfile
    let availableLanguages: [BazarrLanguage]
    let allProfiles: [BazarrLanguageProfile]
    let onSave: (LanguageProfileDraft) async -> Void

    @State private var editSheetPresented = false

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Name", value: profile.name)
                LabeledContent("ID", value: String(profile.profileId))
            }

            let items = profile.parsedItems
            if !items.isEmpty {
                Section("Languages") {
                    ForEach(items) { item in
                        HStack {
                            Text(BazarrLanguageProfileSupport.displayName(for: item.language, availableLanguages: availableLanguages))
                            Spacer()
                            HStack(spacing: 6) {
                                if item.hi {
                                    Text("HI")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.blue, in: Capsule())
                                }
                                if item.forced {
                                    Text("Forced")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.orange, in: Capsule())
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Section("Languages") {
                    Text("No languages configured")
                        .foregroundStyle(.secondary)
                }
            }

            if let mustContain = profile.mustContain, !mustContain.isEmpty {
                Section("Must Contain") {
                    ForEach(mustContain, id: \.self) { Text($0) }
                }
            }

            if let mustNotContain = profile.mustNotContain, !mustNotContain.isEmpty {
                Section("Must Not Contain") {
                    ForEach(mustNotContain, id: \.self) { Text($0) }
                }
            }
        }
        .navigationTitle(profile.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editSheetPresented = true }
            }
        }
        .sheet(isPresented: $editSheetPresented) {
            LanguageProfileEditorView(
                mode: .edit(profile),
                availableLanguages: availableLanguages
            ) { draft in
                await onSave(draft)
                editSheetPresented = false
            }
        }
    }
}

// MARK: - Editor

struct LanguageProfileDraft {
    var name: String
    var items: [EditableLanguageItem]
    var mustContain: [String]
    var mustNotContain: [String]

    init() {
        name = ""
        items = []
        mustContain = []
        mustNotContain = []
    }

    init(from profile: BazarrLanguageProfile, availableLanguages: [BazarrLanguage] = []) {
        name = profile.name
        items = profile.parsedItems.map {
            EditableLanguageItem(
                bazarrId: $0.bazarrId,
                language: BazarrLanguageProfileSupport.canonicalCode(for: $0.language, availableLanguages: availableLanguages),
                hi: $0.hi,
                forced: $0.forced,
                audioExclude: $0.audioExclude,
                audioOnlyInclude: $0.audioOnlyInclude
            )
        }
        mustContain = profile.mustContain ?? []
        mustNotContain = profile.mustNotContain ?? []
    }
}

enum BazarrLanguageProfileSupport {
    static func canonicalCode(for language: String, availableLanguages: [BazarrLanguage]) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return language }
        if availableLanguages.contains(where: { $0.code2.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return trimmed
        }
        if let match = availableLanguages.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match.code2
        }
        return trimmed
    }

    static func displayName(for language: String, availableLanguages: [BazarrLanguage]) -> String {
        if let match = availableLanguages.first(where: { $0.code2.caseInsensitiveCompare(language) == .orderedSame }) {
            return match.name
        }
        return language
    }
}

struct EditableLanguageItem: Identifiable {
    let id = UUID()
    var bazarrId: Int = 0
    var language: String
    var hi: Bool
    var forced: Bool
    var audioExclude: Bool = false
    var audioOnlyInclude: Bool = false
}

private enum LanguageSubtitleVariant: CaseIterable, Identifiable, Equatable {
    case standard
    case hearingImpaired
    case forced
    case forcedHearingImpaired

    var id: Self { self }

    init(hi: Bool, forced: Bool) {
        switch (hi, forced) {
        case (false, false): self = .standard
        case (true, false): self = .hearingImpaired
        case (false, true): self = .forced
        case (true, true): self = .forcedHearingImpaired
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .hearingImpaired: "Hearing impaired"
        case .forced: "Forced"
        case .forcedHearingImpaired: "Forced + HI"
        }
    }

    var shortTitle: String {
        switch self {
        case .standard: "Std"
        case .hearingImpaired: "HI"
        case .forced: "Forced"
        case .forcedHearingImpaired: "F+HI"
        }
    }

    var hi: Bool {
        switch self {
        case .hearingImpaired, .forcedHearingImpaired: true
        case .standard, .forced: false
        }
    }

    var forced: Bool {
        switch self {
        case .forced, .forcedHearingImpaired: true
        case .standard, .hearingImpaired: false
        }
    }
}

private struct LanguageProfileEditorView: View {
    enum Mode {
        case add
        case edit(BazarrLanguageProfile)

        var title: String {
            switch self {
            case .add: return "New Profile"
            case .edit(let p): return p.name
            }
        }

        var saveLabel: String {
            switch self {
            case .add: "Add"
            case .edit: "Save"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let availableLanguages: [BazarrLanguage]
    let onSave: (LanguageProfileDraft) async -> Void

    @State private var draft: LanguageProfileDraft
    @State private var isSaving = false
    @State private var languagePickerPresented = false
    @State private var newMustContain = ""
    @State private var newMustNotContain = ""

    init(mode: Mode, availableLanguages: [BazarrLanguage], onSave: @escaping (LanguageProfileDraft) async -> Void) {
        self.mode = mode
        self.availableLanguages = availableLanguages
        self.onSave = onSave
        switch mode {
        case .add:
            _draft = State(initialValue: LanguageProfileDraft())
        case .edit(let profile):
            _draft = State(initialValue: LanguageProfileDraft(from: profile, availableLanguages: availableLanguages))
        }
    }

    private var alreadyAddedCodes: Set<String> {
        Set(draft.items.map(\.language))
    }

    var body: some View {
        AppSheetShell(
            title: mode.title,
            confirmTitle: mode.saveLabel,
            isConfirmDisabled: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } }
        ) {
            editorContent
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        Form {
            Section("Profile") {
                LabeledContent("Name") {
                    TextField("Profile Name", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                ForEach($draft.items) { $item in
                    HStack(spacing: 8) {
                        Text(BazarrLanguageProfileSupport.displayName(for: item.language, availableLanguages: availableLanguages))
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Menu {
                            ForEach(LanguageSubtitleVariant.allCases) { variant in
                                Button {
                                    item.hi = variant.hi
                                    item.forced = variant.forced
                                } label: {
                                    if variant == LanguageSubtitleVariant(hi: item.hi, forced: item.forced) {
                                        Label(variant.title, systemImage: "checkmark")
                                    } else {
                                        Text(variant.title)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(LanguageSubtitleVariant(hi: item.hi, forced: item.forced).shortTitle)
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8).weight(.bold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                        .accessibilityValue(LanguageSubtitleVariant(hi: item.hi, forced: item.forced).title)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { draft.items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { draft.items.remove(atOffsets: $0) }

                Button {
                    languagePickerPresented = true
                } label: {
                    Label("Add Language", systemImage: "plus.circle.fill")
                        .foregroundStyle(MoreDestinationAccent.languageProfiles.color)
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("Drag to reorder. Bazarr searches languages in order.")
            }

            Section {
                HStack {
                    TextField("Add phrase", text: $newMustContain)
                    Button("Add") {
                        let trimmed = newMustContain.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        draft.mustContain.append(trimmed)
                        newMustContain = ""
                    }
                    .disabled(newMustContain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(MoreDestinationAccent.languageProfiles.color)
                }
                ForEach(draft.mustContain, id: \.self) { phrase in
                    Text(phrase)
                }
                .onDelete { draft.mustContain.remove(atOffsets: $0) }
            } header: {
                Text("Must Contain")
            } footer: {
                Text("Subtitle release info must include at least one of these phrases.")
            }

            Section {
                HStack {
                    TextField("Add phrase", text: $newMustNotContain)
                    Button("Add") {
                        let trimmed = newMustNotContain.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        draft.mustNotContain.append(trimmed)
                        newMustNotContain = ""
                    }
                    .disabled(newMustNotContain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(MoreDestinationAccent.languageProfiles.color)
                }
                ForEach(draft.mustNotContain, id: \.self) { phrase in
                    Text(phrase)
                }
                .onDelete { draft.mustNotContain.remove(atOffsets: $0) }
            } header: {
                Text("Must Not Contain")
            } footer: {
                Text("Subtitle release info must not include any of these phrases.")
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .sheet(isPresented: $languagePickerPresented) {
            LanguagePickerSheet(
                languages: availableLanguages,
                alreadyAdded: alreadyAddedCodes
            ) { code in
                draft.items.append(EditableLanguageItem(language: code, hi: false, forced: false))
                languagePickerPresented = false
            }
        }
    }

    private func save() async {
        isSaving = true
        await onSave(draft)
        isSaving = false
    }
}

// MARK: - Language Picker

private struct LanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let languages: [BazarrLanguage]
    let alreadyAdded: Set<String>
    let onSelect: (String) -> Void

    @State private var searchText = ""

    private var filtered: [BazarrLanguage] {
        let available = languages.filter { !alreadyAdded.contains($0.name) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return available }
        return available.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.code2.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        AppSheetShell(title: "Add Language") {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "All Languages Added" : "No Results",
                        systemImage: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass"
                    )
                } else {
                    List(filtered) { language in
                        Button {
                            onSelect(language.code2)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(language.name)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)
                                Text(language.code2.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                    .fixedSize()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .searchable(text: $searchText, prompt: "Search languages")
        }
    }
}
