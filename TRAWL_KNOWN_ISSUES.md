# Trawl – known issues, deliberately deferred

Defects that are understood, reproduced, and *not* being fixed yet. Each one says why
it is parked and what would un-park it. A defect only belongs here once someone has
looked at it and decided to wait — an unexamined bug is not a known issue, it is an
unknown one.

If a test covers the deferred behaviour it is **skipped, not deleted**, and the skip
names this file. That way the coverage comes back on its own the day the cause is
fixed, instead of being quietly lost.

---

## iPad: the notification bar covers any screen's own bottom bar

**Status:** cause removed, 4 Sep 2026 — **not yet verified by a test run.** Direction 1
below was taken while fixing a second symptom of the same bar (it covered the sidebar's
own last rows, so Settings could not be selected). The skip is still in place until the
journey has actually been run against the change.

**Symptom.** On iPad, a person cannot resolve a Seerr issue. Tapping **Resolve Issue**
opens the notifications sheet instead. Nothing resolves.

**What is actually happening.** `ContentView`'s notification accessory is a bar across
the *whole width* of the window, not just the sidebar it appears to sit in. Its middle
is transparent, so a control underneath it is fully visible and looks perfectly
ordinary — but touches in that strip go to the bar. Frames from an iPad Pro 13-inch
(M5) / iOS 26.4 run, at the moment of the tap:

    Button {{306.0, 961.5}, {1054.0, 34.5}}  label: 'Resolve Issue'
    Button {{16.0,  946.0}, {1344.0, 56.0}}  label: 'Notifications'

The Resolve button is entirely inside the accessory's frame. The tell in a screenshot
is the accessory's expand chevron, which appears at the *far right* of the window, on
top of the green button, while the bar's visible content sits at the far left.

**Not specific to Seerr.** Any screen inside a split-view column that adds its own
`.safeAreaInset(edge: .bottom)` is affected. `SeerrIssueDetailView` (reply field and
resolve button) is the one with a test. `ArrCalendarView`'s Subscribe button is the
other known candidate and has not been checked.

**What was tried, and did not work.** Reserving the accessory's measured height inside
each column — a `PreferenceKey` on the accessory, then `.safeAreaInset(edge: .bottom)`
on `sidebarList`, `contentColumn`, `detailColumn` and `moreStack`. It had *no effect at
all*: the Resolve button stayed at `y 961.5` with a measured height, with a hard-coded
66, and with a hard-coded 200. Something in that path discards the column's safe area,
and the cause was not found. That change has been reverted; nothing of it is in the
tree.

That result also suggests the framing was wrong. The button is not too low. A
full-width invisible bar is on top of it, and moving the button up only moves it out
from under a bar that should not have been there.

**Two candidate directions**, of which the first was taken:

1. ✅ Give the accessory the sidebar's width rather than the window's, on the sidebar
   chrome. It only ever draws content on the left, so this matches what it already
   looks like, and it is the smaller change.
2. Keep it full width but make its empty middle non-interactive, so touches fall
   through to whatever is beneath.

**What was done.** Not a width cap - the bar is now a `safeAreaInset(edge: .bottom)` on
the *sidebar column itself*, inside the split view, rather than on the split view around
it. That is why the earlier attempt failed: it kept the inset outside and tried to
reserve space in each column separately, and the column never learned about a bar that
was not its own. Attached to the column, UIKit insets that column's list and the bar
cannot be over the other columns at all, because it is not laid out across them.

The Resolve button's frame was `{{306, 961.5}, {1054, 34.5}}` under a `{{16, 946},
{1344, 56}}` accessory. The accessory is now confined to the sidebar's ~320pt, so it no
longer overlaps anything in the detail column. **This reasoning has not been confirmed
against a run** - see Status.

**Why it was parked.** The issue UI is due for rework, and the messaging half of it —
the comment list and the reply field — may be removed outright. Fixing the chrome
underneath a screen that is about to change shape is work done twice. The chrome ended
up being fixed anyway, because the same bar was also swallowing the sidebar's own
Settings row, which is not a screen that is about to change shape.

**Coverage.** `TrawlUITests/SeerrJourneyUITests/testAuthenticatedSeerrIssueJourneyLoadsDetailAndResolvesIssue`
is `XCTSkipIf(TrawlChrome.isSidebar)`. It still runs in full on the compact chrome, so
the mutation path itself stays covered; only the iPad chrome is skipped. Removing the
skip is the acceptance test, and it has not been run yet — **remove the skip, run the
journey on the iPad chrome, and delete this entry only if it passes.** If it fails, the
frames above are the thing to re-measure first.

---

## iPhone: the Bazarr series detail has no route into it

**Status:** found 10 Sep 2026 during a full-plan run on the iPhone chrome. Not fixed —
the fix is a product decision about which route should exist, not a defect in either
screen. Parked pending that decision.

**Symptom.** On iPhone there is no way to open `BazarrSeriesDetailView` — 1,991
executable lines holding per-season subtitle state, the language-profile join, and the
interactive subtitle search. On iPad it is still reachable, because the Missing screen's
detail pane renders it directly.

**What is actually happening.** Two separate routes closed, one after the other:

- `BazarrBrowserView` (with `BazarrSeriesListView` / `BazarrMovieListView`) is the
  natural entry point and pushes `MoreDestination.bazarrSeriesDetail`. It is referenced
  nowhere outside its own file, so nothing in the running app can reach it. That was
  already true when `BazarrSeriesDetailJourneyUITests` was written, and its header says
  so.
- That left one live route: `ArrWantedView`'s `BazarrWantedSeriesRow`. Since `1ab881a`
  a wanted row calls `selectionAction(for:)`, which returns `nil` unless a detail pane
  is beside the list. `WantedItemActionRow` treats a nil `onSelect` as "confirm a
  search", so on iPhone the row now opens a *Search for X?* dialog and never pushes.
  `IPadSurfaceCaptureUITests/testMissingCompactRowConfirmsBeforeSearching` asserts that
  confirmation deliberately, so the compact behaviour is intended — it is the absence of
  any *other* route that is the bug.

Both changes are on `main`; neither came from `macos-ui-polish`.

**Two candidate directions**, neither taken:

1. Give the Subtitles hub a row that opens `BazarrBrowserView`, which is what that
   screen was built for and would revive the movie browser at the same time.
2. Let a compact Missing row push the Bazarr detail when the item *has* a Bazarr record,
   keeping the search confirmation for rows that do not. This reopens the question
   `1ab881a` answered, so it is the larger change.

**The same shape, elsewhere.** `ServerListView` became unreachable the same way on
`macos-ui-polish`: qBittorrent Settings dropped its "Servers" row in favour of opening
the configured server's editor directly, and nothing else pushes the list. Worth
deciding whether to delete it or route to it while this entry is open.

**Coverage.** `TrawlUITests/BazarrSeriesDetailJourneyUITests/testWantedSubtitleRowOpensTheBazarrSeriesDetailWithRealServerData`
is `XCTSkipUnless(TrawlChrome.isSidebar)`, naming this file — the mirror of the skip in
the entry above. The compact chrome, which the plan runs on, has no route to reach; the
sidebar chrome still renders the screen in its detail pane, so the journey is left
runnable there rather than switched off outright (that pane path has not been run since
the skip went in). It is the acceptance test for whichever direction is
taken: restore a route, point the journey's navigation at it, remove the skip, and
delete this entry only once it passes. Every assertion below its navigation — the
composed episode line, the language-profile name and its "Profile 71" fallback, the
season pluralisation — is still the right contract and should not be rewritten.
