# Trawl Feature Audit & Go-Live Readiness

Date: 2026-06-01 (go-live pass — supersedes 2026-05-26 feature audit)

**Scope:** Trawl is an **admin-only** app for managing and monitoring connected services (qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, Seerr/Jellyseerr, Jellyfin). End-user request/discovery workflows are handled by a separate frontend app (Lure) being built in parallel. Lidarr, Whisparr, and Readarr are deliberately out of scope.

This pass combines the prior feature-parity audit with a **code-level review of the whole codebase** (≈93k lines, 265 Swift files) looking for bugs, crash risks, silent failures, and incomplete features ahead of go-live.

**Build status:** ✅ `xcodebuild … -scheme Trawl` succeeds (exit 0, one benign `as Any` warning). No `try!`, `as!`, or `fatalError` in shipping code paths outside the guarded `ModelContainer` fallback and `#if DEBUG` previews. Credentials (qBit user/pass, Arr/Seerr API keys, Seerr session cookie, APNs token) are all stored in **Keychain**, never in UserDefaults/SwiftData — no plaintext secrets, no secret logging.

---

## Go-Live Verdict

**Much closer after this pass.** The app is feature-complete for its admin scope, compiles cleanly, and has solid foundations (Keychain, graceful degradation, consistent error surfacing). The code review surfaced a handful of real correctness bugs concentrated in the qBittorrent control path; **all Critical and High items below have now been fixed and the project builds clean (exit 0).** Remaining work is Medium/Low polish + post-launch feature gaps — none block go-live.

Severity legend: **Critical** = crash / data-integrity / security · **High** = broken or unusable feature · **Medium** = degraded UX / review risk · **Low** = polish. Items fixed in the 2026-06-01 pass are tagged **✅ FIXED**.

---

## Bug Register (verified in code)

### Critical — ✅ all fixed in 2026-06-01 pass

1. **✅ FIXED — Set mutated during its own iteration (potential trap).**
   `ViewModels/TorrentListViewModel.swift:226-229` — `for hash in self.processingHashes { … self.processingHashes.remove(hash) }`. Mutating a `Set` while iterating it is undefined behaviour in Swift and can crash. Triggers on any sync that lands while a pause/resume/recheck is in flight (common). Fix: collect hashes to remove, then `subtract` after the loop.

2. **✅ FIXED — `pauseTorrents` / `resumeTorrents` silently swallow all non-404 failures.**
   `Services/QBittorrentAPIClient.swift:176-198` — these two are the only mutations that bypass `performSuccessfulMutation`; they only branch on `404` and otherwise return without throwing (the v4 fallback also ignores its result). A 500/403/400 is reported to the user as success ("Paused"/"Resumed") while nothing happened. Route both through `performSuccessfulMutation` like the other mutations.

3. **✅ FIXED — `FilePriority` is decoded as a non-exhaustive enum — one unexpected value breaks the whole Files tab.**
   `Models/TorrentFile.swift:39` decodes `FilePriority` non-optionally; the enum (`:50`) only models `0,1,6,7`. qBittorrent can emit other priority integers (notably older servers); any unmodeled value throws and `getTorrentFiles` returns nothing. Decode the raw `Int` with a `.normal`/`.unknown` fallback.

4. **✅ FIXED — `AuthService.login` no-ops when a concurrent auth is in flight.**
   `Services/AuthService.swift:27` — `guard !isAuthenticating else { return }` returns with no SID and no throw. The 403 re-auth path (`QBittorrentAPIClient.performRequest:481-492`) can hit this during concurrent requests, leaving a stale/nil cookie and surfacing a spurious `authFailed`. Coalesce/await the in-flight auth instead of returning early.

### High

5. **✅ FIXED — Jellyfin admin "Reset Password" is unusable as designed.**
   `JellyfinStack/JellyfinUserEditorView.swift:687-702` requires the target user's *current* password and always sends `resetPassword: false`. An admin resetting another user's password does not know their current password. The client method already accepts optional `currentPassword` + a `resetPassword` flag — wire the admin-set / reset path.

6. **✅ FIXED — Seerr run-job / cancel-job swallow errors with no feedback.** (Now surfaced via an alert.)
   `SeerrStack/SeerrJobsView.swift:96-106` — `try? await apiClient.runJob(…)` / `cancelJob(…)`. A failed trigger looks identical to success. Surface errors like every other mutating surface does.

