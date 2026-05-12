import Foundation
import OSLog
import SwiftData
import Observation

@MainActor
@Observable
final class JellyfinSetupViewModel {
    var hostURL: String = ""
    var username: String = ""
    var password: String = ""
    var apiKey: String = ""
    var authMode: JellyfinAuthMode = .apiKey
    var displayName: String = "Jellyfin"
    var allowsUntrustedTLS: Bool = false
    var error: String?
    var isAuthenticating: Bool = false

    private var hasSeededInitialState = false
    private var seededProfileID: UUID?

    var canConnect: Bool {
        guard !isAuthenticating, !trimmed(hostURL).isEmpty else { return false }
        switch authMode {
        case .apiKey:
            return !trimmed(apiKey).isEmpty
        case .userPass:
            return !trimmed(username).isEmpty && !password.isEmpty
        }
    }

    func seed(from profile: JellyfinServiceProfile?) {
        let profileID = profile?.id
        guard !hasSeededInitialState || seededProfileID != profileID else { return }

        hasSeededInitialState = true
        seededProfileID = profileID
        error = nil

        guard let profile else { return }
        displayName = profile.displayName
        hostURL = profile.hostURL
        authMode = profile.authMode
        allowsUntrustedTLS = profile.allowsUntrustedTLS
        username = ""
        password = ""
        apiKey = ""
    }

    func connect(modelContext: ModelContext) async -> Bool {
        guard validateFields() else { return false }

        let normalizedURL: String
        do {
            normalizedURL = try ServerURLValidator.normalizedURLString(from: hostURL)
        } catch {
            self.error = error.localizedDescription
            return false
        }

        isAuthenticating = true
        error = nil

        defer { isAuthenticating = false }

        do {
            let result = try await authenticate(normalizedURL: normalizedURL)
            try await persist(result, modelContext: modelContext)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func validateFields() -> Bool {
        guard !trimmed(hostURL).isEmpty else {
            error = "Jellyfin URL is required."
            return false
        }

        switch authMode {
        case .apiKey:
            guard !trimmed(apiKey).isEmpty else {
                error = "API key is required."
                return false
            }
        case .userPass:
            guard !trimmed(username).isEmpty, !password.isEmpty else {
                error = "Username and password are required."
                return false
            }
        }

        return true
    }

    private func authenticate(normalizedURL: String) async throws -> JellyfinSetupResult {
        let probeClient = JellyfinAPIClient(
            baseURL: normalizedURL,
            allowsUntrustedTLS: allowsUntrustedTLS
        )
        let publicInfo = try await probeClient.getPublicSystemInfo()

        switch authMode {
        case .apiKey:
            let token = trimmed(apiKey)
            let client = JellyfinAPIClient(
                baseURL: normalizedURL,
                accessToken: token,
                allowsUntrustedTLS: allowsUntrustedTLS
            )
            let systemInfo = try await client.getSystemInfo()
            _ = try await client.getUsers()

            return JellyfinSetupResult(
                hostURL: normalizedURL,
                token: token,
                authMode: .apiKey,
                userID: nil,
                publicInfo: publicInfo,
                systemInfo: systemInfo
            )

        case .userPass:
            let authResponse = try await probeClient.authenticateByName(
                username: trimmed(username),
                password: password
            )
            guard authResponse.user.policy?.isAdministrator == true else {
                throw JellyfinAPIError.notAdmin
            }

            let systemInfo = try await probeClient.getSystemInfo()
            return JellyfinSetupResult(
                hostURL: normalizedURL,
                token: authResponse.accessToken,
                authMode: .userPass,
                userID: authResponse.user.id,
                publicInfo: publicInfo,
                systemInfo: systemInfo
            )
        }
    }

    private func persist(_ result: JellyfinSetupResult, modelContext: ModelContext) async throws {
        let profiles = try modelContext.fetch(FetchDescriptor<JellyfinServiceProfile>())
        let profile = profiles.first(where: { $0.id == seededProfileID }) ?? profiles.first(where: { $0.isEnabled }) ?? profiles.first
        let isNewProfile = profile == nil
        let savedProfile = profile ?? JellyfinServiceProfile(
            displayName: resolvedDisplayName(from: result),
            hostURL: result.hostURL,
            authMode: result.authMode,
            userID: result.userID,
            allowsUntrustedTLS: allowsUntrustedTLS
        )

        let originalSnapshot = isNewProfile ? nil : JellyfinProfileSnapshot(profile: savedProfile)
        let originalEnabledStates = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.isEnabled) })
        let tokenKey = savedProfile.accessTokenKey
        let originalToken = isNewProfile ? nil : try await KeychainHelper.shared.read(key: tokenKey)

