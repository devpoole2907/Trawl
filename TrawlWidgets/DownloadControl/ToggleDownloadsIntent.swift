import AppIntents
import WidgetKit

/// Errors the Control Center control surfaces. Mirrors the message style of
/// `ArrIntentError` in the app target: plain text, never a host name or key.
nonisolated enum DownloadControlIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noClientConfigured
    case actionFailed

    var message: String {
        switch self {
        case .noClientConfigured:
            return "No qBittorrent or SABnzbd client is configured in Trawl. Add one in Trawl's settings first."
        case .actionFailed:
            return "Couldn't reach your download clients. Check that they're running."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}

/// Pauses or resumes every configured download client at once.
///
/// The value is the *running* position of the switch, matching `ControlWidgetToggle`:
/// `true` resumes, `false` pauses. It acts on the blended qBittorrent + SABnzbd set
/// the download widgets already aggregate, so the control agrees with the tiles
/// sitting next to it rather than silently covering one client.
struct ToggleDownloadsIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Pause or Resume Downloads"
    static let description = IntentDescription(
        "Pauses or resumes every qBittorrent and SABnzbd client configured in Trawl."
    )

    @Parameter(title: "Downloading")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        let state = await WidgetDataFetcher.fetchDownloadControlState()

        switch DownloadControlState.action(requestedRunning: value, state: state) {
        case .unavailable:
            throw DownloadControlIntentError.noClientConfigured
        case .pause:
            try await applyPaused(true)
        case .resume:
            try await applyPaused(false)
        }

        // The control's own value provider is cached, so ask Control Center to
        // re-read it rather than leaving the switch showing the previous position.
        ControlCenter.shared.reloadControls(ofKind: DownloadsPauseControl.kind)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

    private func applyPaused(_ paused: Bool) async throws {
        do {
            try await WidgetDataFetcher.setDownloadsPaused(paused)
        } catch {
            throw DownloadControlIntentError.actionFailed
        }
    }
}
