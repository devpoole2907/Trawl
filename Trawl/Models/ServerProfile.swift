import Foundation
import SwiftData

@Model
final class ServerProfile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var hostURL: String
    var isActive: Bool
    var dateAdded: Date
    var lastConnected: Date?
    var defaultSavePath: String?

    init(displayName: String, hostURL: String) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.isActive = true
        self.dateAdded = .now
    }

    /// Keychain key for the username credential
    var usernameKey: String { "server_\(id.uuidString)_username" }

    /// Keychain key for the password credential
    var passwordKey: String { "server_\(id.uuidString)_password" }
}