        savedProfile.displayName = resolvedDisplayName(from: result)
        savedProfile.hostURL = result.hostURL
        savedProfile.authMode = result.authMode
        savedProfile.userID = result.userID
        savedProfile.allowsUntrustedTLS = allowsUntrustedTLS
        savedProfile.isEnabled = true
        savedProfile.serverName = result.systemInfo.serverName ?? result.publicInfo.serverName
        savedProfile.serverVersion = result.systemInfo.version ?? result.publicInfo.version

        if isNewProfile {
            modelContext.insert(savedProfile)
        }

        for existing in profiles where existing.id != savedProfile.id {
            existing.isEnabled = false
        }

        do {
            try await KeychainHelper.shared.save(key: tokenKey, value: result.token)
        } catch {
            rollbackProfile(
                savedProfile,
                isNewProfile: isNewProfile,
                originalSnapshot: originalSnapshot,
                originalEnabledStates: originalEnabledStates,
                allProfiles: profiles,
                modelContext: modelContext
            )
            await restoreToken(originalToken, key: tokenKey)
            throw error
        }

        do {
            try modelContext.save()
        } catch {
            rollbackProfile(
                savedProfile,
                isNewProfile: isNewProfile,
                originalSnapshot: originalSnapshot,
                originalEnabledStates: originalEnabledStates,
                allProfiles: profiles,
                modelContext: modelContext
            )
            await restoreToken(originalToken, key: tokenKey)
            if isNewProfile {
                modelContext.rollback()
            } else {
                do {
                    try modelContext.save()
                } catch {
                    Self.logger.error("Model context save failed during rollback: \(error)")
                }
            }
            throw error
        }
    }

    private func rollbackProfile(
        _ profile: JellyfinServiceProfile,
        isNewProfile: Bool,
        originalSnapshot: JellyfinProfileSnapshot?,
        originalEnabledStates: [UUID: Bool],
        allProfiles: [JellyfinServiceProfile],
        modelContext: ModelContext
    ) {
        if isNewProfile {
            modelContext.delete(profile)
            return
        }

        originalSnapshot?.restore(on: profile)
        for existing in allProfiles {
            existing.isEnabled = originalEnabledStates[existing.id] ?? existing.isEnabled
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trawl", category: "JellyfinSetupViewModel")

    private func restoreToken(_ originalToken: String?, key: String) async {
        do {
            if let originalToken {
                try await KeychainHelper.shared.save(key: key, value: originalToken)
            } else {
                try await KeychainHelper.shared.delete(key: key)
            }
        } catch {
            Self.logger.error("Keychain rollback failed for key \(key): \(error)")
        }
    }

    private func resolvedDisplayName(from result: JellyfinSetupResult) -> String {
        let requestedName = trimmed(displayName)
        if !requestedName.isEmpty { return requestedName }
        if let serverName = result.systemInfo.serverName, !serverName.isEmpty { return serverName }
        if let serverName = result.publicInfo.serverName, !serverName.isEmpty { return serverName }
        return "Jellyfin"
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct JellyfinSetupResult {
    let hostURL: String
    let token: String
    let authMode: JellyfinAuthMode
    let userID: String?
    let publicInfo: JellyfinSystemPublicInfo
    let systemInfo: JellyfinSystemInfo
}

private struct JellyfinProfileSnapshot {
    let displayName: String
    let hostURL: String
    let allowsUntrustedTLS: Bool
    let isEnabled: Bool
    let authMode: JellyfinAuthMode
    let userID: String?
    let serverName: String?
    let serverVersion: String?

    init(profile: JellyfinServiceProfile) {
        displayName = profile.displayName
        hostURL = profile.hostURL
        allowsUntrustedTLS = profile.allowsUntrustedTLS
        isEnabled = profile.isEnabled
        authMode = profile.authMode
        userID = profile.userID
        serverName = profile.serverName
        serverVersion = profile.serverVersion
    }

    func restore(on profile: JellyfinServiceProfile) {
        profile.displayName = displayName
        profile.hostURL = hostURL
        profile.allowsUntrustedTLS = allowsUntrustedTLS
        profile.isEnabled = isEnabled
        profile.authMode = authMode
        profile.userID = userID
        profile.serverName = serverName
        profile.serverVersion = serverVersion
    }
}
