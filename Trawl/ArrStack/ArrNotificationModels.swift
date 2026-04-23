import Foundation

struct ArrNotification: Codable, Identifiable, Sendable {
    let id: Int?
    let name: String
    let onGrab: Bool
    let onDownload: Bool
    let onUpgrade: Bool?
    let onRename: Bool?
    let onHealthIssue: Bool?
    let onApplicationUpdate: Bool?
    
    // Sonarr specific
    let onSeriesDelete: Bool?
    let onEpisodeFileDelete: Bool?
    let onEpisodeFileDeleteForUpgrade: Bool?
    
    // Radarr specific
    let onMovieDelete: Bool?
    let onMovieFileDelete: Bool?
    let onMovieFileDeleteForUpgrade: Bool?

    let implementation: String
    let configContract: String
    let fields: [ArrNotificationField]
    let tags: [Int]
}

struct ArrNotificationField: Codable, Sendable {
    let name: String
    let value: JSONValue?
}

// Helper to find a specific field value
extension ArrNotification {
    func fieldValue(for name: String) -> String? {
        if let field = fields.first(where: { $0.name == name }),
           case .string(let val) = field.value {
            return val
        }
        return nil
    }
}
