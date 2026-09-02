//
//  DownloadsTips.swift
//  Trawl
//

import SwiftUI
import TipKit

/// Points at the Downloads title, which is secretly the switch between the combined
/// queue, SABnzbd and qBittorrent.
///
/// This is the tip with the strongest case for existing. `DownloadsView` deliberately
/// builds its switcher as a `Menu` styled to read as the navigation title, and its own
/// source notes the trade-off: "a menu hidden in a title is easy to overlook". The
/// chevron helps; a one-time sentence helps more.
///
/// It has no event rule, only a state rule, because there is nothing to wait for. A
/// user with two download clients configured can benefit from knowing this on their
/// first visit, and making them earn it by visiting three times would be withholding
/// the answer from exactly the people who need it.
struct DownloadsQueueSwitchTip: Tip {
    /// Whether there is more than one queue to switch between *right now*, and the
    /// title menu is actually on screen.
    ///
    /// Transient by design. The number of configured download clients is live state
    /// that changes when a server is added or removed, and a persisted copy would go
    /// stale the moment it did - offering to explain a switcher that is no longer
    /// there, or staying quiet after a second client is configured.
    @Parameter static var isEligible: Bool = false

    var id: String { TrawlTipID.downloadsSwitchQueues }

    var title: Text { Text("Switch download queues") }

    var message: Text? {
        Text("Tap the Downloads title to move between the combined queue, SABnzbd, and qBittorrent.")
    }

    var image: Image? { Image(systemName: "arrow.left.arrow.right") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
    }

    /// Once. The menu carries a chevron of its own afterwards, which is the standing
    /// affordance; this is only the introduction to it.
    var options: [Option] { MaxDisplayCount(1) }
}
