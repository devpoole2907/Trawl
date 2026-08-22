import Foundation

/// The documented response from `GET /api/v2/stats`.
nonisolated struct CleanuparrStats: Decodable, Sendable {
    nonisolated struct Events: Decodable, Sendable {
        let total: Int
        let byType: [String: Int]
        let bySeverity: [String: Int]
    }

    nonisolated struct Strikes: Decodable, Sendable {
        let total: Int
        let byType: [String: Int]
        let recovered: Int
    }

    nonisolated struct Rollup: Decodable, Sendable {
        let total: Int
        let byReason: [String: Int]
    }

    nonisolated struct Searches: Decodable, Sendable {
        let total: Int
        let completed: Int
        let failed: Int
        let grabbed: Int
        let byReason: [String: Int]
    }

    nonisolated struct Jobs: Decodable, Sendable {
        nonisolated struct Job: Decodable, Sendable {
            let total: Int
            let completed: Int
            let failed: Int
            let lastRunAt: String?
            let nextRunAt: String?
        }

        let total: Int
        let completed: Int
        let failed: Int
        let byType: [String: Job]
    }

    nonisolated struct Health: Decodable, Sendable {
        nonisolated struct Service: Decodable, Sendable, Identifiable {
            let id: String
            let name: String
            let type: String
            let isHealthy: Bool
            let lastChecked: String?
            let responseTimeMs: Double?
            let errorMessage: String?
        }

        let downloadClients: [Service]
        let arrInstances: [Service]
    }

    let events: Events
    let strikes: Strikes
    let removals: Rollup
    let cleaned: Rollup
    let searches: Searches
    let jobs: Jobs
    let health: Health
    let timeframeHours: Int
    let generatedAt: String
}