7. **✅ FIXED — Share extension accepts ANY shared URL as a magnet link.**
   `Share/ShareViewController.swift` now requires `url.scheme == "magnet"` and closes cleanly otherwise (the plain-text path already checked `magnet:`).

8. **CORRECTED — Share extension activation rule.** The earlier finding (no `NSExtensionActivationRule`) was based on a wrong assumption that TrawlShare uses a generated Info.plist. It actually uses `Trawl/Info.plist`, which **does** declare an `NSExtensionActivationRule` (web-URL max 1, file max 1, text). That's reasonable for a torrent share extension; combined with the #7 scheme check, no change needed. The extension still appears for web pages (standard tradeoff), but no longer mis-handles them.

9. **✅ FIXED — Blocklist deletions swallow failures and optimistically mutate local state.**
   `ArrStack/ArrServiceManager.swift:1004-1014` (`removeBlocklistItem`) and `:1017-1028` (`clearBlocklist`) use `try?` then unconditionally `removeAll`. On network failure the row disappears locally while the server still has it, with no error shown. (The import-list-exclusion paths at `:1030-1099` do this correctly — match them.)

10. **✅ FIXED — qBittorrent `.torrent` upload uses `session.data(for:)` — risks truncating large files.** (Both add paths now use `session.upload(for:from:)` with 403 re-auth retry.)
    `Services/QBittorrentAPIClient.swift:117,161` send the multipart upload via `performRequest` → `data(for:)`. The codebase's own `HTTPTransport.performRawUpload` exists precisely because `data(for:)` can drop/truncate bodies. Switch the add-file path to `session.upload(for:from:)`.

11. **✅ FIXED (partial) — Cold-launch magnet feedback.** Closer inspection showed `pendingMagnetURL` actually survives a failed connect and is presented when `retryDisconnectedConnections` reconnects — so it wasn't lost, just silent. Added a "Magnet Queued" notification on connect failure so the user knows it's pending.

### Medium

12. **ATS fully disabled app-wide (`NSAllowsArbitraryLoads = true`).**
    `TrawlApp-Info.plist:44`, `TrawlMac-Info.plist:38`. `NSAllowsLocalNetworking` is already set, so the blanket arbitrary-loads also permits cleartext to arbitrary *public* hosts and will draw App Store review scrutiny. Consider dropping it in favour of local-networking + the per-user `allowsUntrustedTLS` opt-in.

13. **`allowsUntrustedTLS` disables cert validation entirely (no pinning / host check).**
    `Utilities/ServerTrustPolicy.swift:48-49` returns `URLCredential(trust:)` unconditionally when enabled (MITM-exposed). It's user opt-in and redirect headers are stripped (good), but flag for awareness; consider a persisted per-connection warning.

14. **`seerr-issue://<id>` deep links can't reach issue detail.**
    `Views/ContentView.swift:200-201` and `:218-220` route `seerr-issue` to the issues *list* and discard the id; there is no `MoreDestination.seerrIssueDetail(id:)` (`MoreView.swift:46-63`) and `SeerrOpenIssuesWidget` deep-links with no id. (This is both a bug and the long-standing feature gap below.)

15. **Inconsistent active-server resolution between entry points.**
    `AddTorrentSheet.swift:10` and `ShareAddTorrentView.swift:6` only show servers where `isActive == true`, but `ContentView.activeServer` (`:496`) falls back to `servers.first`. A profile that exists but isn't flagged active leaves the share sheet showing "No server configured" while the main app is connected.

16. **Concurrent access to shared `nonisolated(unsafe)` ISO8601 formatters.**
    `ArrStack/ArrCalendarView.swift:1009-1025` — `ArrDateParser.parse` reads two shared `unsafe` `ISO8601DateFormatter`s from two parallel `group.addTask` children (`:161,184`). Generally thread-safe in practice but exactly what Swift 6 isolation flags. Instantiate formatters locally per parse (as `parseDay` at `:1027` already does).

