import Foundation

nonisolated enum RemotePathEntryKind: String, Codable, Sendable {
    case directory
    case file
    case drive
    case networkShare
    case parent
    case unknown
}

