import Foundation
import Observation

enum SeerrIssueFilter: String, CaseIterable, Identifiable {
    case open = "Open"
    case resolved = "Resolved"

    var id: String { rawValue }

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
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
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
    }

    func clearError() {
        errorMessage = nil
    }
}
