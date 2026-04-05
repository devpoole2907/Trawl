import Foundation
import Observation
import SwiftData

@Observable
final class OnboardingViewModel {
    var hostURL: String = ""
    var username: String = ""
    var password: String = ""
    var displayName: String = ""
    var isValidating: Bool = false
    var validationError: String?
    var isValid: Bool = false
    var hasAttemptedSubmit: Bool = false

    func loadExistingServer(_ server: ServerProfile, username: String, password: String) {
        hostURL = server.hostURL
        displayName = server.displayName == server.hostURL ? "" : server.displayName
        self.username = username
        self.password = password
    }

    /// Validates the connection and saves the server profile.
    /// Returns true if saved successfully.
    func validateAndSave(modelContext: ModelContext, editingServer: ServerProfile? = nil) async -> Bool {
        var trimmedURL = hostURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Prepend http:// if the user didn't include a scheme
        if !trimmedURL.hasPrefix("http://") && !trimmedURL.hasPrefix("https://") {
            trimmedURL = "http://" + trimmedURL
        }

        hasAttemptedSubmit = true

        guard !trimmedURL.isEmpty else {
            validationError = nil
            return false
        }

        guard !username.isEmpty, !password.isEmpty else {
            validationError = nil
            return false
        }

        isValidating = true
        validationError = nil

        do {
            // Create a temporary API client to test the connection
            let tempAuth = AuthService(serverProfileID: UUID())
            let tempClient = QBittorrentAPIClient(baseURL: trimmedURL, authService: tempAuth)

            try await tempClient.login(username: username, password: password)
            _ = try await tempClient.getAppVersion()

            // Connection successful — save the profile
            let name = displayName.isEmpty ? trimmedURL : displayName
            let profile: ServerProfile

            if let editingServer {
                editingServer.displayName = name
                editingServer.hostURL = trimmedURL
                editingServer.isActive = true
                profile = editingServer
            } else {
                profile = ServerProfile(displayName: name, hostURL: trimmedURL)

                // Deactivate any existing active servers
                let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.isActive })
                if let existingServers = try? modelContext.fetch(descriptor) {
                    for server in existingServers {
                        server.isActive = false
                    }
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
