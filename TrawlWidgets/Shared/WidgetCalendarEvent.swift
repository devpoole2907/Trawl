import Foundation

/// Codable representation of a calendar event for use in WidgetKit timeline entries.
/// Mirrors the fields of the main app's fileprivate `CalendarEvent` enum, with
/// Color represented as a name string so the struct stays Codable and Sendable.
struct WidgetCalendarEvent: Codable, Identifiable, Sendable {
    let id: String
    let date: Date
    let title: String
    let subtitle: String?
    let posterURL: URL?
    /// SF Symbol name — "tv" for episodes, "film" for movies
    let placeholderIcon: String
    /// Color name string — "purple", "blue", "indigo", "orange"
    let accentColorName: String
    /// Release-kind label shown as a chip — nil for episodes
    let badgeLabel: String?
    let isDownloaded: Bool
}
