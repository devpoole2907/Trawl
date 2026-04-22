import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class OnboardingViewModel {
    var hostURL: String = ""
    var username: String = ""
    var password: String = ""
    var displayName: String = ""
    var allowsUntrustedTLS: Bool = false
    var isValidating: Bool = false
    var validationError: String?
    var isValid: Bool = false
    var hasAttemptedSubmit: Bool = false

    func loadExistingServer(_ server: ServerProfile) async {
        hostURL = server.hostURL
        displayName = server.displayName == server.hostURL ? "" : server.displayName
        allowsUntrustedTLS = server.allowsUntrustedTLS
        do {
            username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
            password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""
        } catch {
            username = ""
            password = ""
            validationError = "Couldn't load the saved credentials: \(error.localizedDescription)"
        }
    }

    /// Validates the connection and saves the server profile.
    /// Returns true if saved successfully.
    func validateAndSave(modelContext: ModelContext, editingServer: ServerProfile? = nil) async -> Bool {
        let trimmedURLInput = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)

        hasAttemptedSubmit = true

        guard !trimmedURLInput.isEmpty else {
            validationError = nil
            return false
        }

        guard !username.isEmpty, !password.isEmpty else {
            validationError = nil
            return false
        }

        let trimmedURL: String
        do {
            trimmedURL = try ServerURLValidator.normalizedURLString(from: trimmedURLInput)
        } catch {
            validationError = error.localizedDescription
            return false
        }

        isValidating = true
        validationError = nil

        do {
            // Create a temporary API client to test the connection
            let tempAuth = AuthService(serverProfileID: UUID(), allowsUntrustedTLS: allowsUntrustedTLS)
            let tempClient = QBittorrentAPIClient(
                baseURL: trimmedURL,
                authService: tempAuth,
                allowsUntrustedTLS: allowsUntrustedTLS
            )

            try await tempClient.login(username: username, password: password)
            _ = try await tempClient.getAppVersion()

            // Connection successful — save the profile
            let name = displayName.isEmpty ? trimmedURL : displayName
            let profile: ServerProfile

            if let editingServer {
                editingServer.displayName = name
                editingServer.hostURL = trimmedURL
                editingServer.allowsUntrustedTLS = allowsUntrustedTLS
                editingServer.isActive = true
                profile = editingServer
            } else {
                profile = ServerProfile(
                    displayName: name,
                    hostURL: trimmedURL,
                    allowsUntrustedTLS: allowsUntrustedTLS
                )

                // Deactivate any existing active servers
                let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.isActive })
                let existingServers = try modelContext.fetch(descriptor)
                for server in existingServers {
                    server.isActive = false
                }

                modelContext.insert(profile)
            }

            // Save credentials to Keychain
            try await KeychainHelper.shared.save(key: profile.usernameKey, value: username)
            try await KeychainHelper.shared.save(key: profile.passwordKey, value: password)

            try modelContext.save()

            isValid = true
            isValidating = false
            return true
        } catch let error as QBError {
            validationError = error.errorDescription
            isValidating = false
            return false
        } catch {
            validationError = "Connection failed: \(error.localizedDescription)"
            isValidating = false
            return false
        }
    }
}
