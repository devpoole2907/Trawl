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

        isAuthenticating = true
        error = nil

        defer { isAuthenticating = false }

        do {
            let client = SeerrAPIClient(baseURL: hostURL, allowsUntrustedTLS: false)
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

            // Save to SwiftData
            let profile = SeerrServiceProfile(displayName: "Seerr", hostURL: hostURL)
            modelContext.insert(profile)

            // Save session cookie to keychain
            do {
                try await KeychainHelper.shared.save(key: profile.sessionCookieKey, value: cookie)
            } catch {
                // Roll back profile insertion on keychain save failure
                modelContext.delete(profile)
                throw error
            }

            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