17. **Number fields can't display or enter a literal `0`.**
    `numberStringBinding` in `ProwlarrProxiesView.swift:430-442` and `ProwlarrIndexerListHelpers.swift:667-680` map `0` to empty string, so settings where `0` is meaningful (seed ratio, min seeders, priority) show blank and can't be set to `0`.

### Low

- **Widget error-retry cadence.** On auth/transient failure most widget providers reschedule the normal ~30 min interval (e.g. `SpeedWidget.swift:78-84`), showing stale "Unavailable" for up to 30 min; `CalendarWidget.swift:110` even backs off *longer* on error (12h vs 5-6h). A short retry-after on error would help.
- **`SpeedEntry.serverName` overloaded as error text** (`SpeedWidget.swift:34-44`) — harmless smell; small/medium layouts that read `serverName` are unreachable when unavailable.
- **`SeerrServiceManager.swift:45-49`** rolling-cookie persistence is fire-and-forget (`Task.detached { try? … }`); a keychain write failure silently falls back to the older cookie next launch.
- **`ArrWantedView.swift:528`** navigates with `episode.seriesId ?? 0`; a nil id lands on an empty detail rather than crashing (edge polish).
- **`SeerrIssueListViewModel.swift:31-39`** double-increments `requestVersion` (filter `didSet` + `loadIssues`); harmless but fragile.

---

## Feature Gaps (parity — still open, confirmed in code)

These remain genuine gaps but are **not** go-live blockers for an admin tool; prioritise as post-launch increments.

1. **Arr custom format scoring is read-only.** `ArrQualityProfileDraft` round-trips `minFormatScore`/`cutoffFormatScore`/`minUpgradeFormatScore`/`formatItems` (`ArrQualityProfilesViews.swift:463-518`) but the editor (`:558-595`) only exposes name/upgrade/cutoff/qualities. Scores survive edits invisibly. No read-only **custom format definitions** list exists either.
2. **Sonarr/Radarr delete-with-exclusion flag is dead code.** `SonarrAPIClient.deleteSeries(…addImportListExclusion:)` (`:49`) / `RadarrAPIClient.deleteMovie(…addImportExclusion:)` (`:54`) accept the flag, but `SonarrViewModel.deleteSeries`/`RadarrViewModel.deleteMovie`(`/deleteMovies`) never forward it and no UI toggle exists — zero callers pass `true`.
3. **Seerr quota fully unwired.** `SeerrUserQuota`/`SeerrQuotaDetail` (`SeerrUser.swift:85-96`) are modeled but referenced nowhere, **and there is no API client method to fetch them** (no `/quota` path). Surfacing this needs both a client call and UI. (Per-user `requestCount` *is* now displayed — `UnifiedUserDetailView.swift:101,234`.)
4. **Seerr issue deep-link to detail** — see bug #14.
5. **Prowlarr** notification connections and download-client configuration — no client methods/views (indexers, applications, **and now proxies** are present).
6. **Bazarr** notification agents and full settings editor — `getSettings`/`saveSettings` exist on the client but only language-profile/provider/remote-path slices are edited.
7. **qBittorrent** preferences beyond default save path (`setDefaultSavePath` at `:55-67` is the only writer; `getPreferences` decodes ratio/seeding-time/ports/alt-limits but nothing writes them back), plus search plugins, peers, torrent creator.
8. **Jellyfin** plugin catalog/repositories/install/update, device inventory & API keys, live TV/admin settings, metadata provider configuration.

## Confirmed Done Since Last Audit

