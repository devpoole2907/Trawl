import Foundation
import Observation
import SwiftUI

@Observable
final class JellyfinUserEditorViewModel {
    let user: JellyfinUser
    var policy: JellyfinUserPolicy
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    let apiClient: JellyfinAPIClient
    private var originalPolicy: JellyfinUserPolicy

    init(user: JellyfinUser, apiClient: JellyfinAPIClient) {
        self.user = user
        self.apiClient = apiClient
        let currentPolicy = user.policy ?? JellyfinUserPolicy()
        self.policy = currentPolicy
        self.originalPolicy = currentPolicy
    }

    var hasChanges: Bool {
        policy.isAdministrator != originalPolicy.isAdministrator
            || policy.isHidden != originalPolicy.isHidden
            || policy.isDisabled != originalPolicy.isDisabled
            || policy.enableContentDeletion != originalPolicy.enableContentDeletion
            || policy.enableMediaPlayback != originalPolicy.enableMediaPlayback
            || policy.enableLiveTvAccess != originalPolicy.enableLiveTvAccess
            || policy.enableLiveTvManagement != originalPolicy.enableLiveTvManagement
            || policy.enableRemoteAccess != originalPolicy.enableRemoteAccess
            || policy.enableSharedDeviceControl != originalPolicy.enableSharedDeviceControl
    }

    func policyBinding(_ keyPath: WritableKeyPath<JellyfinUserPolicy, Bool?>) -> Binding<Bool> {
        Binding(
            get: { self.policy[keyPath: keyPath] ?? false },
            set: { self.policy[keyPath: keyPath] = $0 }
        )
    }

    func reset() {
        policy = originalPolicy
    }

    func save() async -> JellyfinUser? {
        guard !isSaving else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await apiClient.updateUserPolicy(id: user.id, policy: policy)

            let updatedUsers = try await apiClient.getUsers()
            guard let refreshed = updatedUsers.first(where: { $0.id == user.id }) else {
                errorMessage = "User not found after update."
                return nil
            }
            policy = refreshed.policy ?? policy
            originalPolicy = refreshed.policy ?? policy
            return refreshed
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteUser() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await apiClient.deleteUser(id: user.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
