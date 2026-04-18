import Foundation
import Observation
import SwiftData

/// Central coordinator for all configured *arr services.
/// Holds active API clients and provides unified access to Sonarr/Radarr data.
@MainActor
@Observable
final class ArrServiceManager {
    // Active clients (nil if not configured)
    private(set) var sonarrClient: SonarrAPIClient?
    private(set) var radarrClient: RadarrAPIClient?
    private(set) var prowlarrClient: ProwlarrAPIClient?

    // Connection state
    private(set) var sonarrConnected: Bool = false
    private(set) var radarrConnected: Bool = false
    private(set) var prowlarrConnected: Bool = false
    private(set) var isInitializing: Bool = false
    private(set) var sonarrIsConnecting: Bool = false
    private(set) var radarrIsConnecting: Bool = false
    private(set) var prowlarrIsConnecting: Bool = false
    private(set) var sonarrConnectionError: String? = nil
    private(set) var radarrConnectionError: String? = nil
    private(set) var prowlarrConnectionError: String? = nil
    private(set) var connectionErrors: [String: String] = [:]  // serviceId -> error

    // Stored for retry
    private var storedProfiles: [ArrServiceProfile] = []

    // Shared cached data
    private(set) var sonarrQualityProfiles: [ArrQualityProfile] = []
    private(set) var radarrQualityProfiles: [ArrQualityProfile] = []
    private(set) var sonarrRootFolders: [ArrRootFolder] = []
    private(set) var radarrRootFolders: [ArrRootFolder] = []
    private(set) var sonarrTags: [ArrTag] = []
    private(set) var radarrTags: [ArrTag] = []

    /// Initialize services from stored ArrServiceProfile entries.
    func initialize(from profiles: [ArrServiceProfile]) async {
        storedProfiles = profiles
        isInitializing = true
        defer { isInitializing = false }
        disconnectAll()
        for profile in profiles where profile.isEnabled {
            await connectService(profile)
        }
    }

    func syncProfiles(_ profiles: [ArrServiceProfile]) {
        storedProfiles = profiles
    }

    /// Retry connecting a specific service using the last known profiles.
    func retry(_ serviceType: ArrServiceType) async {
        guard let profile = storedProfiles.first(where: { $0.resolvedServiceType == serviceType && $0.isEnabled }) else { return }
        await connectService(profile)
    }

    /// Connect a single service profile.
    func connectService(_ profile: ArrServiceProfile) async {
        guard let serviceType = profile.resolvedServiceType else {
            let errorMessage = "Invalid service type: \(profile.serviceType)"
            connectionErrors[profile.id.uuidString] = errorMessage
            return
        }
        setConnectingState(true, for: serviceType)
        clearConnectionState(for: serviceType, preserveError: false)
        defer { setConnectingState(false, for: serviceType) }

        do {
            guard let apiKey = try KeychainHelper.shared.read(key: profile.apiKeyKeychainKey),
                  !apiKey.isEmpty else {
                let errorMessage = "API key not found in Keychain."
                connectionErrors[profile.id.uuidString] = errorMessage
                setConnectionError(errorMessage, for: serviceType)
                return
            }

            switch serviceType {
            case .sonarr:
                let client = SonarrAPIClient(baseURL: profile.hostURL, apiKey: apiKey)
                // Test connection
                _ = try await client.getSystemStatus()

                // Cache configuration data
                do {
                    sonarrQualityProfiles = try await client.getQualityProfiles()
                    sonarrRootFolders = try await client.getRootFolders()
                    sonarrTags = try await client.getTags()

                    sonarrClient = client
                    sonarrConnected = true
                    sonarrConnectionError = nil
                    connectionErrors.removeValue(forKey: profile.id.uuidString)
                } catch {
                    let errorMessage = "Failed to load configuration: \(error.localizedDescription)"
                    connectionErrors[profile.id.uuidString] = errorMessage
                    setConnectionError(errorMessage, for: .sonarr)
                }

            case .radarr:
                let client = RadarrAPIClient(baseURL: profile.hostURL, apiKey: apiKey)
                _ = try await client.getSystemStatus()

                // Cache configuration data
                do {
                    radarrQualityProfiles = try await client.getQualityProfiles()
                    radarrRootFolders = try await client.getRootFolders()
                    radarrTags = try await client.getTags()

                    radarrClient = client
                    radarrConnected = true
                    radarrConnectionError = nil
                    connectionErrors.removeValue(forKey: profile.id.uuidString)
                } catch {
                    let errorMessage = "Failed to load configuration: \(error.localizedDescription)"
                    connectionErrors[profile.id.uuidString] = errorMessage
                    setConnectionError(errorMessage, for: .radarr)
                }

            case .prowlarr:
                let client = ProwlarrAPIClient(baseURL: profile.hostURL, apiKey: apiKey)
                _ = try await client.getSystemStatus()
                prowlarrClient = client
                prowlarrConnected = true
                prowlarrConnectionError = nil
                connectionErrors.removeValue(forKey: profile.id.uuidString)
            }
        } catch {
            connectionErrors[profile.id.uuidString] = error.localizedDescription
            setConnectionError(error.localizedDescription, for: serviceType)
        }
    }

