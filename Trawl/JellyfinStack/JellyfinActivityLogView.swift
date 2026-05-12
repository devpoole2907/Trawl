import SwiftUI

// MARK: - View

struct JellyfinActivityLogView: View {
    let apiClient: JellyfinAPIClient

    @State private var viewModel: JellyfinActivityLogViewModel?
    @State private var userNames: [String: String] = [:]

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
            } else {
                Section {
                    ForEach(viewModel.entries) { entry in
                        activityRow(entry)
                            .task {
                                if entry.id == viewModel.entries.last?.id {
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
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .refreshable {
            await viewModel.load()
            await loadUserNames()
        }
    }

    @ViewBuilder
    private func activityRow(_ entry: JellyfinActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.severityIcon)
                    .font(.caption2)
                    .foregroundStyle(severityColor(entry.severity))

                Text(entry.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(formattedDate(entry.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let overview = entry.shortOverview ?? entry.overview, !overview.isEmpty {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let type = entry.type, !type.isEmpty {
                HStack(spacing: 4) {
                    Text(type)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))

                    if let userId = entry.userId, let name = userNames[userId] {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if entry.userId != nil {
                        Text(entry.userId ?? "")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func severityColor(_ severity: String?) -> Color {
        switch severity?.lowercased() {
        case "error", "fatal": .red
        case "warning", "warn": .orange
        default: .secondary
        }
    }

    private func formattedDate(_ raw: String) -> String {
        // Jellyfin returns ISO 8601. Truncate to a shorter form for display.
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
