import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SeerrSetupViewModel {
    var displayName: String = "Seerr"
    var hostURL: String = ""
    var username: String = ""
    var password: String = ""
    /// Seerr was the only service whose sheet offered no way to name the server or
    /// to accept a certificate it signed itself, so a self-signed Seerr behind
    /// HTTPS could not be reached and there was nothing in the sheet to say why.
    var allowsUntrustedTLS: Bool = false

    var isAuthenticating: Bool = false
    var error: String? = nil

    private var seededProfileID: UUID?
    private var hasSeeded = false

    var canConnect: Bool {
        !isAuthenticating
            && !trimmed(hostURL).isEmpty
            && !trimmed(username).isEmpty
            && !password.isEmpty
    }

    func seed(from profile: SeerrServiceProfile?) {
        guard !hasSeeded || seededProfileID != profile?.id else { return }
        hasSeeded = true
        seededProfileID = profile?.id
        error = nil

        guard let profile else {
            displayName = "Seerr"
            hostURL = ""
            allowsUntrustedTLS = false
            username = ""
            password = ""
            return
        }

        // Only the URL and its options are restored. The username and password are
        // Jellyfin credentials exchanged once for a session cookie and never stored,
        // so re-authenticating is always required.
        displayName = profile.displayName
        hostURL = profile.hostURL
        allowsUntrustedTLS = profile.allowsUntrustedTLS
        username = ""
        password = ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            let allowsUntrustedTLS = self.allowsUntrustedTLS

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

            let chosenName = trimmed(displayName)
            savedProfile.displayName = chosenName.isEmpty ? "Seerr" : chosenName
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

#if DEBUG
extension SeerrSetupViewModel {
    convenience init(
        previewHostURL: String = "",
        previewUsername: String = "",
        previewPassword: String = "",
        previewIsAuthenticating: Bool = false,
        previewError: String? = nil,
        previewDisplayName: String = "Seerr"
    ) {
        self.init()
        displayName = previewDisplayName
        hostURL = previewHostURL
        username = previewUsername
        password = previewPassword
        isAuthenticating = previewIsAuthenticating
        error = previewError
    }
}
#endif
