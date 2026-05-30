import AppIntents

// MARK: - Scope Option

/// Whether the calendar widget shows every upcoming release or only monitored items.
enum CalendarScopeOption: String, AppEnum {
    case all
    case monitored

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Releases")
    static let caseDisplayRepresentations: [CalendarScopeOption: DisplayRepresentation] = [
        .all: "All Releases",
        .monitored: "Monitored Only"
    ]

    /// Maps to the Sonarr/Radarr calendar `unmonitored` query flag.
    var includeUnmonitored: Bool { self == .all }
}

// MARK: - Configuration Intent

struct SelectCalendarScopeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Upcoming Releases"
    static let description = IntentDescription("Choose whether to show all upcoming releases or only monitored ones.")

    @Parameter(title: "Show", default: .all)
    var scope: CalendarScopeOption
}
