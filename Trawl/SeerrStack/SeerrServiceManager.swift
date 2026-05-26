import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SeerrServiceManager {
    private(set) var activeClient: SeerrAPIClient?
    private(set) var activeProfileID: UUID?
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var connectionError: String?
    private(set) var cachedUserCount: Int?

    func initialize(from profiles: [SeerrServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first else {
            disconnect()
            return
        }

        await connectService(profile)
    }

    func connectService(_ profile: SeerrServiceProfile) async {
        isConnecting = true
        connectionError = nil

        defer { isConnecting = false }

        do {
            guard let cookie = try await KeychainHelper.shared.read(key: profile.sessionCookieKey), !cookie.isEmpty else {
                activeClient = nil
                activeProfileID = nil
                isConnected = false
                cachedUserCount = nil
                connectionError = "Session cookie not found in Keychain."
                return
            }

            let client = SeerrAPIClient(baseURL: profile.hostURL, sessionCookie: cookie, allowsUntrustedTLS: profile.allowsUntrustedTLS)
            // Overseerr can issue a refreshed `connect.sid` on any response. Persist
            // updates so the cookie used at next launch is the latest, not the original
            // one captured at sign-in.
            let cookieKey = profile.sessionCookieKey
            await client.setCookieUpdateHandler { updated in
                Task.detached {
                    try? await KeychainHelper.shared.save(key: cookieKey, value: updated)
                }
            }
            _ = try await client.getCurrentUser()

            activeClient = client
            activeProfileID = profile.id
            isConnected = true

            // Eagerly fetch the user count so screens can show their subtitle
            // immediately on navigation, not after a round-trip.
            await prefetchUserCount(using: client)
        } catch {
            connectionError = error.localizedDescription
            activeClient = nil
            activeProfileID = nil
            isConnected = false
            cachedUserCount = nil
        }
    }

    func disconnect() {
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        connectionError = nil
        isConnecting = false
        cachedUserCount = nil
    }

    func updateCachedUserCount(_ count: Int) {
        cachedUserCount = count
    }

    private func prefetchUserCount(using client: SeerrAPIClient) async {
        do {
            let response = try await client.getUsers(take: 1, skip: 0)
            if let results = response.pageInfo.results {
                cachedUserCount = results
            }
        } catch {
            // Non-fatal — the user management screen will load fully on appear.
        }
    }

    func webhookNotificationSetupStatus(
        workerURL: String,
        deviceToken: String
    ) async throws -> ArrNotificationSetupStatus {
        guard let activeClient else { throw SeerrAPIError.unauthorized }
        let pushURL = try pushNotificationURL(from: workerURL)
        let settings = try await activeClient.getWebhookNotificationSettings()

        guard settings.enabled else { return .notAdded }
        return webhookSettingsMatch(settings, pushURL: pushURL, deviceToken: deviceToken)
            ? .configured
            : .needsUpdate
    }

    func trawlWebhookNotificationSettings(
        workerURL: String,
        deviceToken: String
    ) async throws -> SeerrWebhookNotificationSettings {
        guard let activeClient else { throw SeerrAPIError.unauthorized }
        let pushURL = try pushNotificationURL(from: workerURL)
        let existing = try await activeClient.getWebhookNotificationSettings()
        return webhookSettingsPayload(existing: existing, pushURL: pushURL, deviceToken: deviceToken)
    }

    func saveTrawlWebhookNotificationSettings(
        _ settings: SeerrWebhookNotificationSettings,
        workerURL: String,
        deviceToken: String
    ) async throws {
        guard let activeClient else { throw SeerrAPIError.unauthorized }
        let pushURL = try pushNotificationURL(from: workerURL)
        let payload = webhookSettingsPayload(existing: settings, pushURL: pushURL, deviceToken: deviceToken)
        try await activeClient.updateWebhookNotificationSettings(payload)
    }

    func testTrawlWebhookNotificationSettings(
        _ settings: SeerrWebhookNotificationSettings,
        workerURL: String,
        deviceToken: String
    ) async throws {
        guard let activeClient else { throw SeerrAPIError.unauthorized }
        let pushURL = try pushNotificationURL(from: workerURL)
        let payload = webhookSettingsPayload(existing: settings, pushURL: pushURL, deviceToken: deviceToken)
        try await activeClient.testWebhookNotificationSettings(payload)
    }

    private func webhookSettingsPayload(
        existing: SeerrWebhookNotificationSettings,
        pushURL: String,
        deviceToken: String
    ) -> SeerrWebhookNotificationSettings {
        let existingMatches = webhookSettingsMatch(existing, pushURL: pushURL, deviceToken: deviceToken)
        let payload = existingMatches
            ? Self.validWebhookPayload(existing.options.jsonPayload) ?? Self.trawlWebhookPayloadTemplate
            : Self.trawlWebhookPayloadTemplate

        return SeerrWebhookNotificationSettings(
            enabled: true,
            types: (existing.types == 0 ? Self.defaultWebhookTypes : existing.types) | SeerrNotificationType.testNotification.rawValue,
            options: SeerrWebhookNotificationOptions(
                webhookUrl: pushURL,
                authHeader: nil,
                jsonPayload: payload,
                supportVariables: true,
                customHeaders: [SeerrWebhookCustomHeader(key: "X-Trawl-Token", value: deviceToken)]
            )
        )
    }

    private func webhookSettingsMatch(
        _ settings: SeerrWebhookNotificationSettings,
        pushURL: String,
        deviceToken: String
    ) -> Bool {
        guard settings.enabled,
              let webhookURL = settings.options.webhookUrl,
              normalizedNotificationComparisonURL(webhookURL) == normalizedNotificationComparisonURL(pushURL)
        else { return false }

        return settings.options.customHeaders?.contains { header in
            header.key.caseInsensitiveCompare("X-Trawl-Token") == .orderedSame && header.value == deviceToken
        } == true
    }

    private func pushNotificationURL(from workerURL: String) throws -> String {
        let normalizedWorkerURL = try normalizedNotificationWorkerURL(from: workerURL)
        var components = URLComponents(string: normalizedWorkerURL)

        var pathParts = components?.path.split(separator: "/").map(String.init) ?? []
        if pathParts.last?.lowercased() == "push" {
            pathParts.removeLast()
        }
        pathParts.append("push")
        components?.path = "/" + pathParts.joined(separator: "/")

        guard let pushURL = components?.url?.absoluteString else {
            throw SeerrAPIError.badURL
        }

        return pushURL
    }

    private func normalizedNotificationWorkerURL(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? NotificationConstants.defaultWorkerURL : trimmed

        func isAllowedScheme(_ components: URLComponents) -> Bool {
            guard let scheme = components.scheme?.lowercased() else { return false }
            switch scheme {
            case "https":
                return true
            case "http":
                let host = components.host?.lowercased()
                return host == "localhost" || host == "127.0.0.1"
            default:
                return false
            }
        }

        let withHTTPS = candidate.hasPrefix("//") ? "https:\(candidate)" : "https://\(candidate)"
        let normalizedCandidate = (URLComponents(string: candidate)?.scheme?.isEmpty == false) ? candidate : withHTTPS

        guard let components = URLComponents(string: normalizedCandidate),
              let host = components.host,
              !host.isEmpty,
              isAllowedScheme(components),
              let canonicalURL = components.url?.absoluteString else {
            throw SeerrAPIError.badURL
        }

        return canonicalURL
    }

    private func normalizedNotificationComparisonURL(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else {
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        return components.url?.absoluteString ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var defaultWebhookTypes: Int {
        SeerrNotificationType.allCases.reduce(0) { $0 | $1.rawValue }
    }

    private static func validWebhookPayload(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard
            let data = value.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            return nil
        }

        return value
    }

    private static let trawlWebhookPayloadTemplate = """
    {
      "eventType": "{{notification_type}}",
      "event": "{{event}}",
      "subject": "{{subject}}",
      "message": "{{message}}",
      "image": "{{image}}",
      "mediaType": "{{media_type}}",
      "tmdbId": "{{media_tmdbid}}",
      "tvdbId": "{{media_tvdbid}}",
      "jellyfinMediaId": "{{media_jellyfinMediaId}}",
      "requestId": "{{request_id}}",
      "requestedBy": "{{requestedBy_username}}",
      "requestedByJellyfinUserId": "{{requestedBy_jellyfinUserId}}",
      "issueId": "{{issue_id}}",
      "issueType": "{{issue_type}}",
      "issueStatus": "{{issue_status}}",
      "comment": "{{comment_message}}"
    }
    """
}

#if DEBUG
extension SeerrServiceManager {
    enum PreviewState {
        case connected, connecting, error(String), notConfigured
    }

    static func preview(_ state: PreviewState = .connected) -> SeerrServiceManager {
        let mgr = SeerrServiceManager()
        switch state {
        case .connected:
            mgr.activeClient = .preview()
            mgr.activeProfileID = UUID()
            mgr.isConnected = true
            mgr.cachedUserCount = 8
        case .connecting:
            mgr.isConnecting = true
        case .error(let msg):
            mgr.connectionError = msg
        case .notConfigured:
            break
        }
        return mgr
    }
}
#endif
