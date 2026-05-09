import SwiftUI

struct SeerrIssueListView: View {
    let apiClient: SeerrAPIClient

    @State private var viewModel: SeerrIssueListViewModel
    @State private var errorAlert: ErrorAlertItem?

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
        self._viewModel = State(initialValue: SeerrIssueListViewModel(apiClient: apiClient))
    }

    var body: some View {
        Group {
            issueContentView
        }
        .background(backgroundGradient)
        .navigationTitle("Issue Management")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await viewModel.loadIfNeeded() }
        .refreshable { await viewModel.loadIssues() }
        .safeAreaInset(edge: .top) {
            SeerrIssueFilterPicker(filter: $viewModel.selectedFilter)
        }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Issue Load Failed", message: message)
            viewModel.clearError()
        }
    }

    @ViewBuilder
    private var issueContentView: some View {
        ArrLoadingErrorEmptyView(
            isLoading: viewModel.isLoading,
            error: nil,
            isEmpty: viewModel.issues.isEmpty,
            emptyTitle: "No Issues",
            emptyIcon: "checkmark.bubble",
            emptyDescription: "No issues match the current status filter.",
            onRetry: nil
        ) {
            List {
                Section {
                    ForEach(viewModel.issues) { issue in
                        NavigationLink {
                            SeerrIssueDetailView(issue: issue, apiClient: apiClient) { updatedIssue in
                                viewModel.refreshIssue(updatedIssue)
                            }
                        } label: {
                            SeerrIssueRow(issue: issue)
                        }
                    }

                    if viewModel.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task { await viewModel.loadMore() }
                    }
                } header: {
                    Text(viewModel.selectedFilter.rawValue)
                } footer: {
                    Text(issueCountText)
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#else
            .listStyle(.inset)
#endif
            .scrollContentBackground(.hidden)
        }
    }

    private var issueCountText: String {
        let count = viewModel.totalIssueCount
        return "\(count) \(count == 1 ? "issue" : "issues")"
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.2), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.orange.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }
}

private struct SeerrIssueFilterPicker: View {
    @Binding var filter: SeerrIssueFilter

    var body: some View {
        Picker("Status", selection: $filter) {
            ForEach(SeerrIssueFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.horizontal, 48)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct SeerrIssueRow: View {
    let issue: SeerrIssue

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: issue.media?.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "exclamationmark.bubble").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.media?.displayTitle ?? "Unknown Media")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let type = issue.issueKind {
                        Label(type.title, systemImage: type.symbolName)
                    }

                    if let dateText = issue.createdAtRelativeText {
                        Text(dateText)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let createdBy = issue.createdBy {
                        Text("Reported by \(createdBy.displayName)")
                            .lineLimit(1)
                    }

                    if issue.commentCount > 0 {
                        Text("\(issue.commentCount) \(issue.commentCount == 1 ? "comment" : "comments")")
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let status = issue.issueStatus {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status == .resolved ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(status == .resolved ? Color.green : Color.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
