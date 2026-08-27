# Trawl widgets audit

**Opened:** 28 August 2026
**Branch:** `rework/downloads-navigation-experience`
**Status:** widgets are a hard release-candidate requirement. This file tracks the
shipped widget surface, verified behaviour, defects, and the deferred roadmap.

Claims here are marked **verified** only when they were read out of production
source or proven by an executed test. Anything else is marked **proposed** or
**unverified**.

## Shipped inventory

All six register in a single bundle, `TrawlWidgets/TrawlWidgetsBundle.swift`.

| Widget | Kind source | Families | Configuration | Backing data |
|---|---|---|---|---|
| Download Speed | `SpeedWidget/SpeedWidget.swift` | small, medium | `SelectServerIntent` | qBittorrent transfer info + all enabled SABnzbd queues |
| Active Downloads | `ActiveTorrentsWidget/ActiveTorrentsWidget.swift` | small, medium | `SelectServerIntent` | qBittorrent torrents + all enabled SABnzbd queue slots |
| Upcoming Releases | `CalendarWidget/CalendarWidget.swift` | medium, large | `SelectCalendarScopeIntent` | Sonarr/Radarr calendar, cached poster thumbnails |
| Library Health | `LibraryHealthWidget/LibraryHealthWidget.swift` | small, medium | static | Arr health checks + stuck queue items |
| Seerr Pending Requests | `SeerrWidgets/SeerrPendingRequestsWidget.swift` | small, medium, accessoryCircular, accessoryInline | `SelectSeerrServerIntent` | Seerr request list/count |
| Seerr Open Issues | `SeerrWidgets/SeerrOpenIssuesWidget.swift` | small, accessoryCircular | static | Seerr issue list |

Every widget sets a `widgetURL` deep link. Refresh intervals for all six now come
from one place, `TrawlWidgets/Shared/WidgetTimelinePolicy.swift`.

## Are the download widgets qBittorrent-only?

**No — verified.** Both download widgets query qBittorrent *and* every enabled
SABnzbd profile and merge the results.

- `WidgetDataFetcher.fetchDownloadSpeed` runs `async let qbResult` alongside
  `async let sabQueues`, then sums SAB's `kilobytesPerSecond * 1024` into `dlSpeed`.
- `WidgetDataFetcher.fetchActiveDownloads` concatenates qB torrents with SAB slots
  and sorts the union by speed, then progress, then name.
- With no qB server *and* no SAB profile, both return the `"No Client"` snapshot;
  with clients configured but all unreachable, both return `"Unreachable"`.
- `clientLabel` composes the display name across whichever clients answered.

So the widgets are downloads-wide, not qB-only. Three real defects fall out of
reading that code:

### W-01 — the server picker is labelled and scoped qBittorrent-only

`SelectServerIntent.title` is `"qBittorrent Server"` and `ServerAppEntityQuery`
enumerates only `ServerProfile`. SABnzbd profiles are never offered, so a user
cannot scope either download widget to one SAB profile, and the picker's label
misdescribes a widget that aggregates both client families. A SAB-only user is
shown a configuration control that lists nothing.

**Severity:** release-blocking for presentation, not for data. **Status:** open.

### W-02 — upload speed and rate limits are qBittorrent-only

In `fetchDownloadSpeed`, `upSpeed`, `dlLimit` and `upLimit` are all taken as
`qb?.info.… ?? 0`. Download speed correctly blends both clients, but a SAB-only
user sees a permanent `↑ 0 B/s` and empty limits next to a live download figure.
The asymmetry is invisible and reads as a bug to the user.

**Severity:** release-blocking for a SAB-only install. **Status:** open.

### W-03 — SABnzbd per-job speed is synthesised, undocumented to the user

`activeDownloads(in:)` credits the entire queue rate to the first `.downloading`
slot and reports `0` for the rest, because SABnzbd reports one global rate and no
per-job speeds. This is a deliberate and reasonable choice — the code says so —
but in a mixed qB+SAB list the user sees several SAB jobs at `0 B/s` beside qB
torrents with real per-torrent speeds, with no cue that the units differ.

**Severity:** cosmetic/explanatory. **Status:** accepted, document only.

## Family coverage gaps

**Proposed, agreed 28 August 2026.** No implementation yet.

| Gap | Widget | Proposed |
|---|---|---|
| No lock-screen presence | Download Speed | add `accessoryInline` and `accessoryCircular` |
| No lock-screen presence | Active Downloads | add `accessoryCircular` |
| No lock-screen presence | Library Health | add `accessoryCircular` (issue count is already a single number) |
| No small family | Upcoming Releases | add `systemSmall` showing next release plus countdown |

