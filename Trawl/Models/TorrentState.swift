import Foundation
import SwiftUI

enum TorrentState: String, Codable, CaseIterable {
    case error
    case missingFiles
    case uploading
    case pausedUP
    case stoppedUP  // qBittorrent v5+
    case queuedUP
    case stalledUP
    case checkingUP
    case forcedUP
    case allocating
    case downloading
    case metaDL
    case pausedDL
    case stoppedDL  // qBittorrent v5+
    case queuedDL
    case stalledDL
    case checkingDL
    case forcedDL
    case checkingResumeData
    case moving
    case unknown

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TorrentState(rawValue: raw) ?? .unknown
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .error: "Error"
        case .missingFiles: "Missing Files"
        case .uploading: "Seeding"
        case .pausedUP: "Paused"
        case .stoppedUP: "Stopped"
        case .queuedUP: "Queued"
        case .stalledUP: "Seeding (stalled)"
        case .checkingUP: "Checking"
        case .forcedUP: "Force Seeding"
        case .allocating: "Allocating"
        case .downloading: "Downloading"
        case .metaDL: "Fetching Metadata"
        case .pausedDL: "Paused"
        case .stoppedDL: "Stopped"
        case .queuedDL: "Queued"
        case .stalledDL: "Downloading (stalled)"
        case .checkingDL: "Checking"
        case .forcedDL: "Force Downloading"
        case .checkingResumeData: "Checking Resume Data"
        case .moving: "Moving"
        case .unknown: "Unknown"
        }
    }

    /// Semantic color for UI badges
    var color: Color {
        switch self {
        case .downloading, .forcedDL, .metaDL: .blue
        case .uploading, .forcedUP: .green
        case .pausedDL, .pausedUP, .stoppedDL, .stoppedUP: .secondary
        case .stalledDL, .stalledUP: .orange
        case .queuedDL, .queuedUP: .secondary
        case .checkingDL, .checkingUP, .checkingResumeData: .yellow
        case .error, .missingFiles: .red
        case .allocating, .moving: .purple
        case .unknown: .gray
        }
    }

    /// Filter category mapping
    var filterCategory: TorrentFilter {
        switch self {
        case .downloading, .forcedDL, .metaDL, .stalledDL, .queuedDL, .checkingDL, .allocating:
            .downloading
        case .uploading, .forcedUP, .stalledUP, .queuedUP, .checkingUP:
            .seeding
        case .pausedDL, .pausedUP, .stoppedDL, .stoppedUP:
            .paused
        case .error, .missingFiles:
            .errored
        case .checkingResumeData, .moving, .unknown:
            .all
        }
    }

    /// Whether this torrent is fully downloaded (seeding-side states)
    var isCompleted: Bool {
        switch self {
        case .uploading, .pausedUP, .stoppedUP, .queuedUP, .stalledUP, .checkingUP, .forcedUP:
            true
        default:
            false
        }
    }

    /// SF Symbol name for state representation
    var systemImage: String {
        switch self {
        case .downloading, .forcedDL, .metaDL: "arrow.down.circle.fill"
        case .uploading, .forcedUP: "arrow.up.circle.fill"
        case .pausedDL, .pausedUP, .stoppedDL, .stoppedUP: "pause.circle.fill"
        case .stalledDL, .stalledUP: "exclamationmark.circle"
        case .queuedDL, .queuedUP: "clock.fill"
        case .checkingDL, .checkingUP, .checkingResumeData: "magnifyingglass.circle.fill"
        case .error, .missingFiles: "xmark.circle.fill"
        case .allocating: "internaldrive.fill"
        case .moving: "arrow.right.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

enum TorrentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Downloading"
    case seeding = "Seeding"
    case paused = "Paused"
    case completed = "Completed"
    case errored = "Errored"

    var id: String { rawValue }
}
