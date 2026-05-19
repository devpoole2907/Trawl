import Foundation
import Observation
import SwiftUI

@Observable
final class JellyfinUserEditorViewModel {
    let user: JellyfinUser
    var policy: JellyfinUserPolicy
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var parentalRatings: [JellyfinParentalRating] = []
    private(set) var virtualFolders: [JellyfinVirtualFolder] = []
    private(set) var devices: [JellyfinDeviceInfo] = []
    private(set) var channels: [JellyfinLibraryItem] = []

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
        policy != originalPolicy
    }

    func policyBinding(_ keyPath: WritableKeyPath<JellyfinUserPolicy, Bool?>) -> Binding<Bool> {
        Binding(
            get: { self.policy[keyPath: keyPath] ?? false },
            set: { self.policy[keyPath: keyPath] = $0 }
        )
    }

    func policyStringBinding(_ keyPath: WritableKeyPath<JellyfinUserPolicy, String?>) -> Binding<String> {
        Binding(
            get: { self.policy[keyPath: keyPath] ?? "" },
            set: { self.policy[keyPath: keyPath] = $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        )
    }

    func policyIntegerBinding(_ keyPath: WritableKeyPath<JellyfinUserPolicy, Int?>) -> Binding<String> {
        Binding(
            get: { self.policy[keyPath: keyPath].map(String.init) ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                self.policy[keyPath: keyPath] = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }

    func policyStringListBinding(_ keyPath: WritableKeyPath<JellyfinUserPolicy, [String]?>) -> Binding<String> {
        Binding(
            get: { self.policy[keyPath: keyPath]?.joined(separator: ", ") ?? "" },
            set: { value in
                let values = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                self.policy[keyPath: keyPath] = values.isEmpty ? nil : values
            }
        )
    }

    func upsertAccessSchedule(_ schedule: JellyfinAccessSchedule, at index: Int?) {
        var schedules = policy.accessSchedules ?? []
        if let index, schedules.indices.contains(index) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        policy.accessSchedules = schedules.isEmpty ? nil : schedules
    }

    func removeAccessSchedule(at index: Int) {
        guard var schedules = policy.accessSchedules, schedules.indices.contains(index) else { return }
        schedules.remove(at: index)
        policy.accessSchedules = schedules.isEmpty ? nil : schedules
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
        guard !isSaving else { return false }
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

    func loadParentalRatings() async {
        guard parentalRatings.isEmpty else { return }
        do {
            parentalRatings = try await apiClient.getParentalRatings()
        } catch {
            // non-fatal; UI falls back to text field
        }
    }

    /// Returns the display name for a stored `MaxParentalRating` score, or the raw
    /// integer as a string if it doesn't match any known rating.
    func parentalRatingName(for score: Int?) -> String? {
        guard let score else { return nil }
        return parentalRatings.first(where: { $0.score == score })?.displayName ?? String(score)
    }

    func policyOptionalIntBinding(_ keyPath: WritableKeyPath<JellyfinUserPolicy, Int?>) -> Binding<Int?> {
        Binding(
            get: { self.policy[keyPath: keyPath] },
            set: { self.policy[keyPath: keyPath] = $0 }
        )
    }

    func loadVirtualFolders() async {
        guard virtualFolders.isEmpty else { return }
        do {
            virtualFolders = try await apiClient.getVirtualFolders()
        } catch {
            // non-fatal; UI falls back to showing raw IDs
        }
    }

    func loadDevices() async {
        guard devices.isEmpty else { return }
        do {
            devices = try await apiClient.getDevices()
        } catch {
            // non-fatal; UI falls back to showing raw IDs
        }
    }

    func loadChannels() async {
        guard channels.isEmpty else { return }
        do {
            channels = try await apiClient.getChannels()
        } catch {
            // non-fatal; UI falls back to showing raw IDs
        }
    }

    func libraryDisplayNames(for ids: [String]?) -> String? {
        guard let ids, !ids.isEmpty else { return nil }
        return ids.map { id in virtualFolders.first(where: { $0.itemId == id })?.name ?? id }.joined(separator: ", ")
    }

    func deviceDisplayNames(for ids: [String]?) -> String? {
        guard let ids, !ids.isEmpty else { return nil }
        return ids.map { id in devices.first(where: { $0.id == id })?.displayName ?? id }.joined(separator: ", ")
    }

    func channelDisplayNames(for ids: [String]?) -> String? {
        guard let ids, !ids.isEmpty else { return nil }
        return ids.map { id in channels.first(where: { $0.id == id })?.name ?? id }.joined(separator: ", ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
