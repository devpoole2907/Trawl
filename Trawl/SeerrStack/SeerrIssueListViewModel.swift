import Foundation
import Observation

enum SeerrIssueFilter: String, CaseIterable, Identifiable {
    case open = "Open"
    case resolved = "Resolved"

    var id: String { rawValue }

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }

    var apiValue: String {
        switch self {
        case .open: "open"
        case .resolved: "resolved"
        }
    }
}

@MainActor
@Observable
final class SeerrIssueListViewModel {
    private(set) var issues: [SeerrIssue] = []
    private(set) var searchIssues: [SeerrIssue] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isLoadingSearch = false
    private(set) var errorMessage: String?
    var selectedFilter: SeerrIssueFilter = .open {
        didSet {
            if selectedFilter != oldValue {
                requestVersion += 1
                currentSkip = 0
                Task { await loadIssues() }
            }
        }
    }

    private let apiClient: SeerrAPIClient
    private let pageSize = 20
    private var currentSkip = 0
    private var totalResults = 0
    private var hasLoaded = false
    private var requestVersion = 0
    private var searchVersion = 0
    private var hasLoadedAllIssuesForSearch = false

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var hasMore: Bool {
        currentSkip + pageSize < totalResults
    }

    var totalIssueCount: Int {
        max(totalResults, issues.count)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadIssues()
    }

    func updateSearchIssues(for searchText: String) async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            searchVersion += 1
            isLoadingSearch = false
            searchIssues = []
            hasLoadedAllIssuesForSearch = false
            return
        }

        guard !hasLoadedAllIssuesForSearch, !isLoadingSearch else { return }

        searchVersion += 1
        let capturedVersion = searchVersion
        isLoadingSearch = true
        defer {
            if capturedVersion == searchVersion {
                isLoadingSearch = false
            }
        }

        do {
            let loadedIssues = try await loadAllIssuesForSearch()
            guard capturedVersion == searchVersion else { return }
            searchIssues = loadedIssues
            hasLoadedAllIssuesForSearch = true
        } catch {
            guard capturedVersion == searchVersion else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadIssues() async {
        requestVersion += 1
        let capturedVersion = requestVersion
        isLoading = true
        errorMessage = nil
        currentSkip = 0

        do {
            let response = try await apiClient.getIssues(
                take: pageSize,
                skip: 0,
                sort: "added",
                filter: selectedFilter.apiValue
            )
            guard capturedVersion == requestVersion else { return }
            issues = response.results
            totalResults = response.pageInfo.results ?? response.results.count
            hasLoaded = true
        } catch {
            guard capturedVersion == requestVersion else { return }
            errorMessage = error.localizedDescription
        }

        guard capturedVersion == requestVersion else { return }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        let capturedVersion = requestVersion
        isLoadingMore = true
        let nextSkip = currentSkip + pageSize

        do {
            let response = try await apiClient.getIssues(
                take: pageSize,
                skip: nextSkip,
                sort: "added",
                filter: selectedFilter.apiValue
            )
            guard capturedVersion == requestVersion else {
                isLoadingMore = false
                return
            }
            let existingIds = Set(issues.map(\.id))
            let newIssues = response.results.filter { !existingIds.contains($0.id) }
            issues.append(contentsOf: newIssues)
            currentSkip = nextSkip
            totalResults = response.pageInfo.results ?? totalResults
            isLoadingMore = false
        } catch {
            guard capturedVersion == requestVersion else {
                isLoadingMore = false
                return
            }
            errorMessage = error.localizedDescription
            isLoadingMore = false
        }
    }

    func refreshIssue(_ issue: SeerrIssue) {
        if let index = issues.firstIndex(where: { $0.id == issue.id }) {
            issues[index] = issue
        }
        if let index = searchIssues.firstIndex(where: { $0.id == issue.id }) {
            searchIssues[index] = issue
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadAllIssuesForSearch() async throws -> [SeerrIssue] {
        var loaded: [SeerrIssue] = []
        for filter in SeerrIssueFilter.allCases {
            loaded.append(contentsOf: try await loadAllIssues(filter: filter))
        }
        return loaded.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func loadAllIssues(filter: SeerrIssueFilter) async throws -> [SeerrIssue] {
        let searchPageSize = 100
        var skip = 0
        var total = Int.max
        var loaded: [SeerrIssue] = []

        while skip < total {
            let response = try await apiClient.getIssues(
                take: searchPageSize,
                skip: skip,
                sort: "added",
                filter: filter.apiValue
            )
            loaded.append(contentsOf: response.results)
            total = response.pageInfo.results ?? loaded.count
            guard !response.results.isEmpty else { break }
            skip += searchPageSize
        }

        return loaded
    }
}

#if DEBUG
extension SeerrIssueListViewModel {
    convenience init(
        previewIssues: [SeerrIssue],
        isLoading: Bool = false,
        isLoadingMore: Bool = false,
        errorMessage: String? = nil,
        selectedFilter: SeerrIssueFilter = .open,
        totalResults: Int? = nil,
        apiClient: SeerrAPIClient = .preview()
    ) {
        self.init(apiClient: apiClient)
        self.issues = previewIssues
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
        self.errorMessage = errorMessage
        self.selectedFilter = selectedFilter
        self.totalResults = totalResults ?? previewIssues.count
        self.hasLoaded = true
    }
}
#endif
