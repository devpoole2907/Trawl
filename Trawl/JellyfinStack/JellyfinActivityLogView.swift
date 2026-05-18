import SwiftUI

// MARK: - View

struct JellyfinActivityLogView: View {
    let apiClient: JellyfinAPIClient

    @State private var viewModel: JellyfinActivityLogViewModel?
    @State private var userNames: [String: String] = [:]
    @State private var selectedTypeFilter: JellyfinActivityTypeFilter = .all
    @State private var searchText = ""
    @State private var isSearchExpanded = false

    var body: some View {
        Group {
            if let viewModel {
                activityContent(viewModel)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Activity Log")
        .task {
            let vm = JellyfinActivityLogViewModel(apiClient: apiClient)
            viewModel = vm
            await vm.load()
            await loadUserNames()
        }
    }

    @ViewBuilder
    private func activityContent(_ viewModel: JellyfinActivityLogViewModel) -> some View {
        let entries = filteredEntries(from: viewModel.entries)

        List {
            if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isLoading && viewModel.entries.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("No activity log entries were returned by Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        JellyfinActivityRow(entry: entry, userNames: userNames)
                            .task {
                                if selectedTypeFilter == .all,
                                   searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   entry.id == viewModel.entries.last?.id {
                                    await viewModel.loadMore()
                                    await loadUserNames()
                                }
                            }
                    }

                    if viewModel.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
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
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .refreshable {
            await viewModel.load()
            await loadUserNames()
        }
        .safeAreaInset(edge: .top) {
            if !viewModel.entries.isEmpty {
                TrawlSegmentBar(
                    "Activity Type",
                    selection: Binding(
                        get: { selectedTypeFilter },
                        set: { newFilter in withAnimation { selectedTypeFilter = newFilter } }
                    ),
                    items: segmentItems(for: viewModel.entries),
                    searchText: $searchText,
                    searchHint: "Search activity",
                    isSearchExpanded: $isSearchExpanded,
                    searchPlacement: .leading,
                    alignment: .leading
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func segmentItems(for entries: [JellyfinActivityEntry]) -> [TrawlSegmentBarItem<JellyfinActivityTypeFilter>] {
        let types = Set(entries.compactMap { entry -> String? in
            guard let type = entry.type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return nil }
            return type
        })

        return [TrawlSegmentBarItem("All", value: .all)] +
            types.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { TrawlSegmentBarItem($0, value: .type($0)) }
    }

    private func filteredEntries(from entries: [JellyfinActivityEntry]) -> [JellyfinActivityEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return entries.filter { entry in
            if case .type(let selectedType) = selectedTypeFilter,
               entry.type?.caseInsensitiveCompare(selectedType) != .orderedSame {
                return false
            }

            guard !query.isEmpty else { return true }

            return entry.name.localizedCaseInsensitiveContains(query) ||
                (entry.type ?? "").localizedCaseInsensitiveContains(query) ||
                (entry.shortOverview ?? "").localizedCaseInsensitiveContains(query) ||
                (entry.overview ?? "").localizedCaseInsensitiveContains(query) ||
                (entry.userId.flatMap { userNames[$0] } ?? entry.userId ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func loadUserNames() async {
        do {
            let users = try await apiClient.getUsers()
            var names: [String: String] = [:]
            for user in users {
                names[user.id] = user.name
            }
            userNames = names
        } catch {
            // Non-fatal: entries still render with raw userId
        }
    }
}

private enum JellyfinActivityTypeFilter: Hashable {
    case all
    case type(String)
}

// MARK: - Activity Row

private struct JellyfinActivityRow: View {
    let entry: JellyfinActivityEntry
    let userNames: [String: String]

    var body: some View {
        LogEntryRow(
            message: entry.name,
            timestamp: formattedDate(entry.date)
        ) {
            if let type = entry.type, !type.isEmpty {
                Text(type)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeTint(for: type).opacity(0.16), in: Capsule())
                    .foregroundStyle(typeTint(for: type))
            }

            if let userName {
                Text(userName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } secondary: {
            if let overview = entry.shortOverview ?? entry.overview, !overview.isEmpty {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var userName: String? {
        guard let userId = entry.userId else { return nil }
        return userNames[userId] ?? userId
    }

    private func typeTint(for type: String) -> Color {
        let normalized = type.lowercased()

        if normalized.contains("failed") || normalized.contains("error") || normalized.contains("denied") {
            return .red
        }
        if normalized.contains("warning") || normalized.contains("transcode") {
            return .orange
        }
        if normalized.contains("started") || normalized.contains("play") || normalized.contains("login") {
            return .green
        }
        if normalized.contains("ended") || normalized.contains("stopped") || normalized.contains("logout") {
            return .secondary
        }
        if normalized.contains("user") || normalized.contains("auth") {
            return .blue
        }
        if normalized.contains("library") || normalized.contains("item") || normalized.contains("scan") {
            return ServiceIdentity.jellyfin.brandColor
        }
        if normalized.contains("task") || normalized.contains("plugin") {
            return .purple
        }
        return ServiceIdentity.jellyfin.brandColor
    }

    private func formattedDate(_ raw: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class JellyfinActivityLogViewModel {
    private(set) var entries: [JellyfinActivityEntry] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    private let apiClient: JellyfinAPIClient
    private let pageSize = 50
    private var totalRecords = 0
    private var hasLoaded = false
    private var loadMoreFailed = false

    var hasMore: Bool { !loadMoreFailed && entries.count < totalRecords }

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        loadMoreFailed = false
        do {
            let response = try await apiClient.getActivityLog(startIndex: 0, limit: pageSize)
            entries = response.items
            totalRecords = response.totalRecordCount
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let response = try await apiClient.getActivityLog(startIndex: entries.count, limit: pageSize)
            entries.append(contentsOf: response.items)
            totalRecords = response.totalRecordCount
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}
