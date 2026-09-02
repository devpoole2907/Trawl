//
//  ArrLibraryTips.swift
//  Trawl
//
//  The two tips that share the library list's one inline slot, in `ArrMediaListView`.
//
//  They are grouped `.firstAvailable` at the point of use rather than ordered, and
//  that choice is load-bearing: an ordered group would make the quick-actions tip wait
//  on the blended-library tip, which a single-instance user can never become eligible
//  for. Those users would simply never hear about the swipe actions. First-available
//  shows whichever one currently qualifies.

import SwiftUI
import TipKit

/// Explains the per-server badges on a blended library row.
///
/// Trawl merges the same title across every configured Sonarr or Radarr instance into
/// one row, and `ArrInstanceBadgeRow` carries a badge per server - filled when that
/// server has the title downloaded. That is a genuinely dense piece of visual
/// language, and nothing else on the screen explains it.
///
/// One tip covers both Series and Movies. It is the same badge grammar in both, so a
/// user who has had it explained under Series should not be told again under Movies -
/// and because a `Tip`'s persisted state is keyed by its `id`, one type with one
/// stable ID is all it takes to make seeing it in either place count for both.
struct ArrBlendedLibraryTip: Tip {
    /// Whether this library is currently blended, populated, and not mid-selection.
    ///
    /// All three are live view state, so all three are transient. A persisted flag
    /// would let the tip appear over a loading spinner, an empty library, or a
    /// selection the user is halfway through - each of which is a worse moment to
    /// interrupt than any of them is worth.
    @Parameter static var isEligible: Bool = false

    var id: String { TrawlTipID.arrBlendedLibrary }

    var title: Text { Text("Your libraries are blended") }

    var message: Text? {
        Text("Badges show which server tracks each title—filled means downloaded. Tap the title to filter by server.")
    }

    var image: Image? { Image(systemName: "square.stack.3d.up") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
    }

    var options: [Option] { MaxDisplayCount(1) }
}

/// Advertises the row swipe actions, to someone who has demonstrably been doing it the
/// long way.
///
/// The threshold is what makes this worth showing at all. Monitor, unmonitor and
/// delete are all available from a row without opening it, and the tip is aimed at a
/// user who has opened three detail screens - the observable signature of not knowing
/// that. Showing it on first launch would be a feature tour; showing it on the third
/// round trip is an answer to something the user has just done three times.
struct ArrLibraryQuickActionsTip: Tip {
    /// Whether this library currently has rows and is not mid-selection.
    @Parameter static var isEligible: Bool = false

    var id: String { TrawlTipID.arrLibraryQuickActions }

    var title: Text { Text("Quick library changes") }

    /// The gesture differs by platform, so the copy has to. Telling a Mac user to
    /// swipe is worse than saying nothing: they will try it, it will not work, and the
    /// feature stays undiscovered with the added impression that it is broken.
    var message: Text? {
        #if os(macOS)
        Text("Control-click a title to monitor, unmonitor, or remove it without opening details.")
        #else
        Text("Swipe a title to monitor, unmonitor, or remove it without opening details.")
        #endif
    }

    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
        // Three, not one: the point is to catch a habit, and one detail opening is
        // just as likely to be someone who wanted the detail screen.
        #Rule(TrawlTipEvents.libraryDetailOpened) { $0.donations.count >= 3 }
    }

    var options: [Option] { MaxDisplayCount(1) }
}
