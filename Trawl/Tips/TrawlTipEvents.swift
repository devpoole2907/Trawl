//
//  TrawlTipEvents.swift
//  Trawl
//
//  The interactions Trawl counts towards showing a tip.
//
//  Events are TipKit's *persistent* half: a donation survives relaunch, which is what
//  lets a rule say "after the third time you did this". Current app state - whether
//  two servers are configured right now, whether this library has any rows - is the
//  transient half and belongs in a `@Parameter` on the tip itself. Mixing the two up
//  is the usual way a tip ends up either never firing or firing on a blank screen.
//
//  Both events live here rather than on the tips that consume them because both are
//  donated from somewhere else in the app, and one of them is shared across two media
//  types on purpose.

import TipKit

nonisolated enum TrawlTipEvents {
    /// A real Sonarr or Radarr detail screen was opened.
    ///
    /// Deliberately one event for both media types. The gesture the quick-actions tip
    /// advertises is identical on a series row and a movie row, so someone who has
    /// opened three movie details has demonstrated exactly the habit the tip is meant
    /// to interrupt - counting series and movies separately would make a heavy Radarr
    /// user wait twice as long to be told about a swipe that has been there all along.
    static let libraryDetailOpened = Tips.Event(id: "trawl.arr.library-detail-opened")

    /// The Calendar screen appeared, connected and rendering real data.
    ///
    /// Only a connected calendar counts. A visit that landed on "No Services
    /// Configured" or "Services Unreachable" is not evidence of interest in
    /// subscribing to a feed - it is evidence the app could not show one.
    static let calendarOpened = Tips.Event(id: "trawl.calendar.opened")
}
