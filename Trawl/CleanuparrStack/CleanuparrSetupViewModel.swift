import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class CleanuparrSetupViewModel {
    var hostURL = ""
    var apiKey = ""
    var displayName = "Cleanuparr"
    var allowsUntrustedTLS = false
    var error: String?
    var isConnecting = false

    private var seededProfileID: UUID?
    private var hasSeededInitialState = false

    var canConnect: Bool {
        !isConnecting && !trimmed(hostURL).isEmpty && !trimmed(apiKey).isEmpty
    }

    func seed(from profile: CleanuparrServiceProfile?) async {
        let profileID = profile?.id
        guard !hasSeededInitialState || seededProfileID != profileID else { return }

        hasSeededInitialState = true
        seededProfileID = profileID
        error = nil

        guard let profile else { return }
        displayName = profile.displayName
        hostURL = profile.hostURL
        allowsUntrustedTLS = profile.allowsUntrustedTLS

        do {
            apiKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey) ?? ""
        } catch {
            apiKey = ""
            self.error = "Couldn't load the saved API key: \(error.localizedDescription)"
        }
    }

    func connect(modelContext: ModelContext) async -> Bool {
        guard validateFields() else { return false }

        let normalizedURL: String
        do {
            normalizedURL = try ServerURLValidator.normalizedURLString(from: hostURL, allowsPath: true)
        } catch {
            self.error = error.localizedDescription
            return false
        }

        isConnecting = true
        error = nil
        defer { isConnecting = false }

        do {
            let key = trimmed(apiKey)
            let client = CleanuparrAPIClient(
                baseURL: normalizedURL,
                apiKey: key,
                allowsUntrustedTLS: allowsUntrustedTLS
            )
            _ = try await client.getStats(hours: 1)
            try await persist(
                normalizedURL: normalizedURL,
                apiKey: key,
                modelContext: modelContext
            )
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func validateFields() -> Bool {
        guard !trimmed(hostURL).isEmpty else {
            error = "Cleanuparr URL is required."
            return false
        }
        guard !trimmed(apiKey).isEmpty else {
            error = "API key is required."
            return false
        }
        return true
    }

    private func persist(
        normalizedURL: String,
        apiKey: String,
        modelContext: ModelContext
    ) async throws {
        let profiles = try modelContext.fetch(FetchDescriptor<CleanuparrServiceProfile>())
        let profile = profiles.first(where: { $0.id == seededProfileID })
            ?? profiles.first(where: { $0.isEnabled })
            ?? profiles.first
        let isNewProfile = profile == nil
        let savedProfile = profile ?? CleanuparrServiceProfile(
            displayName: resolvedDisplayName,
            hostURL: normalizedURL,
            allowsUntrustedTLS: allowsUntrustedTLS
        )
        let originalDisplayName = savedProfile.displayName
        let originalHostURL = savedProfile.hostURL
        let originalAllowsUntrustedTLS = savedProfile.allowsUntrustedTLS
        let originalIsEnabled = savedProfile.isEnabled
        let originalLastSynced = savedProfile.lastSynced
        let originalEnabledStates = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.isEnabled) })
        let keychainKey = savedProfile.apiKeyKeychainKey
        let originalAPIKey = isNewProfile ? nil : try await KeychainHelper.shared.read(key: keychainKey)

        savedProfile.displayName = resolvedDisplayName
        savedProfile.hostURL = normalizedURL
        savedProfile.allowsUntrustedTLS = allowsUntrustedTLS
        savedProfile.isEnabled = true
        savedProfile.lastSynced = .now

        if isNewProfile {
            modelContext.insert(savedProfile)
        }
        for existing in profiles where existing.id != savedProfile.id {
            existing.isEnabled = false
        }

        do {
            try await KeychainHelper.shared.save(key: keychainKey, value: apiKey)
            try modelContext.save()
        } catch {
            if isNewProfile {
                modelContext.rollback()
            } else {
                savedProfile.displayName = originalDisplayName
                savedProfile.hostURL = originalHostURL
                savedProfile.allowsUntrustedTLS = originalAllowsUntrustedTLS
                savedProfile.isEnabled = originalIsEnabled
                savedProfile.lastSynced = originalLastSynced
                for existing in profiles {
                    existing.isEnabled = originalEnabledStates[existing.id] ?? existing.isEnabled
                }
                try? modelContext.save()
            }
            await restoreAPIKey(originalAPIKey, key: keychainKey)
            throw error
        }
    }

    private var resolvedDisplayName: String {
        let requestedName = trimmed(displayName)
        return requestedName.isEmpty ? "Cleanuparr" : requestedName
    }

    private func restoreAPIKey(_ originalAPIKey: String?, key: String) async {
        do {
            if let originalAPIKey {
                try await KeychainHelper.shared.save(key: key, value: originalAPIKey)
            } else {
                try await KeychainHelper.shared.delete(key: key)
            }
        } catch {
            Self.logger.error("Keychain rollback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Trawl",
        category: "CleanuparrSetup"
    )
}
