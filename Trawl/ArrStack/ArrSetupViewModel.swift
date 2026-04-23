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
            let isEditing = existingProfile != nil
            let originalAPIKey: String?

            if let existing = existingProfile {
                originalAPIKey = try await KeychainHelper.shared.read(key: existing.apiKeyKeychainKey)
                profile = existing
            } else {
                originalAPIKey = nil
                profile = ArrServiceProfile(
                    displayName: name,
                    hostURL: trimmedURL,
                    serviceType: serviceType,
                    allowsUntrustedTLS: allowsUntrustedTLS
                )
                profile.apiVersion = status.version
            }

            let originalDisplayName = profile.displayName
            let originalHostURL = profile.hostURL
            let originalServiceType = profile.serviceType
            let originalAllowsUntrustedTLS = profile.allowsUntrustedTLS
            let originalApiVersion = profile.apiVersion
            let keychainKey = profile.apiKeyKeychainKey

            try await KeychainHelper.shared.save(key: keychainKey, value: trimmedKey)

            profile.displayName = name
            profile.hostURL = trimmedURL
            profile.serviceType = serviceType.rawValue
            profile.allowsUntrustedTLS = allowsUntrustedTLS
            profile.apiVersion = status.version

            if !isEditing {
                modelContext.insert(profile)
            }

            do {
                try modelContext.save()
            } catch {
                if isEditing {
                    profile.displayName = originalDisplayName
                    profile.hostURL = originalHostURL
                    profile.serviceType = originalServiceType
                    profile.allowsUntrustedTLS = originalAllowsUntrustedTLS
                    profile.apiVersion = originalApiVersion

                    if let originalAPIKey {
                        try? await KeychainHelper.shared.save(key: keychainKey, value: originalAPIKey)
                    } else {
                        try? await KeychainHelper.shared.delete(key: keychainKey)
                    }
                } else {
                    modelContext.rollback()
                    try? await KeychainHelper.shared.delete(key: keychainKey)
                }
                throw error
            }

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
        guard let serviceType = profile.resolvedServiceType else {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Remove Service",
                message: "The saved service type is invalid. Please try editing the profile before deleting it."
            )
            return
        }

        let keychainKey = profile.apiKeyKeychainKey
        serviceManager.disconnectService(serviceType, profileID: profile.id)

        modelContext.delete(profile)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Remove Service",
                message: "Failed to save the updated service list. \(error.localizedDescription)"
            )
            return
        }

        do {
            try await KeychainHelper.shared.delete(key: keychainKey)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Keychain Warning",
                message: "Service removed but failed to delete API key from keychain. \(error.localizedDescription)"
            )
        }
    }
}
