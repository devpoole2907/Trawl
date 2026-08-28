# Trawl widgets audit

**Opened:** 28 August 2026
**Branch:** `rework/downloads-navigation-experience`
**Status:** widgets are a hard release-candidate requirement. This file tracks the
shipped widget surface, verified behaviour, defects, and the deferred roadmap.

Claims here are marked **verified** only when they were read out of production
source or proven by an executed test. Anything else is marked **proposed** or
**unverified**.

## Shipped inventory

All register in a single bundle, `TrawlWidgets/TrawlWidgetsBundle.swift`.

| Widget | Kind source | Families | Configuration | Backing data |
|---|---|---|---|---|
| Download Speed | `SpeedWidget/SpeedWidget.swift` | small, medium, **accessoryInline**, **accessoryCircular** | `SelectServerIntent` | qBittorrent transfer info + all enabled SABnzbd queues |
| Active Downloads | `ActiveDownloadsWidget/ActiveDownloadsWidget.swift` | small, medium, **accessoryCircular** | `SelectServerIntent` | qBittorrent torrents + all enabled SABnzbd queue slots |
| Upcoming Releases | `CalendarWidget/CalendarWidget.swift` | **small**, medium, large | `SelectCalendarScopeIntent` | Sonarr/Radarr calendar, cached poster thumbnails |
| Library Health | `LibraryHealthWidget/LibraryHealthWidget.swift` | small, medium, **accessoryCircular** | static | Arr health checks + stuck queue items |
| **Seerr Inbox** | `SeerrWidgets/SeerrInboxWidget.swift` | small, medium, accessoryCircular, accessoryInline | `SelectSeerrServerIntent` | Seerr pending requests **and** open issues |
| **Downloads Pause** (Control Center) | `DownloadControl/DownloadsPauseControl.swift` | Control Center control | — | Blended qBittorrent + SABnzbd running state |

Every widget sets a `widgetURL` deep link. Refresh intervals for all of them come
from one place, `TrawlWidgets/Shared/WidgetTimelinePolicy.swift`; no interval is
inlined in a provider.

### Widget kinds orphaned on update

Three kinds were removed or renamed, so any already-installed instance disappears
from the Home Screen when a user updates:

- `com.poole.james.Trawl.ActiveTorrentsWidget` → `…ActiveDownloadsWidget`
- `SeerrPendingRequestsWidget` and `SeerrOpenIssuesWidget` → merged into Seerr Inbox

Accepted deliberately: pre-1.0 is the cheapest possible moment for this, and doing
it after release would strand users' widgets with no recourse.

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

**Severity:** release-blocking for a SAB-only install. **Status:** open. The Control Center toggle added on 28 August deliberately acts on the blended set, so the download widgets' upload figure is now the only qBittorrent-only surface left.

### W-03 — SABnzbd per-job speed is synthesised, undocumented to the user

`activeDownloads(in:)` credits the entire queue rate to the first `.downloading`
slot and reports `0` for the rest, because SABnzbd reports one global rate and no
per-job speeds. This is a deliberate and reasonable choice — the code says so —
but in a mixed qB+SAB list the user sees several SAB jobs at `0 B/s` beside qB
torrents with real per-torrent speeds, with no cue that the units differ.

**Severity:** cosmetic/explanatory. **Status:** accepted, document only.

## Family coverage gaps — CLOSED 28 August 2026

All implemented. Each reuses a snapshot the provider already fetched; none added
networking.

| Gap | Widget | Result |
|---|---|---|
| No lock-screen presence | Download Speed | `accessoryInline` rate text + `accessoryCircular` gauge. Accessory families are routed **before** the unavailable branch, because the full "open Trawl to set up" card does not fit a lock-screen slot |
| No lock-screen presence | Active Downloads | `accessoryCircular` |
| No lock-screen presence | Library Health | `accessoryCircular` |
| No small family | Upcoming Releases | `systemSmall` next release plus countdown; the provider picks its countdown cadence from `context.family` |

## Seerr Inbox — CLOSED 28 August 2026

Seerr Pending Requests and Seerr Open Issues are merged into one **Seerr Inbox**
widget carrying both counts and the `SelectSeerrServerIntent` picker, which also
resolves the static-configuration inconsistency: Open Issues previously had no
server picker while its sibling did. Both counts are fetched per profile in one
task. The two old widgets are deleted.

The open question in the previous revision — replace both kinds or keep Pending
separately — was settled as **replace both**. See the orphaned-kinds note above.

## Control widgets — CLOSED 28 August 2026

`DownloadControl/DownloadsPauseControl.swift` is a `ControlWidget` with a
`ControlValueProvider`, driven by `ToggleDownloadsIntent` (a `SetValueIntent`
whose error type follows `ArrIntentError`). `Shared/DownloadControlState.swift`
is the single Foundation-only answer to "are downloads running?" across
qBittorrent **and** SABnzbd, which is the same blended set the download widgets
use — the consistent choice given W-01/W-02.

`WidgetDataFetcher.setDownloadsPaused` uses qBittorrent's `hashes=all` plus
SABnzbd `pause`/`resume` per profile, and only rethrows when *every* client
failed, so one dead client cannot make the control appear broken.

⚠️ **`setDownloadsPaused` has never been exercised against a live qBittorrent or
SABnzbd.** The `hashes=all` wildcard is documented behaviour, not verified here.
Live-fire this before release.

Live Activities remain post-1.0.

## Deferred

