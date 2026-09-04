import Foundation
import Observation

/// Carries a Jellyfin sign-in from the Jellyfin sheet to the Seerr sheet, for as
/// long as the app is running and no further.
///
/// Seerr does not have its own accounts - it authenticates against the Jellyfin
/// account configured on the Seerr server. So a user setting up both services in
/// one sitting types the same username and password twice, which is why Jellyfin
/// is now offered first and Seerr offers to reuse what was just entered.
///
/// Deliberately in memory only, and deliberately not written to the keychain.
/// Trawl does not store a Jellyfin password at all: signing in exchanges it for an
/// access token, the token goes to the keychain, and the password is dropped.
/// Keeping one on disk to save a second typing would be a bad trade, so the offer
/// is available for this launch and disappears with it.
@MainActor
@Observable
final class JellyfinCredentialHandoff {
    private(set) var username: String?
    private(set) var password: String?

    /// Whether there is a sign-in to reuse. False when Jellyfin was connected with
    /// an API key, which is not a credential Seerr can use.
    var isAvailable: Bool {
        guard let username, let password else { return false }
        return !username.isEmpty && !password.isEmpty
    }

    func store(username: String, password: String) {
        guard !username.isEmpty, !password.isEmpty else { return }
        self.username = username
        self.password = password
    }

    func clear() {
        username = nil
        password = nil
    }
}