None of these need new networking; each reuses a snapshot the provider already
fetches. Lock-screen accessories are the highest-value addition because the two
most glanceable widgets currently have none while the two Seerr widgets do.

## Seerr Inbox consolidation

**Proposed, agreed 28 August 2026.**

Seerr Open Issues is the weakest widget of the six: small + circular only, static
configuration with no server picker (unlike its sibling, which has one), and an
open-issue count that is zero for most users most of the time. A widget that is
usually empty trains users to remove it.

Merge Pending Requests and Open Issues into one **Seerr Inbox** widget presenting
both counts, carrying the `SelectSeerrServerIntent` picker so multi-server users
are served, and deep-linking to the appropriate Seerr surface. This removes the
static-configuration inconsistency at the same time.

Open question to settle before implementing: whether the merged widget replaces
both kinds or whether Pending Requests survives separately. Replacing a shipped
widget kind removes it from users' home screens on update, which is acceptable
pre-1.0 but must be a deliberate decision.

## Control widgets

**Proposed, agreed 28 August 2026.** Nothing exists today — no `ControlWidget`
and no `ActivityAttributes` anywhere in the repo (verified by search).

A Control Center control for pause/resume-all is a natural fit: the app already
has an AppIntents layer under `Trawl/ArrStack/AppIntents/`, so the intent
plumbing and entity types are precedented. Sizing this properly needs a decision
on whether the control targets qBittorrent only or the same blended qB+SAB set
the download widgets use — given W-01/W-02, blended is the consistent answer.

Live Activities for a single large download are the other obvious iOS-26-era
absence, and are the more expensive of the two. Both are post-1.0 unless the
release date moves.

## Deferred

| Item | Decision | Date |
|---|---|---|
| Jellyfin "now playing / active streams" widget | Deferred to a future release. `JellyfinStack` is large enough to support it (sessions, activity log, scheduled tasks), but it needs a new client in the widget target, a new snapshot type, and pbxproj membership work. Would likely out-install Seerr Open Issues. | 28 Aug 2026 |
| Cleanuparr widget | Not planned. Cleanuparr itself is being feature-flag hidden until a future release because the upstream instance is not fleshed out enough to build against. No widget work until that flag lifts. | 28 Aug 2026 |
| Live Activities | Post-1.0. | 28 Aug 2026 |

## Empty-state risk

**Unverified — needs checking before release.** Library Health and Seerr Open
Issues both use `StaticConfiguration` with no picker. A user with no Arr or no
Seerr service configured therefore gets a tile with no configuration affordance.
The project rule is that features degrade gracefully when an integrated service
is absent, so both must render an explicit "not configured" state rather than a
bare zero. This has not yet been confirmed by an executed test or a device
screenshot.

## Test coverage

See `TRAWL_TEST_COVERAGE_MAP.md` for the authoritative row. Current state:

| Target | Covered by | Status |
|---|---|---|
| Refresh policy, all six widgets | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green, with a valid negative control |
| Calendar day-sequencing | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Calendar scope filtering | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Calendar failure headlines | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Seerr decoding and display fallbacks | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| WidgetKit extension registration | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green |
| Installed widget presence and layout | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green |
| `trawl://downloads` deep link from widget | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green |
| Widget pixel/text content | — | Not reachable from XCTest; device smoke test. See W-04 |
| Per-widget-kind data fetch on device | — | Release smoke-test work |

### W-04 — widget content is not reachable from SpringBoard's accessibility tree

**Resolved as a test-design issue, not a product defect.** The installed-process test
now passes: 1 test, 0 failures, 0 skipped.

Three earlier attempts failed at the same assertion after successfully installing the
widget. The cause was never selector spelling. Every query for the widget's inner text
logged `Error getting main window kAXErrorServerNotFound` against the remote process:
a Home Screen widget is rendered by `com.apple.chrono.WidgetRenderer`, and XCTest
cannot read into it from the SpringBoard element.

Dumping SpringBoard's hierarchy showed what it does own:

```
Icon, identifier: 'Trawl', label: 'Trawl', value: Widget    ← the installed widget
Icon, identifier: 'Trawl', label: 'Trawl'                   ← the app icon
```

The widget is an `SBWidgetIcon` surfaced as an icon carrying `value: Widget`. The test
now selects on that, counts Trawl widget icons before and after the gallery flow so it
proves this run installed one, waits for hittability before each tap, and taps the
widget to prove the deep link opens Trawl.

**Standing constraint for future widget tests:** assert on SpringBoard-owned elements
only. A widget's rendered text can be confirmed by a device screenshot during release
smoke testing, but it cannot be a regression assertion.
