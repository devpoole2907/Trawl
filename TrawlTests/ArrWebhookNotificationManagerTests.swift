import Foundation
import Testing
@testable import Trawl

/// Manager-level webhook tests. They deliberately use a real connected profile
/// and the production `ArrServiceManager` public API, so each assertion covers
/// manager selection and payload assembly as well as the client, transport,
/// API-key header, status mapping, Codable, and wire endpoint.
@Suite("Arr webhook notification manager", .serialized)
@MainActor
struct ArrWebhookNotificationManagerTests {
    private let workerURL = "https://push.fixture.test/trawl"
    private let deviceToken = "device-token-for-webhook-tests"

    @Test("A matching Trawl webhook is configured and setup makes no mutation")
    func matchingWebhookIsConfiguredAndSetupIsIdempotent() async throws {
        let profileName = "Matching Sonarr"
        let existing = notification(
            id: 71,
            name: "Trawl (\(profileName))",
            serviceType: .sonarr,
            url: "https://push.fixture.test/trawl/push/",
            token: deviceToken,
            method: .string("POST"),
            headerKey: "key",
            headerValueKey: "value"
        )
        let response = try notificationListJSON([existing])

        try await withConnectedProfile(
            label: "matching-webhook",
            displayName: profileName,
            serviceType: .sonarr,
            handler: notificationHandler(listResponse: response)
        ) { manager, profile, server in
            let status = try await manager.notificationSetupStatus(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )
            let draft = try await manager.trawlNotification(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )
            try await manager.setupNotifications(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )

            guard case .configured = status else {
                Issue.record("Expected matching webhook to be configured.")
                return
            }
            #expect(draft.id == 71)
            #expect(draft.name == "Trawl (\(profileName))")
            #expect(draft.onSeriesAdd == false)
            #expect(draft.tags.isEmpty)
            #expect(server.requests(method: "GET", path: "/api/v3/notification").count == 3)
            #expect(server.requests(method: "POST", path: "/api/v3/notification").isEmpty)
            #expect(server.requests(method: "PUT", path: "/api/v3/notification/71").isEmpty)
            for request in server.requests(method: "GET", path: "/api/v3/notification") {
                #expect(request.apiKey == "webhook-test-key")
                #expect(request.body.isEmpty)
            }
        }
    }

