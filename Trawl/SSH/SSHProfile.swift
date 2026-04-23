import Foundation
import SwiftData

// MARK: - Auth Type

enum SSHAuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password   = "Password"
    case privateKey = "Private Key"
    var id: String { rawValue }
}

// MARK: - Credential Error

enum SSHCredentialError: Error, LocalizedError {
    case missingPassword
    case missingPrivateKey

    var errorDescription: String? {
        switch self {
        case .missingPassword: return "Password not found in Keychain"
        case .missingPrivateKey: return "Private key not found in Keychain"
        }
    }
}

// MARK: - Profile Model

@Model
final class SSHProfile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String
    /// Raw value of SSHAuthType — enum stored as String for SwiftData compatibility
    var authTypeRaw: String
    /// TOFU: SHA-256 fingerprint of the server's host key, set on first connect
    var knownHostFingerprint: String?
    var createdAt: Date

    init(
        displayName: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authType: SSHAuthType = .password
    ) {
        self.id = UUID()
        self.displayName = displayName.isEmpty ? host : displayName
        self.host = host
        self.port = port
        self.username = username
        self.authTypeRaw = authType.rawValue
        self.createdAt = .now
    }

    var authType: SSHAuthType {
        SSHAuthType(rawValue: authTypeRaw) ?? .password
    }

    /// Formatted host:port string for display
    var hostDisplay: String { port == 22 ? host : "\(host):\(port)" }

    // MARK: - Keychain keys (credentials never stored in SwiftData)
    var passwordKey:   String { "ssh.password.\(id.uuidString)" }
    var privateKeyKey: String { "ssh.privatekey.\(id.uuidString)" }
    var passphraseKey: String { "ssh.passphrase.\(id.uuidString)" }
}