    /// Disconnect all services.
    func disconnectAll() {
        sonarrClient = nil
        radarrClient = nil
        prowlarrClient = nil
        sonarrConnected = false
        radarrConnected = false
        prowlarrConnected = false
        sonarrIsConnecting = false
        radarrIsConnecting = false
        prowlarrIsConnecting = false
        sonarrConnectionError = nil
        radarrConnectionError = nil
        prowlarrConnectionError = nil
        sonarrQualityProfiles = []
        radarrQualityProfiles = []
        sonarrRootFolders = []
        radarrRootFolders = []
        sonarrTags = []
        radarrTags = []
        connectionErrors.removeAll()
    }

    /// Disconnect a single service and clear any cached state for that service type.
    func disconnectService(_ serviceType: ArrServiceType, profileID: UUID? = nil) {
        switch serviceType {
        case .sonarr:
            clearConnectionState(for: .sonarr, preserveError: false)
        case .radarr:
            clearConnectionState(for: .radarr, preserveError: false)
        case .prowlarr:
            clearConnectionState(for: .prowlarr, preserveError: false)
        }

        if let profileID {
            connectionErrors.removeValue(forKey: profileID.uuidString)
        }
    }

    /// Test a connection without persisting it.
    func testConnection(hostURL: String, apiKey: String, serviceType: ArrServiceType) async throws -> ArrSystemStatus {
        switch serviceType {
        case .prowlarr:
            let client = ProwlarrAPIClient(baseURL: hostURL, apiKey: apiKey)
            return try await client.getSystemStatus()
        default:
            let client = ArrAPIClient(baseURL: hostURL, apiKey: apiKey)
            return try await client.getSystemStatus()
        }
    }

    /// Refresh cached configuration data for all connected services.
    func refreshConfiguration() async {
        if let sonarr = sonarrClient {
            sonarrQualityProfiles = (try? await sonarr.getQualityProfiles()) ?? sonarrQualityProfiles
            sonarrRootFolders = (try? await sonarr.getRootFolders()) ?? sonarrRootFolders
            sonarrTags = (try? await sonarr.getTags()) ?? sonarrTags
        }
        if let radarr = radarrClient {
            radarrQualityProfiles = (try? await radarr.getQualityProfiles()) ?? radarrQualityProfiles
            radarrRootFolders = (try? await radarr.getRootFolders()) ?? radarrRootFolders
            radarrTags = (try? await radarr.getTags()) ?? radarrTags
        }
    }

    private func setConnectingState(_ isConnecting: Bool, for serviceType: ArrServiceType) {
        switch serviceType {
        case .sonarr: sonarrIsConnecting = isConnecting
        case .radarr: radarrIsConnecting = isConnecting
        case .prowlarr: prowlarrIsConnecting = isConnecting
        }
    }

    private func setConnectionError(_ message: String?, for serviceType: ArrServiceType) {
        switch serviceType {
        case .sonarr:
            sonarrConnected = false
            sonarrConnectionError = message
        case .radarr:
            radarrConnected = false
            radarrConnectionError = message
        case .prowlarr:
            prowlarrConnected = false
            prowlarrConnectionError = message
        }
    }

    private func clearConnectionState(for serviceType: ArrServiceType, preserveError: Bool) {
        switch serviceType {
        case .sonarr:
            sonarrClient = nil
            sonarrConnected = false
            if !preserveError { sonarrConnectionError = nil }
            sonarrQualityProfiles = []
            sonarrRootFolders = []
            sonarrTags = []
        case .radarr:
            radarrClient = nil
            radarrConnected = false
            if !preserveError { radarrConnectionError = nil }
            radarrQualityProfiles = []
            radarrRootFolders = []
            radarrTags = []
        case .prowlarr:
            prowlarrClient = nil
            prowlarrConnected = false
            if !preserveError { prowlarrConnectionError = nil }
        }
    }
}