| Item | Decision | Date |
|---|---|---|
| Jellyfin "now playing / active streams" widget | Deferred to a future release. `JellyfinStack` is large enough to support it (sessions, activity log, scheduled tasks), but it needs a new client in the widget target, a new snapshot type, and pbxproj membership work. Would likely out-install Seerr Open Issues. | 28 Aug 2026 |
| Cleanuparr widget | Not planned. Cleanuparr itself is being feature-flag hidden until a future release because the upstream instance is not fleshed out enough to build against. No widget work until that flag lifts. | 28 Aug 2026 |
| Live Activities | Post-1.0. | 28 Aug 2026 |

## Empty-state risk

**Partially verified, 28 August 2026.** A simulator screenshot taken during the widget
UI work shows the Download Speed widget rendering `No Client` / `Open Trawl to set up`
correctly with nothing configured, so that widget degrades gracefully.

Still **unverified**: Library Health and Seerr Open Issues both use `StaticConfiguration`
with no picker, so a user with no Arr or no Seerr configured gets a tile with no
configuration affordance. The project rule is that features degrade gracefully when an
integrated service is absent, so both must render an explicit "not configured" state
rather than a bare zero. Not yet confirmed by an executed test or a device screenshot.

## Live-stack validation — 28 August 2026

Read-only against the disposable `trawl-test` stack. No credentials are recorded in this
repository and none should be added.

**Library Health is validated end-to-end against live data.** Every Arr instance returns
3 health checks (`type` `error` or `warning`, plus `source`/`message`/`wikiUrl`); all pass
`isRelevantHealthCheck`, and `healthSeverity` maps them correctly. The queue endpoint
returns the paged envelope the widget expects, so `queue.records` is correct. Against
this stack the widget would show 3 issues, 1 of them an error, per instance.

**Download Speed's decoding is validated.** qBittorrent `transfer/info` returns
`dl_info_speed`, `up_info_speed`, `dl_rate_limit` and `up_rate_limit` exactly as the
widget reads them, and qB v5 login returns `204` with a port-suffixed `QBT_SID_<port>`
cookie as expected.

### W-05 — Seerr widget fixtures have never been validated against a real payload

The Seerr test instance reports `"initialized": false`; its setup wizard was never
completed, so it holds no requests or issues and its credentials cannot authenticate.
The Seerr decoding and display-fallback tests added in the widget tranche are therefore
**hand-authored JSON that has never been compared to a live Seerr response.** They pass,
but they may be pinning a shape Seerr does not produce — the precise failure mode this
project has hit repeatedly with invented fixtures.

**Resolution:** complete Seerr setup against the Jellyfin instance, capture real
`/api/v1/request` and `/api/v1/issue` payloads, and reconcile the fixtures. This is a
mutation and needs an explicit decision. **Status:** open.

### W-06 — Calendar widget shapes — CLOSED 28 August 2026

**Closed.** Validated against a live Sonarr and Radarr by temporarily adding media, then
removing it. One movie was added to Radarr and one series to Sonarr, both with search
disabled so nothing was downloaded; both were deleted afterwards and both instances
verified back to zero series, zero movies and an empty calendar.

Every field the widget reads is present and correctly shaped:

| Path | Confirmed |
|---|---|
| Sonarr episode | `airDateUtc`, `airDate`, `seasonNumber`, `episodeNumber`, `hasFile`, `id`, and a nested `series` carrying `title` and `images` |
| Sonarr poster | `series.images` includes `coverType: "poster"` with a `remoteUrl`, which is what `posterURL` resolves |
| Sonarr `includeSeries` | The nested `series` object only appears when `includeSeries=true` — the widget passes it |
| Radarr movie | `inCinemas`, `digitalRelease`, `physicalRelease` (genuinely null when absent), `title`, `year`, `hasFile`, `id` |
| Radarr multi-release | One movie with a cinema date and a digital date but no physical date correctly produces exactly two events, matching the provider's `flatMap` over the three release kinds |

**One thing worth knowing:** live Arr timestamps carry **no fractional seconds**
(`2026-07-25T00:00:00Z`, `2025-01-14T02:00:00Z`). `parseISO` tries
`[.withInternetDateTime, .withFractionalSeconds]` first and only parses these on its
second, non-fractional attempt. The fallback is not defensive padding — it is the branch
that actually does the work against a real server. Do not remove it.

## Test coverage

See `TRAWL_TEST_COVERAGE_MAP.md` for the authoritative row. Current state:

| Target | Covered by | Status |
|---|---|---|
| Refresh policy, all six widgets | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green, with a valid negative control |
| Calendar day-sequencing | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Calendar scope filtering | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Calendar payload shapes (Sonarr + Radarr) | Validated live 28 Aug 2026 | Green — see W-06 |
| Calendar failure headlines | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Seerr decoding and display fallbacks | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green, but fixtures are hand-authored and **never checked against a live Seerr payload** — see W-05 |
| WidgetKit extension registration | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green |
| Installed widget presence and layout | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green |
| `trawl://downloads` deep link from widget | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green |
| Home Screen state restored after UI test | `TrawlUITests/WidgetInstalledProcessUITests.swift` | Green — teardown removes only widgets added above the recorded pre-test count |
| Glance formatting (gauges, rate labels, inline text, countdown) | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green |
| Download-control blended running state | `TrawlTests/WidgetTimelineAndDataTests.swift` | Green — a negative control exposed that the original SAB case survived mutation; a `soleLiveSAB` case now covers "control silently reverted to qBittorrent-only" |
| `setDownloadsPaused` against a live client | — | **Gap — never run against a real qBittorrent or SABnzbd** |
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
