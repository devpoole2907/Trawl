import SwiftUI

struct SeerrIssueListView: View {
    let apiClient: SeerrAPIClient

    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(SeerrIssueBrowserState.self) private var sharedBrowser: SeerrIssueBrowserState?
    @State private var localBrowser = SeerrIssueBrowserState()
    private var browser: SeerrIssueBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var viewModel: SeerrIssueListViewModel? { browser.viewModel }
    private var selectedIssueID: Int? { browser.selectedIssueID }
    @State private var issueSearchText = ""
    @State private var isSearchExpanded = false

    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var seerrClientID: ObjectIdentifier {
        ObjectIdentifier(apiClient)
    }

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        Group {
            if let viewModel {
                TrawlListDetailPanes(title: "Issues", subtitle: "Seerr") {
                    issueList(viewModel: viewModel)
                } detail: {
                    selectedIssueDetail(viewModel: viewModel)
                }
            } else if sidebarColumn == .detail {
                listDetailPlaceholder("Select an Issue", systemImage: "exclamationmark.bubble")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: seerrClientID) {
            guard sidebarColumn != .detail else { return }
            if browser.viewModel == nil || browser.viewModelSeerrClientID != seerrClientID {
                browser.viewModel = SeerrIssueListViewModel(apiClient: apiClient)
                browser.viewModelSeerrClientID = seerrClientID
                await browser.viewModel?.loadIfNeeded()
            } else {
                await browser.viewModel?.loadIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func issueRow(
        _ issue: SeerrIssue,
        viewModel: SeerrIssueListViewModel
    ) -> some View {
        if showsDetailPane {
            SeerrIssueRow(issue: issue)
                .tag(issue.id)
        } else {
            NavigationLink {
                issueDetail(issue, viewModel: viewModel)
            } label: {
                SeerrIssueRow(issue: issue)
            }
        }
    }

    @ViewBuilder
    private func selectedIssueDetail(viewModel: SeerrIssueListViewModel) -> some View {
        if let id = selectedIssueID,
           let issue = (viewModel.issues + viewModel.searchIssues).first(where: { $0.id == id }) {
            issueDetail(issue, viewModel: viewModel)
                .id(issue.id)
        } else {
            listDetailPlaceholder("Select an Issue", systemImage: "exclamationmark.bubble")
        }
    }

    private func issueDetail(_ issue: SeerrIssue, viewModel: SeerrIssueListViewModel) -> some View {
        SeerrIssueDetailView(issue: issue, apiClient: apiClient) { updatedIssue in
            viewModel.refreshIssue(updatedIssue)
        }
    }

    @ViewBuilder
    private func issueList(viewModel: SeerrIssueListViewModel) -> some View {
        let query = issueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredIssues = query.isEmpty ? viewModel.issues : filteredSearchIssues(matching: query, in: viewModel)

        @Bindable var browser = self.browser
        List(selection: $browser.selectedIssueID) {
            if let errorMessage = viewModel.errorMessage {
                ServiceErrorView(
                    title: "Issues Unavailable",
                    message: errorMessage,
                    identity: .seerr,
                    hasContent: !viewModel.issues.isEmpty,
                    onRetry: { await viewModel.loadIssues() }
                )
            }

            if viewModel.isLoading && viewModel.issues.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if !query.isEmpty && viewModel.isLoadingSearch && viewModel.searchIssues.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if query.isEmpty && viewModel.issues.isEmpty {
                if viewModel.errorMessage == nil {
                    ContentUnavailableView(
                        "No Issues",
                        systemImage: "checkmark.bubble",
                        description: Text("No issues match the current status filter.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else if filteredIssues.isEmpty {
                if viewModel.errorMessage == nil {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
            } else {
                if query.isEmpty {
                    Section {
                        ForEach(viewModel.issues) { issue in
                            issueRow(issue, viewModel: viewModel)
                        }

                        if viewModel.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .task { await viewModel.loadMore() }
                        }
                    } header: {
                        Text(viewModel.selectedFilter.rawValue)
                    } footer: {
                        Text(issueCountText(for: viewModel))
                    }
                } else {
                    ForEach(issueSearchSections(matching: query, in: viewModel)) { section in
                        Section(section.title) {
                            ForEach(section.issues) { issue in
                                issueRow(issue, viewModel: viewModel)
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
        .refreshable { await viewModel.loadIssues() }
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar("Status", selection: Binding(
                get: { viewModel.selectedFilter },
                set: { newFilter in withAnimation { viewModel.selectedFilter = newFilter } }
            ),
            items: SeerrIssueFilter.allCases.map(\.segmentBarItem),
            searchText: $issueSearchText,
            searchHint: "Search issues",
            isSearchExpanded: $isSearchExpanded,
            searchPlacement: .leading,
            alignment: .leading)
            .clipped()
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .onChange(of: issueSearchText) { _, newValue in
            Task { await viewModel.updateSearchIssues(for: newValue) }
        }
    }

    private func filteredSearchIssues(matching query: String, in viewModel: SeerrIssueListViewModel) -> [SeerrIssue] {
        viewModel.searchIssues.filter { $0.matchesIssueSearch(query) }
    }

    private func issueSearchSections(matching query: String, in viewModel: SeerrIssueListViewModel) -> [IssueSearchSection] {
        let matches = filteredSearchIssues(matching: query, in: viewModel)
        return SeerrIssueFilter.allCases.compactMap { filter in
            let issues = matches.filter { $0.issueStatus == filter.issueStatus }
            guard !issues.isEmpty else { return nil }
            return IssueSearchSection(title: filter.rawValue, issues: issues)
        }
    }

    private func issueCountText(for viewModel: SeerrIssueListViewModel) -> String {
        let count = viewModel.totalIssueCount
        return "\(count) \(count == 1 ? "issue" : "issues")"
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
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

private struct IssueSearchSection: Identifiable {
    let title: String
    let issues: [SeerrIssue]

    var id: String { title }
}

private extension SeerrIssueFilter {
    var issueStatus: SeerrIssueStatus {
        switch self {
        case .open: .open
        case .resolved: .resolved
        }
    }
}

private extension SeerrIssue {
    func matchesIssueSearch(_ query: String) -> Bool {
        [
            media?.displayTitle,
            createdBy?.displayName,
            modifiedBy?.displayName,
            issueKind?.title,
            issueStatus?.title
        ].contains { $0?.localizedCaseInsensitiveContains(query) == true } ||
        comments?.contains { $0.message.localizedCaseInsensitiveContains(query) } == true
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
            .clipShape(RoundedRectangle(cornerRadius: 8))

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

#if DEBUG
extension SeerrIssueListView {
    init(
        apiClient: SeerrAPIClient = .preview(),
        previewViewModel: SeerrIssueListViewModel
    ) {
        self.apiClient = apiClient
        let browser = SeerrIssueBrowserState()
        browser.viewModel = previewViewModel
        self._localBrowser = State(initialValue: browser)
    }
}

#Preview("Seerr Issues - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrIssueListView(
                previewViewModel: SeerrIssueListViewModel(previewIssues: SeerrIssue.previewList)
            )
        }
    }
}

#Preview("Seerr Issues - Loaded Heavy") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrIssueListView(
                previewViewModel: SeerrIssueListViewModel(
                    previewIssues: SeerrIssue.previewHeavyList,
                    totalResults: SeerrIssue.previewHeavyList.count
                )
            )
        }
    }
}

#Preview("Seerr Issues - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrIssueListView(
                previewViewModel: SeerrIssueListViewModel(previewIssues: [])
            )
        }
    }
}

#Preview("Seerr Issues - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        NavigationStack {
            SeerrIssueListView(
                previewViewModel: SeerrIssueListViewModel(previewIssues: [], isLoading: true)
            )
        }
    }
}

#Preview("Seerr Issues - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to load issues."))) {
        NavigationStack {
            SeerrIssueListView(
                previewViewModel: SeerrIssueListViewModel(
                    previewIssues: [],
                    errorMessage: "Issue list endpoint returned 500."
                )
            )
        }
    }
}
#endif
