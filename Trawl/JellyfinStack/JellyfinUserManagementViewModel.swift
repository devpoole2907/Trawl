import Foundation
import Observation

@MainActor
@Observable
final class JellyfinUserManagementViewModel {
    private(set) var users: [JellyfinUser] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let apiClient: JellyfinAPIClient
    private weak var serviceManager: JellyfinServiceManager?
    private var hasLoaded = false

    init(apiClient: JellyfinAPIClient, serviceManager: JellyfinServiceManager? = nil) {
        self.apiClient = apiClient
        self.serviceManager = serviceManager
    }

    var totalUserCount: Int { users.count }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadUsers()
    }

    func loadUsers() async {
        isLoading = true
        errorMessage = nil

        do {
            users = try await apiClient.getUsers()
            hasLoaded = true
            serviceManager?.updateCachedUserCount(users.count)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func deleteUser(_ user: JellyfinUser) async {
        do {
            try await apiClient.deleteUser(id: user.id)
            users.removeAll { $0.id == user.id }
            serviceManager?.updateCachedUserCount(users.count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createUser(name: String, password: String?) async throws -> JellyfinUser {
        let createdUser = try await apiClient.createUser(name: name, password: password)
        applyCreatedUser(createdUser)
        return createdUser
    }

    private func applyCreatedUser(_ user: JellyfinUser) {
        users.append(user)
        users.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        serviceManager?.updateCachedUserCount(users.count)
    }

    func applyUpdatedUser(_ user: JellyfinUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        }
    }

    func removeUser(_ user: JellyfinUser) {
        users.removeAll { $0.id == user.id }
        serviceManager?.updateCachedUserCount(users.count)
    }

    func clearError() {
        errorMessage = nil
    }
}
