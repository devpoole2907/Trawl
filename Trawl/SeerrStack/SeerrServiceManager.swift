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
        try await rewriteLegacyWebhookPayloadIfNeeded(
            existing: settings,
            client: activeClient,
            pushURL: pushURL,
            deviceToken: deviceToken
        )
    }

    func testTrawlWebhookNotificationSettings(
        _ settings: SeerrWebhookNotificationSettings,
        workerURL: String,
        deviceToken: String
    ) async throws {
        guard let activeClient else { throw SeerrAPIError.unauthorized }
        let pushURL = try pushNotificationURL(from: workerURL)
        let payload = webhookSettingsPayload(existing: settings, pushURL: pushURL, deviceToken: deviceToken)
        do {
            try await activeClient.testWebhookNotificationSettings(payload)
        } catch {
            let enriched = await enrichedWebhookTestError(from: error, using: activeClient)
            guard Self.isLegacyWebhookPayloadError(enriched) else {
                throw enriched
            }

            do {
                let legacyPayload = webhookSettingsPayload(
                    existing: settings,
                    pushURL: pushURL,
                    deviceToken: deviceToken,
                    payloadFormat: .legacyJSONString
                )
                try await activeClient.testWebhookNotificationSettings(legacyPayload)
            } catch {
                throw await enrichedWebhookTestError(from: error, using: activeClient)
            }
        }
    }

    private func webhookSettingsPayload(
        existing: SeerrWebhookNotificationSettings,
        pushURL: String,
        deviceToken: String,
        payloadFormat: SeerrWebhookPayloadFormat = .current
    ) -> SeerrWebhookNotificationSettings {
        return SeerrWebhookNotificationSettings(
            enabled: true,
            types: (existing.types == 0 ? Self.defaultWebhookTypes : existing.types) | SeerrNotificationType.testNotification.rawValue,
            options: SeerrWebhookNotificationOptions(
                webhookUrl: pushURL,
                authHeader: Self.basicAuthHeader(deviceToken: deviceToken),
                jsonPayload: Self.webhookPayloadValue(format: payloadFormat),
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

        if Self.authHeaderMatches(settings.options.authHeader, deviceToken: deviceToken) {
            return true
        }

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

    private static func basicAuthHeader(deviceToken: String) -> String {
        let credentials = "trawl:\(deviceToken)"
        let encodedCredentials = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encodedCredentials)"
    }

    private static func authHeaderMatches(_ value: String?, deviceToken: String) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) == basicAuthHeader(deviceToken: deviceToken)
    }

    private func rewriteLegacyWebhookPayloadIfNeeded(
        existing: SeerrWebhookNotificationSettings,
        client: SeerrAPIClient,
        pushURL: String,
        deviceToken: String
    ) async throws {
        do {
            _ = try await client.getWebhookNotificationSettings()
        } catch let error as SeerrAPIError {
            guard case .decode = error else { return }

            let legacyPayload = webhookSettingsPayload(
                existing: existing,
                pushURL: pushURL,
                deviceToken: deviceToken,
                payloadFormat: .legacyJSONString
            )
            try await client.updateWebhookNotificationSettings(legacyPayload)
        }
    }

    private func enrichedWebhookTestError(from error: any Error, using client: SeerrAPIClient) async -> any Error {
        guard
            let logs = try? await client.getLogs(take: 20, filter: "debug", search: "webhook"),
            let detail = logs.compactMap(\.webhookFailureDetail).first
        else {
            return error
        }

        return SeerrWebhookNotificationTestError(baseMessage: error.localizedDescription, detail: detail)
    }

    private static func isLegacyWebhookPayloadError(_ error: any Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("[object object]") && message.contains("valid json")
    }

    private static func webhookPayloadValue(format: SeerrWebhookPayloadFormat) -> String {
        switch format {
        case .current:
            return trawlWebhookPayloadTemplate
        case .legacyJSONString:
            guard
                let data = try? JSONEncoder().encode(trawlWebhookPayloadTemplate),
                let string = String(data: data, encoding: .utf8)
            else {
                return trawlWebhookPayloadTemplate
            }
            return string
        }
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

private enum SeerrWebhookPayloadFormat {
    case current
    case legacyJSONString
}

private struct SeerrWebhookNotificationTestError: LocalizedError {
    let baseMessage: String
    let detail: String

    var errorDescription: String? {
        "\(baseMessage)\n\nSeerr log: \(detail)"
    }
}

private extension SeerrServerLogEntry {
    var webhookFailureDetail: String? {
        let searchable = [label, message, prettyPrintedData]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard searchable.contains("webhook") || searchable.contains("notification") else {
            return nil
        }

        if let dataDetail = data?.webhookFailureDetail, !dataDetail.isEmpty {
            return dataDetail
        }

        return message
    }
}

private extension SeerrJSONValue {
    var webhookFailureDetail: String? {
        guard case .object(let object) = self else { return nil }

        let preferredKeys = ["errorMessage", "message", "response", "error", "code"]
        let details = preferredKeys.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            return value.compactDescription
        }

        if !details.isEmpty {
            return details.joined(separator: " | ")
        }

        return prettyPrinted
    }

    var compactDescription: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return String(value)
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return value
        case .array, .object:
            return prettyPrinted
        }
    }
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
