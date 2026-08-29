import SwiftUI

/// What the Downloads tab's toolbar can currently do, published by whichever list
/// is on screen.
///
/// The tab shows one of three lists — the blended queue, SABnzbd's queue, or
/// qBittorrent's torrents — and they used to be three separate screens, each with
/// its own toolbar. Switching lists therefore replaced the entire chrome: Select
/// existed only on Torrents, Client Management and Blocklist only on the blended
/// list, and "Pause All" was the sole occupant of SABnzbd's overflow. The tab now
/// owns one toolbar for all three, and each list registers what it can do here.
///
/// The list publishes *capabilities and closures*, never views: the toolbar's
/// shape belongs to the tab, and only its contents flex. That is what keeps the
/// buttons the same buttons rather than a new set per destination.
@MainActor
@Observable
final class DownloadsListChrome {
    /// Whether the visible list supports multi-select at all. A list with no rows
    /// still supports it — the button is disabled rather than absent, so the
    /// toolbar does not reshuffle as rows arrive.
    var canSelect = false
    var isSelecting = false
    var selectedCount = 0
    var totalCount = 0

    /// Torrents can be rechecked; nothing else can. Actions the visible list does
    /// not support are dropped rather than shown disabled — a permanently greyed
    /// Recheck on a SABnzbd queue is noise, where a greyed Pause with nothing
    /// selected is a hint.
    var supportsRecheck = false
    var supportsPauseResume = false

    var beginSelecting: (() -> Void)?
    var endSelecting: (() -> Void)?
    var toggleSelectAll: (() -> Void)?
    var pauseSelected: (() -> Void)?
    var resumeSelected: (() -> Void)?
    var recheckSelected: (() -> Void)?
    var deleteSelected: (() -> Void)?

    /// Entries the visible list contributes to the shared overflow menu — SABnzbd's
    /// Pause All, qBittorrent's alternative speed mode. Described rather than
    /// built, so the menu stays the tab's.
    var extraActions: [ExtraAction] = []

    struct ExtraAction: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        /// Set for a toggle; nil renders a plain button.
        var isOn: Bool?
        var isEnabled = true
        let perform: () -> Void
    }

    var hasSelection: Bool { selectedCount > 0 }

    var selectAllTitle: String {
        selectedCount == totalCount && totalCount > 0 ? "Deselect All" : "Select All"
    }

    /// Called when a list disappears so the next one starts from nothing. Without
    /// this a destination inherits the previous list's buttons for a frame, and a
    /// stale closure can act on rows that are no longer on screen.
    func reset() {
        canSelect = false
        isSelecting = false
        selectedCount = 0
        totalCount = 0
        supportsRecheck = false
        supportsPauseResume = false
        beginSelecting = nil
        endSelecting = nil
        toggleSelectAll = nil
        pauseSelected = nil
        resumeSelected = nil
        recheckSelected = nil
        deleteSelected = nil
        extraActions = []
    }
}
