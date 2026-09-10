import Foundation
import Testing
@testable import Trawl

@Suite("Cleanuparr Tests")
struct CleanuparrTests {
    @Test("Documented v2 stats response decodes")
    func documentedStatsResponseDecodes() throws {
        let json = """
        {
          "events": {
            "total": 3,
            "byType": { "StalledStrike": 2, "QueueItemDeleted": 1 },
            "bySeverity": { "Warning": 2, "Information": 1 }
          },
          "strikes": {
            "total": 2,
            "byType": { "Stalled": 2 },
            "recovered": 1
          },
          "removals": {
            "total": 1,
            "byReason": { "Stalled": 1 }
          },
          "cleaned": {
            "total": 0,
            "byReason": {}
          },
          "searches": {
            "total": 1,
            "completed": 1,
            "failed": 0,
            "grabbed": 1,
            "byReason": { "Replacement": 1 }
          },
          "jobs": {
            "total": 4,
            "completed": 4,
            "failed": 0,
            "byType": {
              "QueueCleaner": {
                "total": 4,
                "completed": 4,
                "failed": 0,
                "lastRunAt": "2026-08-22T00:00:00Z",
                "nextRunAt": "2026-08-22T00:05:00Z"
              }
            }
          },
          "health": {
            "downloadClients": [{
              "id": "client-1",
              "name": "qBittorrent",
              "type": "qBittorrent",
              "isHealthy": true,
              "lastChecked": "2026-08-22T00:00:00Z",
              "responseTimeMs": 12.5,
              "errorMessage": null
            }],
            "arrInstances": []
          },
          "timeframeHours": 24,
          "generatedAt": "2026-08-22T00:00:00Z"
        }
        """

        let stats = try JSONDecoder().decode(CleanuparrStats.self, from: Data(json.utf8))

        #expect(stats.events.total == 3)
        #expect(stats.strikes.recovered == 1)
        #expect(stats.removals.byReason["Stalled"] == 1)
        #expect(stats.jobs.byType["QueueCleaner"]?.completed == 4)
        #expect(stats.health.downloadClients.first?.responseTimeMs == 12.5)
    }

    @Test("Cleanuparr URL normalization preserves a base path")
    func basePathIsPreserved() throws {
        let normalized = try ServerURLValidator.normalizedURLString(
            from: "https://example.com/cleanuparr/",
            allowsPath: true
        )

        #expect(normalized == "https://example.com/cleanuparr")
    }

    // MARK: - What the dashboard's controls actually send

    /// The dashboard's timeframe menu and dry-run toggle are only worth anything if
    /// they reach the server. Nothing else would notice if they did not: the screen
    /// re-reads stats either way, the numbers change plausibly, and "Last 24 Hours"
    /// quietly showing a week of events looks exactly like a quiet week.
    ///
    /// Driven over a real socket because `CleanuparrAPIClient` builds its own
    /// `HTTPTransport` with no session seam - the same reason `BazarrFixtureServer`
    /// exists, which is why this reuses it rather than standing up a fourth listener
    /// of its own.
    @Test("The timeframe and dry-run controls travel as query items")
    func statsRequestCarriesTheDashboardControls() async throws {
        let server = try await BazarrFixtureServer(label: "cleanuparr-stats") { _ in
            BazarrFixtureResponse.json(Self.emptyStatsJSON)
        }
        defer { server.stop() }
        let client = CleanuparrAPIClient(baseURL: server.baseURL, apiKey: "cleanuparr-key")

        _ = try await client.getStats(hours: 24, includeDryRun: true)

        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v2/stats")
        #expect(request.rawQuery.contains("hours=24"))
        #expect(request.rawQuery.contains("includeDryRun=true"))
    }

    /// Cleanuparr documents an hour range, and the client clamps to it rather than
    /// letting the server reject the call. The two ends matter in opposite ways: the
    /// menu's own "Last Year" is 8,760 hours and must survive untouched, while a zero
    /// - which no menu item produces but a future one might - has to become a real
    /// window rather than a request for nothing.
    @Test("Out-of-range hours are clamped, and the longest menu option is not")
    func statsHoursAreClampedToTheDocumentedRange() async throws {
        let server = try await BazarrFixtureServer(label: "cleanuparr-clamp") { _ in
            BazarrFixtureResponse.json(Self.emptyStatsJSON)
        }
        defer { server.stop() }
        let client = CleanuparrAPIClient(baseURL: server.baseURL, apiKey: "cleanuparr-key")

        _ = try await client.getStats(hours: 8_760)
        _ = try await client.getStats(hours: 100_000)
        _ = try await client.getStats(hours: 0)
        _ = try await client.getStats(hours: -12)

        let queries = server.requests.map(\.rawQuery)
        #expect(queries.count == 4)
        #expect(queries[0].contains("hours=8760"), "Last Year is inside the range and must not be clamped down.")
        #expect(queries[1].contains("hours=8760"))
        #expect(queries[2].contains("hours=1"))
        #expect(queries[3].contains("hours=1"))
        // The default is off, and it is sent explicitly rather than omitted.
        #expect(queries.allSatisfy { $0.contains("includeDryRun=false") })
    }

    /// A stats body with every collection empty. Real in shape - this is what a
    /// freshly installed Cleanuparr answers - and enough for the request-shape tests
    /// above to get past decoding.
    private static let emptyStatsJSON = #"""
    {
      "events": {"total": 0, "byType": {}, "bySeverity": {}},
      "strikes": {"total": 0, "byType": {}, "recovered": 0},
      "removals": {"total": 0, "byReason": {}},
      "cleaned": {"total": 0, "byReason": {}},
      "searches": {"total": 0, "completed": 0, "failed": 0, "grabbed": 0, "byReason": {}},
      "jobs": {"total": 0, "completed": 0, "failed": 0, "byType": {}},
      "health": {"downloadClients": [], "arrInstances": []},
      "timeframeHours": 168,
      "generatedAt": "2026-09-10T00:00:00Z"
    }
    """#
}