- **Prowlarr proxy management** — full list/create/edit/delete/test with tags (`ProwlarrProxiesView.swift` + `ProwlarrProxiesViewModel`). Previously listed as a gap; now complete.
- **Per-user Seerr request count** displayed in `UnifiedUserDetailView`.
- **Jellyfin policy editor browsable pickers** (`getVirtualFolders`/`getDevices`/`getChannels`).
- Arr blocklist + import-list-exclusion management views (exclusion paths handle failures correctly; blocklist paths do not — bug #9).

---

## Scope Map (refreshed)

| Scope | Coverage | Notes |
|---|---:|---|
| qBittorrent daily torrent ops | Strong | Add/delete/pause/resume/recheck/files/category/tags/limits/log + tracker mutation. **But** pause/resume/file-decode bugs above. |
| qBittorrent advanced control | Partial | RSS rules covered; search plugins, peers, torrent creator, full preferences missing/thin. |
| Sonarr/Radarr library ops | Strong | Library, lookup/add/edit/delete/search/wanted/calendar/queue/history/manual import. |
| Sonarr/Radarr policy/config | Partial | Quality profiles (read-only CF scoring), quality definitions, root folders, naming, media management, remote path mappings, download clients (CRUD). Gaps: CF definitions/editing, import lists, delay/release profiles, metadata, notification connections. |
| Prowlarr indexer layer | Good | Indexers, apps (CRUD + test), **proxies (CRUD + test)**, stats, status, search. |
| Prowlarr full settings | Partial | Download clients, notification connections, deeper sync/app profile detail not surfaced. |
| Bazarr subtitles | Strong | Wanted, language profiles, providers, search/download/delete/tools, history stats. |
| Bazarr full admin | Partial | Backups, tasks, remote path mappings wired. Notifications, scheduler depth, integration/provider/post-processing config thin. |
| Seerr/Jellyseerr admin | Good | Users, permissions, requests, issues (+comments), logs, jobs, linked Arr servers (CRUD + test), Jellyfin user import, request count. Gaps: quota, notification agents, issue deep-link. |
| Jellyfin admin | Good | Users (CRUD + full policy + browsable pickers + password*), libraries (virtual folder CRUD/media-path/rename), sessions, activity log, scheduled tasks, plugins (uninstall), system info, restart/shutdown, parental ratings. (*password reset unusable — bug #5.) |
| Jellyfin full dashboard | Partial | Plugin catalog/repos/install/update, device inventory/API keys, live TV, metadata provider config missing. |

---

## Manual Test Workflows (recommended before go-live)

Run these against a live stack to catch the dynamic issues a static review can't:

1. **qBittorrent control path** — pause/resume a torrent **while a server error is forced** (stop the server mid-action) and confirm the UI reports failure, not success (bug #2). Pause/resume rapidly while sync polling runs (bug #1). Open the Files tab on a torrent with mixed priorities (bug #3).
2. **Add torrent** — add a large `.torrent` file via the in-app sheet and the share extension (bug #10); cold-launch from a `magnet:` link with the server briefly unreachable (bug #11); share a plain web URL and confirm it's rejected (bug #7).
3. **Auth expiry** — leave the app idle past qBittorrent SID expiry, then fire two actions at once (bug #4).
4. **Jellyfin** — admin-reset another user's password (bug #5).
5. **Seerr** — trigger and cancel a job; confirm failures are visible (bug #6). Tap the open-issues widget and confirm where it lands (bug #14).
6. **Arr** — remove a blocklist item with the server down; confirm the row doesn't vanish silently (bug #9).
7. **Degradation** — run with each service unconfigured/unreachable in turn; confirm every tab shows a clean empty/not-configured state (this held up well in review across all stacks).

---

## Widgets

`TrawlWidgets` ships: **SpeedWidget** (qBit speed), **CalendarWidget** (Arr releases), **ActiveTorrentsWidget**, **SeerrPendingRequestsWidget**, **SeerrOpenIssuesWidget**. Shared `WidgetDataFetcher` loads SwiftData profiles in-process. No Lock Screen accessories, Live Activities, or Control widgets yet. See bug-register Low items for widget error-cadence polish. Highest-value future additions: Lock Screen accessory families for existing widgets, and a Live Activity for in-progress torrents added via the share extension.

---

## Likely Unnecessary (don't build for go-live)

- Full host/network/security settings editors per service (high-risk, low-frequency — leave to web UIs).
- qBittorrent torrent creator; full Jellyfin metadata editing / playback replacement.
- Every notification provider's dynamic config schema — target status/test/enable/webhook first.
- Duplicating advanced web-UI tables/filters where Trawl already offers a faster mobile path.

## Sources Compared

- qBittorrent WebUI API: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-4.1%29
- Sonarr/Radarr/Prowlarr settings: https://wiki.servarr.com/
- Bazarr settings: https://wiki.bazarr.media/Additional-Configuration/Settings/
- Seerr docs: https://docs.seerr.dev/
- Jellyfin users/plugins: https://jellyfin.org/docs/general/server/
