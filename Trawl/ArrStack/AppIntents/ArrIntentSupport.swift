import Foundation
import SwiftData

/// A `Sendable` snapshot of a configured *arr service profile, safe to pass across actors.
///
/// App Intents run off the main actor and must not touch the `@MainActor`, UI-oriented
/// `ArrServiceManager`. This snapshot carries everything the intent layer needs to build a
/// client without holding a SwiftData `@Model` reference.
nonisolated struct ArrServiceSnapshot: Sendable, Identifiable {
    let id: UUID
    let displayName: String
    let hostURL: String
    let allowsUntrustedTLS: Bool
    let apiKeyKeychainKey: String
    let serviceType: ArrServiceType
}

/// Intent-safe access layer over Trawl's saved *arr service profiles and API clients.
///
/// Deliberately independent of `ArrServiceManager` (which is `@MainActor` and view-oriented).
/// It reads `ArrServiceProfile` records from the App Group SwiftData store, loads API keys from
/// the shared Keychain, and constructs the existing `RadarrAPIClient` / `SonarrAPIClient` /
/// `ProwlarrAPIClient` actors directly — the same pattern the widgets use in `WidgetDataFetcher`.
nonisolated enum ArrIntentSupport {

    // MARK: - Model container

    /// Builds a one-shot `ModelContainer` pointed at the App Group store, mirroring
    /// `TrawlApp` and `WidgetDataFetcher.makeModelContainer()`.
    nonisolated static func makeModelContainer() throws -> ModelContainer {
        let schema = TrawlModelSchema.full
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(AppGroup.identifier)
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Profiles

    /// Loads enabled service snapshots of the requested types from the shared SwiftData store.
    ///
    /// Mirrors `WidgetDataFetcher.fetchArrProfiles`: if no profile is explicitly enabled it falls
    /// back to all profiles so a stray disabled flag doesn't make Siri report "no service".
    static func loadServices(ofTypes types: Set<ArrServiceType>) async throws -> [ArrServiceSnapshot] {
        let container = try makeModelContainer()
        return try await MainActor.run {
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<ArrServiceProfile>())
            let enabled = all.filter(\.isEnabled)
            let candidates = enabled.isEmpty ? all : enabled
            return candidates
                .compactMap { profile -> ArrServiceSnapshot? in
                    guard let type = profile.resolvedServiceType, types.contains(type) else { return nil }
                    return ArrServiceSnapshot(
                        id: profile.id,
                        displayName: profile.displayName,
                        hostURL: profile.hostURL,
                        allowsUntrustedTLS: profile.allowsUntrustedTLS,
                        apiKeyKeychainKey: profile.apiKeyKeychainKey,
                        serviceType: type
                    )
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Resolves a single service to act on.
    ///
    /// - If the user picked a service entity, that one is used (validated against the allowed types).
    /// - Otherwise, when exactly one service of the requested type exists it is selected automatically.
    /// - When several exist and none was chosen, asks the user to pick one.
    static func resolveService(
        preferred entity: ArrServiceEntity?,
        ofTypes types: Set<ArrServiceType>
    ) async throws -> ArrServiceSnapshot {
        let services = try await loadServices(ofTypes: types)
        guard !services.isEmpty else {
            throw ArrIntentError.noServiceConfigured(serviceTypeDescription(for: types))
        }
        if let entity {
            guard let match = services.first(where: { $0.id.uuidString == entity.id }) else {
                throw ArrIntentError.unsupportedServiceType
            }
            return match
        }
        if services.count == 1 { return services[0] }
        throw ArrIntentError.serviceSelectionRequired(serviceTypeDescription(for: types))
    }

    // MARK: - Credentials & clients

    /// Reads the API key for a service from the shared Keychain.
    static func apiKey(for service: ArrServiceSnapshot) async throws -> String {
        guard let key = try? await KeychainHelper.shared.read(key: service.apiKeyKeychainKey),
              !key.isEmpty else {
            throw ArrIntentError.missingAPIKey(service.displayName)
        }
        return key
    }

    static func makeRadarrClient(_ service: ArrServiceSnapshot) async throws -> RadarrAPIClient {
        let key = try await apiKey(for: service)
        return RadarrAPIClient(baseURL: service.hostURL, apiKey: key, allowsUntrustedTLS: service.allowsUntrustedTLS)
    }

    static func makeSonarrClient(_ service: ArrServiceSnapshot) async throws -> SonarrAPIClient {
        let key = try await apiKey(for: service)
        return SonarrAPIClient(baseURL: service.hostURL, apiKey: key, allowsUntrustedTLS: service.allowsUntrustedTLS)
    }

    static func makeProwlarrClient(_ service: ArrServiceSnapshot) async throws -> ProwlarrAPIClient {
        let key = try await apiKey(for: service)
        return ProwlarrAPIClient(baseURL: service.hostURL, apiKey: key, allowsUntrustedTLS: service.allowsUntrustedTLS)
    }

    // MARK: - Safe add defaults

    /// Chooses a sensible default quality profile from the service's live profiles.
    /// Prefers an existing 1080p-style profile, otherwise the first available one.
    static func defaultQualityProfileId(from profiles: [ArrQualityProfile]) throws -> Int {
        guard !profiles.isEmpty else { throw ArrIntentError.noQualityProfiles }
        if let hd1080 = profiles.first(where: { $0.name.localizedCaseInsensitiveContains("1080") }) {
            return hd1080.id
        }
        return profiles[0].id
    }

    /// Chooses a default root folder from the service's live root folders.
    /// Prefers the first accessible folder, otherwise the first one. Never hardcodes a path.
    static func defaultRootFolderPath(from folders: [ArrRootFolder]) throws -> String {
        guard !folders.isEmpty else { throw ArrIntentError.noRootFolders }
        if let accessible = folders.first(where: { $0.accessible != false }) {
            return accessible.path
        }
        return folders[0].path
    }

    // MARK: - Error & formatting helpers

    /// Produces a user-facing message for an underlying error without leaking API keys or URLs.
    /// `ArrError` descriptions already redact credentials and host URLs.
    static func describe(_ error: Error) -> String {
        if let intentError = error as? ArrIntentError { return intentError.message }
        if let arrError = error as? ArrError { return arrError.errorDescription ?? "The request failed." }
        return error.localizedDescription
    }

    static func serviceTypeDescription(for types: Set<ArrServiceType>) -> String {
        let names = ArrServiceType.allCases
            .filter { types.contains($0) }
            .map(\.displayName)
        switch names.count {
        case 0: return "service"
        case 1: return names[0]
        default: return names.joined(separator: " or ")
        }
    }

    /// "1.2 GB" style size text from a byte count.
    static func byteText(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func byteText(_ bytes: Double?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Download progress percent text for a queue item, e.g. "42%".
    static func progressText(size: Double?, sizeleft: Double?) -> String? {
        guard let size, size > 0, let sizeleft else { return nil }
        let fraction = max(0, min(1, (size - sizeleft) / size))
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Parses an *arr ISO-8601 date string (with or without fractional seconds).
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