    @Test("An unrelated notification is not mistaken for Trawl and setup creates the exact Sonarr webhook")
    func unrelatedWebhookCreatesExactSonarrWebhook() async throws {
        let profileName = "Create Sonarr"
        let unrelated = notification(
            id: 8,
            name: "Another App",
            serviceType: .sonarr,
            url: "https://elsewhere.example/push",
            token: "not-trawl"
        )
        let response = try notificationListJSON([unrelated])

        try await withConnectedProfile(
            label: "create-sonarr-webhook",
            displayName: profileName,
            serviceType: .sonarr,
            handler: notificationHandler(listResponse: response)
        ) { manager, profile, server in
            let status = try await manager.notificationSetupStatus(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )
            try await manager.setupNotifications(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )

            guard case .notAdded = status else {
                Issue.record("Expected unrelated webhook to leave Trawl unconfigured.")
                return
            }
            #expect(server.requests(method: "PUT", path: "/api/v3/notification/8").isEmpty)
            let request = try #require(server.requests(method: "POST", path: "/api/v3/notification").only)
            #expect(request.apiKey == "webhook-test-key")
            #expect(request.headers["content-type"] == "application/json")
            #expect(request.rawQuery.isEmpty)
            let body = try notificationDictionary(from: request)
            #expect(body == expectedNotificationDictionary(
                id: nil,
                name: "Trawl (\(profileName))",
                serviceType: .sonarr,
                deviceToken: deviceToken,
                workerURL: workerURL,
                tags: []
            ))
        }
    }

    @Test("A stale matching webhook needs update and setup PUTs its existing identifier")
    func staleMatchingWebhookUpdatesExactRadarrWebhook() async throws {
        let profileName = "Update Radarr"
        let existing = notification(
            id: 44,
            name: "Trawl (\(profileName))",
            serviceType: .radarr,
            url: "https://push.fixture.test/old/push",
            token: "old-token"
        )
        let response = try notificationListJSON([existing])

        try await withConnectedProfile(
            label: "update-radarr-webhook",
            displayName: profileName,
            serviceType: .radarr,
            handler: notificationHandler(listResponse: response)
        ) { manager, profile, server in
            let status = try await manager.notificationSetupStatus(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )
            try await manager.setupNotifications(
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )

            guard case .needsUpdate = status else {
                Issue.record("Expected stale matching webhook to need an update.")
                return
            }
            #expect(server.requests(method: "POST", path: "/api/v3/notification").isEmpty)
            let request = try #require(server.requests(method: "PUT", path: "/api/v3/notification/44").only)
            #expect(request.apiKey == "webhook-test-key")
            let body = try notificationDictionary(from: request)
            #expect(body == expectedNotificationDictionary(
                id: 44,
                name: "Trawl (\(profileName))",
                serviceType: .radarr,
                deviceToken: deviceToken,
                workerURL: workerURL,
                tags: []
            ))
        }
    }

    @Test("Saving a new Sonarr notification preserves selected triggers and tags while replacing auth fields")
    func saveCreatesSonarrNotificationWithSelectedTriggersAndTags() async throws {
        let profileName = "Draft Sonarr"
        let draft = notification(
            id: nil,
            name: "Ignored draft name",
            serviceType: .sonarr,
            url: "https://stale.example/push",
            token: "stale-token",
            onGrab: false,
            onDownload: false,
            onUpgrade: true,
            onRename: false,
            onHealthIssue: false,
            onApplicationUpdate: true,
            onSeriesAdd: true,
            onSeriesDelete: true,
            onEpisodeFileDelete: false,
            onEpisodeFileDeleteForUpgrade: true,
            tags: [4, 9]
        )

        try await withConnectedProfile(
            label: "save-sonarr-webhook",
            displayName: profileName,
            serviceType: .sonarr,
            handler: notificationHandler(listResponse: "[]")
        ) { manager, profile, server in
            try await manager.saveTrawlNotification(
                draft,
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )

            let request = try #require(server.requests(method: "POST", path: "/api/v3/notification").only)
            #expect(request.apiKey == "webhook-test-key")
            let body = try notificationDictionary(from: request)
            #expect(body == expectedNotificationDictionary(
                id: nil,
                name: "Trawl (\(profileName))",
                serviceType: .sonarr,
                deviceToken: deviceToken,
                workerURL: workerURL,
                onGrab: false,
                onDownload: false,
                onUpgrade: true,
                onRename: false,
                onHealthIssue: false,
                onApplicationUpdate: true,
                onSeriesAdd: true,
                onSeriesDelete: true,
                onEpisodeFileDelete: false,
                onEpisodeFileDeleteForUpgrade: true,
                tags: [4, 9]
            ))
        }
    }

    @Test("Saving an existing Radarr notification PUTs its identifier and keeps only movie triggers")
    func saveUpdatesRadarrNotificationWithSelectedTriggersAndTags() async throws {
        let profileName = "Draft Radarr"
        let draft = notification(
            id: 99,
            name: "Ignored draft name",
            serviceType: .radarr,
            url: "https://stale.example/push",
            token: "stale-token",
            onGrab: false,
            onDownload: true,
            onUpgrade: false,
            onRename: true,
            onHealthIssue: false,
            onApplicationUpdate: false,
            onMovieAdded: true,
            onMovieDelete: true,
            onMovieFileDelete: false,
            onMovieFileDeleteForUpgrade: true,
            tags: [2, 7]
        )

        try await withConnectedProfile(
            label: "save-radarr-webhook",
            displayName: profileName,
            serviceType: .radarr,
            handler: notificationHandler(listResponse: "[]")
        ) { manager, profile, server in
            try await manager.saveTrawlNotification(
                draft,
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )

            #expect(server.requests(method: "POST", path: "/api/v3/notification").isEmpty)
            let request = try #require(server.requests(method: "PUT", path: "/api/v3/notification/99").only)
            #expect(request.apiKey == "webhook-test-key")
            let body = try notificationDictionary(from: request)
            #expect(body == expectedNotificationDictionary(
                id: 99,
                name: "Trawl (\(profileName))",
                serviceType: .radarr,
                deviceToken: deviceToken,
                workerURL: workerURL,
                onGrab: false,
                onDownload: true,
                onUpgrade: false,
                onRename: true,
                onHealthIssue: false,
                onApplicationUpdate: false,
                onMovieAdded: true,
                onMovieDelete: true,
                onMovieFileDelete: false,
                onMovieFileDeleteForUpgrade: true,
                tags: [2, 7]
            ))
        }
    }

    @Test("Testing a notification uses the dedicated endpoint and fully normalized payload")
    func testNotificationUsesDedicatedEndpoint() async throws {
        let profileName = "Test Endpoint Sonarr"
        let draft = notification(
            id: 18,
            name: "Ignored draft name",
            serviceType: .sonarr,
            url: "https://stale.example/push",
            token: "stale-token",
            onGrab: false,
            onSeriesAdd: true,
            tags: [6]
        )

        try await withConnectedProfile(
            label: "test-notification-endpoint",
            displayName: profileName,
            serviceType: .sonarr,
            handler: notificationHandler(listResponse: "[]")
        ) { manager, profile, server in
            try await manager.testTrawlNotification(
                draft,
                for: profile,
                workerURL: workerURL,
                deviceToken: deviceToken
            )

            #expect(server.requests(method: "POST", path: "/api/v3/notification").isEmpty)
            let request = try #require(server.requests(method: "POST", path: "/api/v3/notification/test").only)
            #expect(request.apiKey == "webhook-test-key")
            let body = try notificationDictionary(from: request)
            #expect(body == expectedNotificationDictionary(
                id: 18,
                name: "Trawl (\(profileName))",
                serviceType: .sonarr,
                deviceToken: deviceToken,
                workerURL: workerURL,
                onGrab: false,
                onSeriesAdd: true,
                tags: [6]
            ))
        }
    }

    @Test(arguments: [401, 500])
    func testNotificationMapsHTTPFailures(statusCode: Int) async throws {
        let draft = notification(
            id: 33,
            name: "Failure draft",
            serviceType: .sonarr,
            url: "https://stale.example/push",
            token: "stale-token"
        )
        let failure = ArrWebhookNotificationFixtureResponse.error(status: statusCode, message: "fixture rejected test")

        try await withConnectedProfile(
            label: "test-notification-failure-\(statusCode)",
            displayName: "Failure Sonarr \(statusCode)",
            serviceType: .sonarr,
            handler: { request in
                let response: ArrWebhookNotificationFixtureResponse = switch request.path {
                case "/api/v3/notification/test": failure
                default: ArrWebhookNotificationFixtureServer.unexpected(request)
                }
                return ArrWebhookNotificationFixtureServer.connectedServiceResponse(for: request, otherwise: response)
            }
        ) { manager, profile, server in
            do {
                try await manager.testTrawlNotification(
                    draft,
                    for: profile,
                    workerURL: workerURL,
                    deviceToken: deviceToken
                )
                Issue.record("Expected HTTP \(statusCode) to fail notification test.")
            } catch let error as ArrError {
                switch (statusCode, error) {
                case (401, .invalidAPIKey):
                    break
                case (500, .serverError(let code, let message)):
                    #expect(code == 500)
                    #expect(message == #"{"message":"fixture rejected test"}"#)
                default:
                    Issue.record("Unexpected Arr error for HTTP \(statusCode): \(error.localizedDescription)")
                }
            }

            let request = try #require(server.requests(method: "POST", path: "/api/v3/notification/test").only)
            #expect(request.apiKey == "webhook-test-key")
        }
    }

    // MARK: - Real connection harness

    private func withConnectedProfile(
        label: String,
        displayName: String,
        serviceType: ArrServiceType,
        handler: @escaping ArrWebhookNotificationFixtureServer.Handler,
        operation: @MainActor (ArrServiceManager, ArrServiceProfile, ArrWebhookNotificationFixtureServer) async throws -> Void
    ) async throws {
        let server = try await ArrWebhookNotificationFixtureServer(label: label, handler: handler)
        defer { server.stop() }

        let profile = ArrServiceProfile(displayName: displayName, hostURL: server.baseURL, serviceType: serviceType)
        let manager = ArrServiceManager()
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "webhook-test-key")
        do {
            await manager.connectService(profile)
            #expect(
                manager.isConnected(serviceType, profileID: profile.id),
                "Connection failed: \(manager.connectionError(serviceType) ?? "no error"). Requests: \(server.requests)"
            )
            try await operation(manager, profile, server)
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        } catch {
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }
    }

    private func notificationHandler(
        listResponse: String
    ) -> ArrWebhookNotificationFixtureServer.Handler {
        { request in
            let response: ArrWebhookNotificationFixtureResponse = switch (request.method, request.path) {
            case ("GET", "/api/v3/notification"):
                .json(listResponse)
            case ("POST", "/api/v3/notification"):
                .json(request.body, status: 201)
            case ("PUT", let path) where path.hasPrefix("/api/v3/notification/"):
                .json(request.body)
            case ("POST", "/api/v3/notification/test"):
                .empty
            default:
                ArrWebhookNotificationFixtureServer.unexpected(request)
            }
            return ArrWebhookNotificationFixtureServer.connectedServiceResponse(for: request, otherwise: response)
        }
    }

    // MARK: - Remote JSON fixtures and exact-wire expectations

    private func notification(
        id: Int?,
        name: String,
        serviceType: ArrServiceType,
        url: String,
        token: String,
        method: JSONValue = .number(1),
        headerKey: String = "Key",
        headerValueKey: String = "Value",
        onGrab: Bool = true,
        onDownload: Bool = true,
        onUpgrade: Bool = true,
        onRename: Bool = true,
        onHealthIssue: Bool = true,
        onApplicationUpdate: Bool = true,
        onSeriesAdd: Bool? = nil,
        onSeriesDelete: Bool? = nil,
        onEpisodeFileDelete: Bool? = nil,
        onEpisodeFileDeleteForUpgrade: Bool? = nil,
        onMovieAdded: Bool? = nil,
        onMovieDelete: Bool? = nil,
        onMovieFileDelete: Bool? = nil,
        onMovieFileDeleteForUpgrade: Bool? = nil,
        tags: [Int] = []
    ) -> ArrNotification {
        ArrNotification(
            id: id,
            name: name,
            onGrab: onGrab,
            onDownload: onDownload,
            onUpgrade: onUpgrade,
            onRename: onRename,
            onHealthIssue: onHealthIssue,
            onApplicationUpdate: onApplicationUpdate,
            onSeriesAdd: serviceType == .sonarr ? onSeriesAdd : nil,
            onSeriesDelete: serviceType == .sonarr ? onSeriesDelete : nil,
            onEpisodeFileDelete: serviceType == .sonarr ? onEpisodeFileDelete : nil,
            onEpisodeFileDeleteForUpgrade: serviceType == .sonarr ? onEpisodeFileDeleteForUpgrade : nil,
            onMovieAdded: serviceType == .radarr ? onMovieAdded : nil,
            onMovieDelete: serviceType == .radarr ? onMovieDelete : nil,
            onMovieFileDelete: serviceType == .radarr ? onMovieFileDelete : nil,
            onMovieFileDeleteForUpgrade: serviceType == .radarr ? onMovieFileDeleteForUpgrade : nil,
            includeHealthWarnings: true,
            implementation: "Webhook",
            configContract: "WebhookSettings",
            fields: [
                ArrNotificationField(name: "url", value: .string(url)),
                ArrNotificationField(name: "method", value: method),
                ArrNotificationField(name: "headers", value: .array([
                    .object([
                        headerKey: .string("X-Trawl-Token"),
                        headerValueKey: .string(token)
                    ])
                ]))
            ],
            tags: tags
        )
    }

    private func notificationListJSON(_ notifications: [ArrNotification]) throws -> String {
        String(decoding: try JSONEncoder().encode(notifications), as: UTF8.self)
    }

    private func notificationDictionary(
        from request: ArrWebhookNotificationFixtureRequest
    ) throws -> NSDictionary {
        guard let body = request.jsonObject() else {
            throw ArrError.invalidResponse
        }
        return NSDictionary(dictionary: body)
    }

    private func expectedNotificationDictionary(
        id: Int?,
        name: String,
        serviceType: ArrServiceType,
        deviceToken: String,
        workerURL: String,
        onGrab: Bool = true,
        onDownload: Bool = true,
        onUpgrade: Bool = true,
        onRename: Bool = true,
        onHealthIssue: Bool = true,
        onApplicationUpdate: Bool = true,
        onSeriesAdd: Bool = false,
        onSeriesDelete: Bool = false,
        onEpisodeFileDelete: Bool = false,
        onEpisodeFileDeleteForUpgrade: Bool = false,
        onMovieAdded: Bool = false,
        onMovieDelete: Bool = false,
        onMovieFileDelete: Bool = false,
        onMovieFileDeleteForUpgrade: Bool = false,
        tags: [Int]
    ) -> NSDictionary {
        var dictionary: [String: Any] = [
            "name": name,
            "onGrab": onGrab,
            "onDownload": onDownload,
            "onUpgrade": onUpgrade,
            "onRename": onRename,
            "onHealthIssue": onHealthIssue,
            "onApplicationUpdate": onApplicationUpdate,
            "includeHealthWarnings": true,
            "implementation": "Webhook",
            "configContract": "WebhookSettings",
            "fields": [
                ["name": "url", "value": "\(workerURL)/push"],
                ["name": "method", "value": 1],
                ["name": "headers", "value": [["Key": "X-Trawl-Token", "Value": deviceToken]]]
            ],
            "tags": tags
        ]
        if let id { dictionary["id"] = id }
        switch serviceType {
        case .sonarr:
            dictionary["onSeriesAdd"] = onSeriesAdd
            dictionary["onSeriesDelete"] = onSeriesDelete
            dictionary["onEpisodeFileDelete"] = onEpisodeFileDelete
            dictionary["onEpisodeFileDeleteForUpgrade"] = onEpisodeFileDeleteForUpgrade
        case .radarr:
            dictionary["onMovieAdded"] = onMovieAdded
            dictionary["onMovieDelete"] = onMovieDelete
            dictionary["onMovieFileDelete"] = onMovieFileDelete
            dictionary["onMovieFileDeleteForUpgrade"] = onMovieFileDeleteForUpgrade
        case .prowlarr, .bazarr:
            Issue.record("This test helper is for Sonarr and Radarr only.")
        }
        return NSDictionary(dictionary: dictionary)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
