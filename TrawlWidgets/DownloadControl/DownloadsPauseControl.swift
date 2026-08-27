import AppIntents
import SwiftUI
import WidgetKit

/// Control Center toggle for pause/resume-all across every download client.
struct DownloadsPauseControl: ControlWidget {
    nonisolated static let kind = "com.poole.james.Trawl.DownloadsPauseControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: DownloadsPauseValueProvider()) { state in
            ControlWidgetToggle(
                "Downloads",
                isOn: state.isRunning,
                action: ToggleDownloadsIntent()
            ) { isRunning in
                Label(
                    state.isAvailable ? state.statusLabel : "No Client",
                    systemImage: isRunning ? "arrow.down.circle.fill" : "pause.circle.fill"
                )
            }
            .tint(.blue)
            .disabled(!state.isAvailable)
        }
        .displayName("Pause Downloads")
        .description("Pause or resume every qBittorrent and SABnzbd download.")
    }
}

/// Reads the blended pause state. Control Center calls this off its own schedule,
/// so it must never throw for an unreachable client: `DownloadControlState`
/// carries "nothing answered" as a value the tile can render.
struct DownloadsPauseValueProvider: ControlValueProvider {
    let previewValue = DownloadControlState(
        runningTorrentCount: 3,
        stoppedTorrentCount: 0,
        sabQueuePausedFlags: [false],
        reachableClientCount: 2
    )

    func currentValue() async throws -> DownloadControlState {
        await WidgetDataFetcher.fetchDownloadControlState()
    }
}
