import Foundation
import Observation

@MainActor
@Observable
final class SeerrUserManagementViewModel {
    private(set) var users: [SeerrUser] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isImporting = false
    private(set) var errorMessage: String?

    private let apiClient: SeerrAPIClient
    private weak var serviceManager: SeerrServiceManager?
    private let pageSize = 20
    private var totalResults = 0
    private var hasLoaded = false

    init(apiClient: SeerrAPIClient, serviceManager: SeerrServiceManager? = nil) {
        self.apiClient = apiClient
        self.serviceManager = serviceManager
    }

    var hasMore: Bool {
        users.count < totalResults
    }

    var totalUserCount: Int {
        max(totalResults, users.count)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadUsers()
    }

    func loadUsers() async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await apiClient.getUsers(take: pageSize, skip: 0)
            users = response.results
            totalResults = response.pageInfo.results ?? response.results.count
            hasLoaded = true
            serviceManager?.updateCachedUserCount(totalResults)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let skip = users.count

        do {
            let response = try await apiClient.getUsers(take: pageSize, skip: skip)
            users.append(contentsOf: response.results)
            totalResults = response.pageInfo.results ?? totalResults
            serviceManager?.updateCachedUserCount(totalResults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importJellyfinUsers(ids: [String]) async {
        guard !ids.isEmpty else { return }
        isImporting = true
        errorMessage = nil

        do {
            _ = try await apiClient.importUsersFromJellyfin(jellyfinUserIds: ids)
            await loadUsers()
        } catch {
            errorMessage = error.localizedDescription
        }

        isImporting = false
    }

    func deleteUser(_ user: SeerrUser) async {
        do {
            try await apiClient.deleteUser(id: user.id)
            users.removeAll { $0.id == user.id }
            totalResults = max(0, totalResults - 1)
            serviceManager?.updateCachedUserCount(totalResults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyUpdatedUser(_ user: SeerrUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
