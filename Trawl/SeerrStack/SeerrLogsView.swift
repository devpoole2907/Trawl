import SwiftUI

struct SeerrLogsView: View {
    let apiClient: SeerrAPIClient

    @State private var entries: [SeerrServerLogEntry] = []
    @State private var level: SeerrLogLevelFilter = .debug
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEntry: SeerrServerLogEntry?
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        List {
            if let errorMessage {
                Section("Unavailable") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && entries.isEmpty {
                Section("Logs") {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No Seerr Logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("No server log entries were returned by Seerr.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Logs") {
                    ForEach(entries) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            SeerrLogRow(entry: entry)
                        }
                        .buttonStyle(.plain)
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
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .navigationTitle("Seerr Logs")
        .searchable(text: $searchText, prompt: "Search logs")
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                SeerrLogLevelMenu(level: $level)
            }
        }
        .refreshable { await loadLogs() }
        .task(id: "\(level.apiValue)|\(committedSearchText)") {
            await loadLogs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await loadLogs(showLoading: false)
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                committedSearchText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .sheet(item: $selectedEntry) { entry in
            SeerrLogDetailSheet(entry: entry)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func loadLogs(showLoading: Bool = true) async {
        if showLoading {
            isLoading = true
        }
        errorMessage = nil

        do {
            entries = try await apiClient.getLogs(
                take: 100,
                filter: level.apiValue,
                search: committedSearchText
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private struct SeerrLogLevelMenu: View {
    @Binding var level: SeerrLogLevelFilter

    var body: some View {
        Menu {
            Picker("Log Level", selection: Binding(
                get: { level },
                set: { withAnimation { level = $0 } }
            )) {
                ForEach(SeerrLogLevelFilter.allCases) { option in
                    Label(option.rawValue, systemImage: option.iconName).tag(option)
                }
            }
        } label: {
            Image(systemName: level == .debug
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

private extension SeerrLogLevelFilter {
    var iconName: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

struct SeerrLogRow: View {
    let entry: SeerrServerLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.level?.uppercased() ?? "LOG")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelTint.opacity(0.16), in: Capsule())
                    .foregroundStyle(levelTint)

                if let label = entry.label, !label.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let date = entry.timestampDate {
                    Text(date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(entry.message ?? "No message")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var levelTint: Color {
        switch entry.level?.lowercased() {
        case "error": .red
        case "warn", "warning": .orange
        case "info": .blue
        default: .secondary
        }
    }
}

private struct SeerrLogDetailSheet: View {
    let entry: SeerrServerLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Timestamp") {
                    Text(timestampText)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                Section("Severity") {
                    HStack(spacing: 8) {
                        Image(systemName: severityIcon)
                            .foregroundStyle(severityTint)
                        Text(entry.level?.uppercased() ?? "LOG")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(severityTint)
                    }
                }

                if let label = entry.label, !label.isEmpty {
                    Section("Label") {
                        Text(label)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }

                Section("Message") {
                    Text(entry.message ?? "No message")
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                if let prettyData = entry.prettyPrintedData {
                    Section("Additional Data") {
                        Text(prettyData)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Log Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private var timestampText: String {
        if let date = entry.timestampDate {
            return date.formatted(date: .long, time: .standard)
        }
        return entry.timestamp ?? "Unknown"
    }

    private var severityIcon: String {
        switch entry.level?.lowercased() {
        case "error": return "xmark.octagon.fill"
        case "warn", "warning": return "exclamationmark.triangle.fill"
        case "info": return "info.circle.fill"
        default: return "ant.fill"
        }
    }

    private var severityTint: Color {
        switch entry.level?.lowercased() {
        case "error": return .red
        case "warn", "warning": return .orange
        case "info": return .blue
        default: return .secondary
        }
    }
}
