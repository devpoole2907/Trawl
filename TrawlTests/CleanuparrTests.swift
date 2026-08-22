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
}
