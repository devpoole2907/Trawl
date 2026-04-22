import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ArrSetupViewModel {
    var hostURL: String = ""
    var apiKey: String = ""
    var displayName: String = ""
    var serviceType: ArrServiceType = .sonarr
    var allowsUntrustedTLS: Bool = false
    var isValidating: Bool = false
    var validationError: String?
    var validatedStatus: ArrSystemStatus?

    private let serviceManager: ArrServiceManager
    private var existingProfile: ArrServiceProfile?

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    /// Validate the connection and save the profile.
    func validateAndSave(modelContext: ModelContext) async -> Bool {
        let trimmedURLInput = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURLInput.isEmpty else {
            validationError = "Server URL is required."
            return false
        }
        guard !trimmedKey.isEmpty else {
            validationError = "API key is required."
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
            let status = try await serviceManager.testConnection(
                hostURL: trimmedURL,
                apiKey: trimmedKey,
                serviceType: serviceType,
                allowsUntrustedTLS: allowsUntrustedTLS
            )
            validatedStatus = status

            // Save or update profile
            let name = displayName.isEmpty ? (status.instanceName ?? serviceType.displayName) : displayName

            let profile: ArrServiceProfile
            if let existing = existingProfile {
                existing.displayName = name
                existing.hostURL = trimmedURL
                existing.serviceType = serviceType.rawValue
                existing.allowsUntrustedTLS = allowsUntrustedTLS
                existing.apiVersion = status.version
                profile = existing
            } else {
                profile = ArrServiceProfile(
                    displayName: name,
                    hostURL: trimmedURL,
                    serviceType: serviceType,
                    allowsUntrustedTLS: allowsUntrustedTLS
                )
                profile.apiVersion = status.version
                modelContext.insert(profile)
            }

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
        existingProfile = profile
        hostURL = profile.hostURL
        displayName = profile.displayName
        if let resolvedType = profile.resolvedServiceType {
            serviceType = resolvedType
        } else {
            serviceType = .sonarr
            validationError = "Invalid service type stored in profile. Defaulting to Sonarr."
        }
        allowsUntrustedTLS = profile.allowsUntrustedTLS
        do {
            apiKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey) ?? ""
        } catch {
            apiKey = ""
            validationError = "Couldn't load the saved API key: \(error.localizedDescription)"
        }
    }

    /// Delete a service profile.
    func deleteProfile(_ profile: ArrServiceProfile, modelContext: ModelContext) async {
        do {
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Remove Service",
                message: "Failed to delete the saved API key. \(error.localizedDescription)"
            )
            return
        }
        modelContext.delete(profile)
        do {
            try modelContext.save()
            if let serviceType = profile.resolvedServiceType {
                serviceManager.disconnectService(serviceType, profileID: profile.id)
            }
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Remove Service",
                message: "Failed to save the updated service list. \(error.localizedDescription)"
            )
        }
    }
}