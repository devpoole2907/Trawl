import Foundation
import Observation
import SwiftData

@Observable
final class ArrSetupViewModel {
    var hostURL: String = ""
    var apiKey: String = ""
    var displayName: String = ""
    var serviceType: ArrServiceType = .sonarr
    var isValidating: Bool = false
    var validationError: String?
    var validatedStatus: ArrSystemStatus?

    private let serviceManager: ArrServiceManager

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    /// Validate the connection and save the profile.
    func validateAndSave(modelContext: ModelContext) async -> Bool {
        let trimmedURL = hostURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            validationError = "Server URL is required."
            return false
        }
        guard !trimmedKey.isEmpty else {
            validationError = "API key is required."
            return false
        }

        isValidating = true
        validationError = nil

        do {
            let status = try await serviceManager.testConnection(
                hostURL: trimmedURL,
                apiKey: trimmedKey,
                serviceType: serviceType
            )
            validatedStatus = status

            // Save profile
            let name = displayName.isEmpty ? (status.instanceName ?? serviceType.displayName) : displayName
            let profile = ArrServiceProfile(displayName: name, hostURL: trimmedURL, serviceType: serviceType)
            profile.apiVersion = status.version

            modelContext.insert(profile)

            // Save API key to Keychain
            try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: trimmedKey)

            try modelContext.save()

            // Connect the new service
            await serviceManager.connectService(profile)

            isValidating = false
            return true
        } catch let error as ArrError {
            validationError = error.errorDescription
            isValidating = false
            return false
        } catch {
            validationError = "Connection failed: \(error.localizedDescription)"
            isValidating = false
            return false
        }
    }

    /// Pre-fill for editing an existing profile.
    func loadExisting(_ profile: ArrServiceProfile) async {
        hostURL = profile.hostURL
        displayName = profile.displayName
        serviceType = profile.resolvedServiceType ?? .sonarr
        apiKey = (try? await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey)) ?? ""
    }

    /// Delete a service profile.
    func deleteProfile(_ profile: ArrServiceProfile, modelContext: ModelContext) async {
        if let serviceType = profile.resolvedServiceType {
            serviceManager.disconnectService(serviceType, profileID: profile.id)
        }
        try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        modelContext.delete(profile)
        try? modelContext.save()
    }
}