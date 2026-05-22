import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SeerrSetupViewModel {
    var hostURL: String = ""
    var username: String = ""
    var password: String = ""
    
    var isAuthenticating: Bool = false
    var error: String? = nil
    
    func login(modelContext: ModelContext) async -> Bool {
        guard !hostURL.isEmpty, !username.isEmpty, !password.isEmpty else { return false }

        let trimmedURLInput = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL: String
        do {
            normalizedURL = try ServerURLValidator.normalizedURLString(from: trimmedURLInput)
        } catch {
            self.error = error.localizedDescription
            return false
        }

        isAuthenticating = true
        error = nil

        defer { isAuthenticating = false }

        do {
            let profiles = try modelContext.fetch(FetchDescriptor<SeerrServiceProfile>())
            let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first
            let allowsUntrustedTLS = profile?.allowsUntrustedTLS ?? false

            let client = SeerrAPIClient(baseURL: normalizedURL, allowsUntrustedTLS: allowsUntrustedTLS)
            let user = try await client.loginJellyfin(username: username, password: password)
            guard user.isAdmin else {
                error = "You must be a Seerr admin to use Trawl."
                return false
            }

            // Get session cookie first
            guard let cookie = await client.getSessionCookie() else {
                error = "Session cookie not received from server."
                return false
            }

            let isNewProfile = profile == nil
            let savedProfile = profile ?? SeerrServiceProfile(displayName: "Seerr", hostURL: normalizedURL)
            let originalDisplayName = savedProfile.displayName
            let originalHostURL = savedProfile.hostURL
            let originalIsEnabled = savedProfile.isEnabled
            let originalAllowsUntrustedTLS = savedProfile.allowsUntrustedTLS
            let originalEnabledStates = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.isEnabled) })
            let sessionCookieKey = savedProfile.sessionCookieKey
            let originalSessionCookie = isNewProfile ? nil : try await KeychainHelper.shared.read(key: sessionCookieKey)

            savedProfile.displayName = originalDisplayName.isEmpty ? "Seerr" : originalDisplayName
            savedProfile.hostURL = normalizedURL
            savedProfile.isEnabled = true
            savedProfile.allowsUntrustedTLS = allowsUntrustedTLS

            if isNewProfile {
                modelContext.insert(savedProfile)
            }

            for existing in profiles where existing.id != savedProfile.id {
                existing.isEnabled = false
            }

            // Save session cookie to keychain
            do {
                try await KeychainHelper.shared.save(key: sessionCookieKey, value: cookie)
            } catch {
                // Roll back profile insertion on keychain save failure
                if isNewProfile {
                    modelContext.delete(savedProfile)
                } else {
                    savedProfile.displayName = originalDisplayName
                    savedProfile.hostURL = originalHostURL
                    savedProfile.isEnabled = originalIsEnabled
                    savedProfile.allowsUntrustedTLS = originalAllowsUntrustedTLS
                    for existing in profiles {
                        existing.isEnabled = originalEnabledStates[existing.id] ?? existing.isEnabled
                    }
                    if let originalSessionCookie {
                        do {
                            try await KeychainHelper.shared.save(key: sessionCookieKey, value: originalSessionCookie)
                        } catch {
                            InAppNotificationCenter.shared.showError(title: "Failed to Restore Session", message: error.localizedDescription)
                        }
                    } else {
                        do {
                            try await KeychainHelper.shared.delete(key: sessionCookieKey)
                        } catch {
                            InAppNotificationCenter.shared.showError(title: "Failed to Delete Session", message: error.localizedDescription)
                        }
                    }
                }
                throw error
            }

            do {
                try modelContext.save()
            } catch {
                if isNewProfile {
                    modelContext.rollback()
                    try? await KeychainHelper.shared.delete(key: sessionCookieKey)
                } else {
                    savedProfile.displayName = originalDisplayName
                    savedProfile.hostURL = originalHostURL
                    savedProfile.isEnabled = originalIsEnabled
                    savedProfile.allowsUntrustedTLS = originalAllowsUntrustedTLS
                    for existing in profiles {
                        existing.isEnabled = originalEnabledStates[existing.id] ?? existing.isEnabled
                    }
                    if let originalSessionCookie {
                        try? await KeychainHelper.shared.save(key: sessionCookieKey, value: originalSessionCookie)
                    } else {
                        try? await KeychainHelper.shared.delete(key: sessionCookieKey)
                    }
                    try? modelContext.save()
                }
                throw error
            }

            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
