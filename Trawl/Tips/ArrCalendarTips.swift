//
//  ArrCalendarTips.swift
//  Trawl
//

import SwiftUI
import TipKit

/// Points at the Calendar's Subscribe button, which produces a real iCal feed.
///
/// The button is in the bottom bar and reads as a single word, so it is easy to take
/// for a toggle or a filter. What it actually does - hand you a subscribable Sonarr or
/// Radarr feed, with a choice of releases and filters - is worth a sentence.
///
/// Gated on a *second* visit rather than the first. Someone who opens the Calendar
/// once may have been passing through; someone who comes back is tracking releases,
/// which is precisely the person a subscription is for. And the tip fires only while a
/// service is actually connected, because the sheet it leads to has nothing to offer
/// otherwise.
struct ArrCalendarSubscribeTip: Tip {
    /// Whether at least one Sonarr or Radarr instance is connected *right now*.
    ///
    /// Transient: connection state changes while the app is running, and a persisted
    /// copy would offer a subscription for a server that has since gone away.
    @Parameter static var isEligible: Bool = false

    var id: String { TrawlTipID.calendarSubscribe }

    var title: Text { Text("Add releases to Calendar") }

    var message: Text? {
        Text("Subscribe to a Sonarr or Radarr feed and choose the releases and filters you want.")
    }

    var image: Image? { Image(systemName: "calendar.badge.plus") }

    var rules: [Rule] {
        #Rule(Self.$isEligible) { $0 == true }
        #Rule(TrawlTipEvents.calendarOpened) { $0.donations.count >= 2 }
    }

    var options: [Option] { MaxDisplayCount(1) }
}
