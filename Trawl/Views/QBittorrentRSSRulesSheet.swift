import SwiftUI

struct QBittorrentRSSRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var appServices

    let feedURLs: [String]

    @State private var rules: [String: QBittorrentRSSRule] = [:]
    @State private var isLoading = false
    @State private var actionErrorAlert: ErrorAlertItem?
    @State private var rulePendingDeletion: String?
    @State private var newRuleDestination: NewRuleDestination?
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init(feedURLs: [String]) {
        self.feedURLs = feedURLs
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && rules.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rules.isEmpty {
                    ContentUnavailableView(
                        "No Auto-Download Rules",
                        systemImage: "wand.and.stars",
                        description: Text("Add a rule to automatically download matching torrents from your feeds.")
                    )
                } else {
                    List {
                        ForEach(sortedRuleNames, id: \.self) { name in
                            NavigationLink {
                                ruleEditor(for: name)
                            } label: {
                                RuleRow(name: name, rule: rules[name])
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    rulePendingDeletion = name
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle("Auto-Download Rules")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newRuleDestination = NewRuleDestination()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $newRuleDestination) { _ in
                QBittorrentRSSRuleEditorView(
                    mode: .create,
                    initialRule: QBittorrentRSSRule(),
                    feedURLs: feedURLs,
                    existingRuleNames: Set(rules.keys),
                    onSave: { name, rule in
                        try await saveRule(name: name, rule: rule)
                    }
                )
            }
            .alert("Delete Rule?", isPresented: deleteAlertBinding) {
                Button("Delete", role: .destructive) {
                    guard let rulePendingDeletion else { return }
                    Task { await deleteRule(rulePendingDeletion) }
                }
                Button("Cancel", role: .cancel) {
                    rulePendingDeletion = nil
                }
            } message: {
                Text("This removes the auto-download rule \"\(rulePendingDeletion ?? "")\" from qBittorrent.")
            }
            .errorAlert(item: $actionErrorAlert)
            .task {
                #if DEBUG
                guard !skipsAutomaticLoading else { return }
                #endif
                await loadRules()
            }
            .refreshable {
                await loadRules()
            }
        }
    }

    @ViewBuilder
    private func ruleEditor(for name: String) -> some View {
        if let rule = rules[name] {
            QBittorrentRSSRuleEditorView(
                mode: .edit(name: name),
                initialRule: rule,
                feedURLs: feedURLs,
                existingRuleNames: Set(rules.keys),
                onSave: { savedName, savedRule in
                    try await saveRule(name: savedName, rule: savedRule)
                }
            )
        } else {
            ContentUnavailableView("Rule Unavailable", systemImage: "exclamationmark.triangle")
        }
    }

    private var sortedRuleNames: [String] {
        rules.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { rulePendingDeletion != nil },
            set: { if !$0 { rulePendingDeletion = nil } }
        )
    }

    private func loadRules() async {
        isLoading = true
        do {
            rules = try await appServices.apiClient.getRSSRules()
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Failed to Load Rules",
                message: error.localizedDescription
            )
        }
        isLoading = false
    }

    private func saveRule(name: String, rule: QBittorrentRSSRule) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(rule)
        guard let json = String(data: data, encoding: .utf8) else {
            throw QBError.invalidResponse
        }
        try await appServices.apiClient.setRSSRule(ruleName: name, ruleDef: json)
        await loadRules()
    }

    private func deleteRule(_ name: String) async {
        do {
            try await appServices.apiClient.removeRSSRule(ruleName: name)
            await loadRules()
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Failed to Delete Rule",
                message: error.localizedDescription
            )
        }
        rulePendingDeletion = nil
    }
}

// Wrapping the "new rule" navigation as an Identifiable lets `navigationDestination(item:)`
// push a fresh editor each time the user taps + without re-using stale state.
private struct NewRuleDestination: Identifiable, Hashable {
    let id = UUID()
}

