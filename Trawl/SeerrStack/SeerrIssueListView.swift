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
        List {
            Section {
                Picker("Status", selection: $viewModel.selectedFilter) {
                    ForEach(SeerrIssueFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                if !viewModel.issues.isEmpty {
                    Text("\(viewModel.totalIssueCount) issues")
                }
            }

            if viewModel.isLoading && viewModel.issues.isEmpty {
                Section {
                    ProgressView("Loading issues...")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if viewModel.issues.isEmpty {
                Section {
                    ContentUnavailableView("No Issues", systemImage: "checkmark.bubble", description: Text("No issues match the current status filter."))
                }
            } else {
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
                    Text("Issues")
                }
            }
        }
        .navigationTitle("Issue Management")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .modifier(SeerrIssueSubtitleModifier(subtitle: viewModel.issues.isEmpty ? nil : "\(viewModel.totalIssueCount) issues"))
        .task { await viewModel.loadIfNeeded() }
        .refreshable { await viewModel.loadIssues() }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Issue Load Failed", message: message)
            viewModel.clearError()
        }
    }
}

private struct SeerrIssueSubtitleModifier: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        if let subtitle {
            #if os(iOS) || os(macOS)
            // macOS/iOS may not support navigationSubtitle natively in the same way, we can use toolbar
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack {
                        Text("Issue Management").font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            #else
            content
            #endif
        } else {
            content
        }
    }
}

private struct SeerrIssueRow: View {
    let issue: SeerrIssue

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: issue.media?.posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.media?.displayTitle ?? "Unknown Media")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let type = issue.issueKind {
                        Label(type.title, systemImage: type.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let status = issue.issueStatus {
                        Text(status.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(status == .resolved ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(status == .resolved ? Color.green : Color.orange)
                    }
                }

                HStack(spacing: 8) {
                    if let createdBy = issue.createdBy {
                        Text("Reported by \(createdBy.displayName)")
                            .lineLimit(1)
                    }

                    if let dateText = issue.createdAtRelativeText {
                        Text(dateText)
                            .lineLimit(1)
                    }

                    if issue.commentCount > 0 {
                        Text("\(issue.commentCount) comments")
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