private struct RuleRow: View {
    let name: String
    let rule: QBittorrentRSSRule?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(rule?.enabled == true ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard let rule, !rule.mustContain.isEmpty else { return "Must contain: —" }
        return "Must contain: \(rule.mustContain)"
    }
}

private enum RuleEditorMode: Hashable {
    case create
    case edit(name: String)
}

private struct QBittorrentRSSRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let mode: RuleEditorMode
    let feedURLs: [String]
    let existingRuleNames: Set<String>
    let onSave: (String, QBittorrentRSSRule) async throws -> Void

    @State private var name: String
    @State private var rule: QBittorrentRSSRule
    @State private var isSaving = false
    @State private var errorAlert: ErrorAlertItem?

    init(
        mode: RuleEditorMode,
        initialRule: QBittorrentRSSRule,
        feedURLs: [String],
        existingRuleNames: Set<String>,
        onSave: @escaping (String, QBittorrentRSSRule) async throws -> Void
    ) {
        self.mode = mode
        self.feedURLs = feedURLs
        self.existingRuleNames = existingRuleNames
        self.onSave = onSave
        switch mode {
        case .create:
            self._name = State(initialValue: "")
        case .edit(let name):
            self._name = State(initialValue: name)
        }
        self._rule = State(initialValue: initialRule)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var saveDisabled: Bool {
        if isSaving { return true }
        if isEditing { return false }
        if trimmedName.isEmpty { return true }
        return existingRuleNames.contains(trimmedName)
    }

    var body: some View {
        Form {
            Section("Rule") {
                if isEditing {
                    LabeledContent("Name", value: name)
                } else {
                    TextField("Rule name", text: $name)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        #endif
                }
            }

            Section("Status") {
                Toggle("Enabled", isOn: $rule.enabled)
            }

            Section {
                TextField("Must contain", text: $rule.mustContain)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
                TextField("Must not contain", text: $rule.mustNotContain)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
                Toggle("Use regex", isOn: $rule.useRegex)
                TextField("Episode filter", text: $rule.episodeFilter)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            } header: {
                Text("Match Rules")
            } footer: {
                Text("Episode filter uses qBittorrent's format, for example 1x01-; matches season 1 from episode 1 onward.")
            }

            Section("Behaviour") {
                Toggle("Smart filter (skip duplicates)", isOn: $rule.smartFilter)
                Stepper(value: $rule.ignoreDays, in: 0...365) {
                    HStack {
                        Text("Ignore for")
                        Spacer()
                        Text("\(rule.ignoreDays) day\(rule.ignoreDays == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Add paused", selection: addPausedBinding) {
                    Text("Default").tag(AddPausedOption.defaultOption)
                    Text("Yes").tag(AddPausedOption.yes)
                    Text("No").tag(AddPausedOption.no)
                }
                Picker("Content layout", selection: contentLayoutBinding) {
                    Text("Default").tag(ContentLayoutOption.defaultOption)
                    Text("Original").tag(ContentLayoutOption.original)
                    Text("Subfolder").tag(ContentLayoutOption.subfolder)
                    Text("No Subfolder").tag(ContentLayoutOption.noSubfolder)
                }
            }

            Section {
                TextField("Category", text: $rule.assignedCategory)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
                TextField("Save path", text: $rule.savePath)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            } header: {
                Text("Destination")
            } footer: {
                Text("Leave blank to use qBittorrent's defaults.")
            }

            Section {
                if feedURLs.isEmpty {
                    Text("No RSS feeds are configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(feedURLs, id: \.self) { url in
                        Toggle(isOn: feedBinding(for: url)) {
                            Text(url)
                                .font(.footnote)
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("Affected Feeds")
            } footer: {
                Text("The rule only matches items from feeds you select here.")
            }
        }
        .navigationTitle(isEditing ? "Edit Rule" : "New Rule")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(saveDisabled)
            }
        }
        .errorAlert(item: $errorAlert)
        .disabled(isSaving)
    }

    private func feedBinding(for url: String) -> Binding<Bool> {
        Binding(
            get: { rule.affectedFeeds.contains(url) },
            set: { included in
                if included {
                    if !rule.affectedFeeds.contains(url) {
                        rule.affectedFeeds.append(url)
                    }
                } else {
                    rule.affectedFeeds.removeAll { $0 == url }
                }
            }
        )
    }

    private var addPausedBinding: Binding<AddPausedOption> {
        Binding(
            get: {
                switch rule.addPaused {
                case .none: return .defaultOption
                case .some(true): return .yes
                case .some(false): return .no
                }
            },
            set: { option in
                switch option {
                case .defaultOption: rule.addPaused = nil
                case .yes: rule.addPaused = true
                case .no: rule.addPaused = false
                }
            }
        )
    }

    private var contentLayoutBinding: Binding<ContentLayoutOption> {
        Binding(
            get: { ContentLayoutOption(rawValue: rule.torrentContentLayout) },
            set: { option in rule.torrentContentLayout = option.payloadValue }
        )
    }

    private func save() async {
        let saveName = isEditing ? name : trimmedName
        guard !saveName.isEmpty else { return }
        isSaving = true
        do {
            try await onSave(saveName, rule)
            dismiss()
        } catch {
            errorAlert = ErrorAlertItem(
                title: "Failed to Save Rule",
                message: error.localizedDescription
            )
        }
        isSaving = false
    }
}

private enum AddPausedOption: Hashable {
    case defaultOption
    case yes
    case no
}

private enum ContentLayoutOption: Hashable {
    case defaultOption
    case original
    case subfolder
    case noSubfolder

    init(rawValue: String?) {
        switch rawValue {
        case "Original": self = .original
        case "Subfolder": self = .subfolder
        case "NoSubfolder": self = .noSubfolder
        default: self = .defaultOption
        }
    }

    var payloadValue: String? {
        switch self {
        case .defaultOption: return nil
        case .original: return "Original"
        case .subfolder: return "Subfolder"
        case .noSubfolder: return "NoSubfolder"
        }
    }
}

#if DEBUG
extension QBittorrentRSSRulesSheet {
    init(
        previewRules: [String: QBittorrentRSSRule],
        feedURLs: [String] = [
            "https://releases.ubuntu.com/rss.xml",
            "https://tracker.example.org/movies/rss"
        ],
        isLoading: Bool = false,
        actionErrorAlert: ErrorAlertItem? = nil
    ) {
        self.init(feedURLs: feedURLs)
        self._rules = State(initialValue: previewRules)
        self._isLoading = State(initialValue: isLoading)
        self._actionErrorAlert = State(initialValue: actionErrorAlert)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Loaded") {
    PreviewHost(profiles: .qBittorrentOnly) {
        QBittorrentRSSRulesSheet(previewRules: [
            "Ubuntu Daily": QBittorrentRSSRule(
                enabled: true,
                mustContain: "ubuntu 24.04",
                useRegex: false,
                affectedFeeds: ["https://releases.ubuntu.com/rss.xml"],
                assignedCategory: "linux"
            ),
            "Documentaries": QBittorrentRSSRule(
                enabled: false,
                mustContain: "1080p",
                affectedFeeds: ["https://tracker.example.org/movies/rss"]
            )
        ])
    }
}

#Preview("Empty") {
    PreviewHost(profiles: .qBittorrentOnly) {
        QBittorrentRSSRulesSheet(previewRules: [:])
    }
}

#Preview("Loading") {
    PreviewHost(profiles: .qBittorrentOnly) {
        QBittorrentRSSRulesSheet(previewRules: [:], isLoading: true)
    }
}

#Preview("Error") {
    PreviewHost(profiles: .qBittorrentOnly) {
        QBittorrentRSSRulesSheet(
            previewRules: [:],
            actionErrorAlert: ErrorAlertItem(
                title: "Failed to Load Rules",
                message: "qBittorrent returned 403 Forbidden."
            )
        )
    }
}
#endif
