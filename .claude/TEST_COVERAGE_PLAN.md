# Trawl Test-Coverage Plan

## Phase 1 — Discovery (findings)

### Architecture in scope

Trawl is an admin app, layered roughly:

- **Transport** — `HTTPTransport` (actor) owns `URLSession`, server-trust delegate, mutable-auth state (cookies/tokens), response observer (for rolling `connect.sid`), error mapping, diagnostics hooks. `URLEncoding`, `Data+Multipart`, `HTTPClientFactory`, `QBittorrentClientFactory`, `ServerTrustPolicy`.
- **API clients (actors)** — `ArrAPIClient` (shared) + `SonarrAPIClient`, `RadarrAPIClient`, `ProwlarrAPIClient`; `BazarrAPIClient`; `SeerrAPIClient`; `JellyfinAPIClient`; `QBittorrentAPIClient`; `TMDbClient`.
- **Service managers (`@Observable` finals)** — `ArrServiceManager` (1,355 lines, the biggest cross-service brain), `JellyfinServiceManager`, `SeerrServiceManager`. They own connection lifecycle, retry, cached lookups, blocklist, exclusions, notification setup, iCal feeds, Bazarr↔Sonarr/Radarr correlation.
- **Domain services** — `SyncService` (qB poll loop + local mutation cache), `TorrentService` (qB facade), `KeychainHelper` (actor), `AuthService`, `BiometricAuthService`, `AppLockController`, `NotificationService`, `ArtworkCache`, `InAppNotificationCenter`.
- **View models** — `OnboardingViewModel`, `*SetupViewModel` (3 of them), `TorrentList/DetailViewModel`, `AddTorrentViewModel`, `SearchViewModel`, `SettingsViewModel`, `UnifiedUserViewModel`, library/editor VMs per Arr/Seerr/Jellyfin, `AddImportLocationAndScanViewModel`.
- **Utilities** — `ServerURLValidator`, `MagnetLinkHandler`, `ServiceIdentity`, `FilterSortPipeline`, `ByteFormatter`, `ArrayChunking`, `PreviewSupport`.
- **Extensions** — Share extension (`TrawlShare`), widgets (`TrawlWidgets`/SpeedWidget, CalendarWidget).

### Integrations + capabilities (mapped from API client surfaces)

| Integration | Capabilities the code calls |
|---|---|
| **qBittorrent** | login/logout, app version, preferences, set default save path; list torrents (filter/category/sort), add by magnet, add by file (with category/tags/savePath/paused/sequentialDownload/firstLastPiece), delete (deleteFiles), pause/resume/recheck, rename, set location/category, file priorities, set torrent up/down limits, sequential/firstLast toggles; trackers get/add/remove/edit (real vs pseudo); categories list/create/remove, tags list/create/delete, add/remove tags; transfer info, alt-speed toggle, global up/down limits; **sync `maindata` long-poll** (rid); RSS items list/add folder/add feed/remove/move/refresh, RSS rules get/set/remove; main log fetch (level filters + lastKnownId) |
| **Sonarr** | series CRUD, lookup (term/tvdb), episodes get/files, set monitored, delete episode file, calendar (+iCal/webcal), releases (interactive search), grab, wanted/missing paged, refresh, search episodes/season/series, rename files, search all missing, RSS sync, install update |
| **Radarr** | movie CRUD, lookup (term/tmdb/imdb), files get/delete, calendar (+iCal/webcal), releases, grab, wanted/missing paged, refresh, search movie/all-missing, rename files, RSS sync, install update |
| **Prowlarr** | test all indexers, sync apps, search (multi-category/type), indexer stats with date range, indexer statuses, applications full CRUD + test + schema, tags |
| **Arr shared** | system/status, health, quality profiles full CRUD (+ custom format scoring fields), root folders CRUD, filesystem browse, tags, notifications CRUD, queue (paged), delete queue (blocklist/removeFromClient), history paged, log paged, disk space, backups (list/create/download/restore/upload/delete), updates, download clients full CRUD + test + schema, remote path mappings CRUD, blocklist paged + delete, import list exclusions paged + delete, manual import (scan + commit), naming config get/update, indexers get/create/delete + schema, scheduled tasks, calendar combined, events stream, activity hub |
| **Bazarr** | system status/health/badges/announcements (+ dismiss), tasks (list + run), backups full CRUD + upload, settings get/save (form-encoded), remote path mappings CRUD, languages, language profiles save, providers list/reset/save, series/movies paged (+ profile bulk update + actions), episodes by series/by id, download/delete episode/movie subtitles (lang/forced/hi), subtitle tracks + actions (sync/translate/OCR-fix/etc.), logs paged, history stats, search, wanted episodes/movies, interactive search (episode + movie) + download interactive subtitle, test connection |
| **Seerr / Jellyseerr** | Jellyfin login (cookie), current user, logout, users list/update permissions/delete, import users from Jellyfin, get Jellyfin users; DVR settings full CRUD per Sonarr/Radarr (incl. test + per-service detail); issues list/get/comments/reply/resolve/reopen; request count, requests paged, approve/decline/delete; media summary; jobs list/run/cancel; logs paged with filter+search; public settings; live cookie rotation via response observer |
| **Jellyfin** | auth-by-name, ping, public + full system info, restart/shutdown; users CRUD + policy + configuration + password reset; virtual folders CRUD + media paths + rename; library items (paged + all + find + search), series episodes; devices, channels, parental ratings; refresh all/item; filesystem browse (drives, directory contents, parent, validate); sessions get/sendMessage/stop; activity log paged; scheduled tasks list/start/stop; plugins list/delete |
| **TMDb** | search/trending/details used by `SearchViewModel` |

### Existing test inventory

- `TrawlTests/TrawlTests.swift` — `ByteFormatter` (3 small suites, table-driven).
- `TrawlTests/ArrStackTests.swift` — pure-decoder + property-assertion suites for `ArrError`, `ArrServiceType`, `RemoteFileSystem`, `ArrQueueItem`, `ArrRelease`, `ArrReleaseSort`, `ArrReleaseSortKey`, `ArrDiskSpace`, `ArrDiskSpaceSnapshot`, `ArrHealthCheck`, `AnyCodableValue`, `Prowlarr` (protocol/search/stats), `ArrServiceManager` initial-state, `ArrAPIClient` URL trimming, miscellaneous decoders for queue/history/blocklist/system status/quality profile/root folder/tag/Bazarr page.
- `TrawlUITests/*` — Apple template scaffolding only. Empty `testExample` and a launch metric. **No real UI assertions exist today.**

All present tests use **Swift Testing**. There is no HTTP fixture/cassette layer, no protocol seam over `URLSession`, no mock of `HTTPTransport`, and no `KeychainHelper` test double. `ArrServiceManager` is partially tested at its initial-state surface only — none of its 1,300+ lines of connection/retry/notification/correlation logic.

### External dependencies + side effects

- **Live HTTP** to user-hosted services. All authenticated via API key / cookie / bearer.
- **TLS**: `ServerTrustPolicy` allows-per-origin override for self-signed servers; user-toggle.
- **Keychain** (with access group) for API keys, qB password, Seerr cookie, Jellyfin token.
- **APNs + Trawl notification worker** at `workerURL` (Cloudflare worker-style bridge). `ArrServiceManager.setupNotifications` writes back into the Arr notification list — a destructive remote action.
- **Rolling Seerr cookie**: `connect.sid` is captured from response headers and written back into the transport mid-flight.
- **Destructive paths**: delete torrents (with files), restore backup (replaces server config), shutdown/restart Jellyfin, delete Jellyfin/Seerr user, delete download client, delete root folder, delete quality profile, delete series/movie with files.
- **Universal links / share extension / widgets** consume the same persisted profiles via App Group; cross-process state.

Currently no mocking strategy exists — there are no live-API tests and no recorded fixtures. All behaviour beyond pure-decoder tests is implicitly exercised only by manual use.

---

## Phase 2 — Gap analysis

### Risk legend

- **R1 (highest)**: destructive / can lose user data on the server.
- **R2**: cross-integration state — wrong here means silent inconsistency.
- **R3**: auth / connection lifecycle — wrong here = lockout, leaked creds, broken refresh.
- **R4**: shaped data round-trip — wrong here = corrupted profile/settings sent back.
- **R5**: pure presentation / formatters / sort.

Test type abbreviations: **U**nit · **C**ontract (fixture/HTTP stub against the real wire format) · **I**ntegration (live, opt-in, sandbox) · **E**nd-to-end UI · **M**anual smoke.

### Per-integration coverage matrix

Scoring "current coverage" as Present / Thin / **None** based on the test inventory above.

| Integration | Feature group | Coverage today | Risk | Proposed |
|---|---|---|---|---|
| **HTTP / Transport** | URL building, auth header injection, error mapping, status→error mapping, multipart upload, form-encoded post, response observer (cookie capture), TLS allow-untrusted | None | R3, R1 | **U + C** — stub `URLProtocol`, assert request shape + error mapping table |
| **Transport** | retry-on-failure / connection-error mapping per service | None | R3 | C |
| **Server URL validator** | scheme, port range, IDNs, trailing slashes | Likely none | R5 | U |
| **Keychain** | save/read/delete, access group, error mapping | None | R3 | U on sim only (skipped on CI without keychain) |
| **qBittorrent** | login/logout cookie lifecycle | None | R3 | C |
| qBittorrent | addTorrentMagnet / addTorrentFile multipart with options round-trip | None | R1 | C |
| qBittorrent | deleteTorrents(deleteFiles:) | None | **R1** | C + M (live destructive) |
| qBittorrent | sync/maindata diff merge into local cache (`SyncMainData`, `SyncService`) | None | R2 | U with fixtures |
| qBittorrent | RSS rules set/get/remove, RSS items add/move/refresh | None | R4 | C |
| qBittorrent | tracker add/remove/edit and pseudo-tracker filtering | None | R4 | C + U for filtering |
| qBittorrent | categories/tags CRUD, set-on-torrents, local-mirror in `SyncService` | None | R2 | U + C |
| qBittorrent | global speed limits + alt-speed toggle | None | R5 | U |
| qBittorrent | log fetch with `lastKnownId` paging | None | R5 | C |
| qBittorrent | preferences get + `setDefaultSavePath` | None | R4 | C |
| **Sonarr/Radarr** | series/movie CRUD + add-from-lookup | None | R4 | C |
| Sonarr/Radarr | delete with `deleteFiles` and `addImportListExclusion` flag | None | **R1** | C + flagged manual |
| Sonarr/Radarr | quality profile decode/encode + custom-format scoring round-trip | Thin (one decode test) | R4 | C |
| Sonarr/Radarr | releases / grab / interactive search | None | R4 | C |
| Sonarr/Radarr | calendar (iCal/webcal URL building) | None | R5 | U |
| Sonarr/Radarr | wanted/missing pagination | None | R5 | U + C |
| Sonarr/Radarr | episode/file delete, rename files, search season/series/episode | None | R1 partial | C |
| **Prowlarr** | applications CRUD + test, search across categories, indexer stats | None | R4 | C |
| **Bazarr** | settings get/save form-encoded round-trip | None | R4 | C (this is the riskiest Bazarr surface) |
| Bazarr | language profiles save (array → server format) | None | R4 | C |
| Bazarr | series/movie ↔ Sonarr/Radarr id correlation (`refreshBazarrSubtitleCache`, `bazarrSubtitleStatus(forSonarrSeriesId:)`) | None | **R2** | U with fixtures across both |
| Bazarr | interactive subtitle search + download | None | R1 (writes files server-side) | C + M |
| Bazarr | provider save with field values | None | R4 | C |
| Bazarr | backups full lifecycle (incl. restore) | None | R1 | C + M |
| **Seerr** | Jellyfin login + session cookie capture + observer rewrite | None | **R3** | C — assert observer writes back, header order, replay survives 302 |
| Seerr | DVR (Sonarr/Radarr) settings CRUD + test | None | R1, R4 | C |
| Seerr | users CRUD + permissions bitmask + Jellyfin import | None | R4 | U for permissions math + C for round-trip |
| Seerr | issues list/get/reply/resolve/reopen + comments | None | R4 | C |
| Seerr | requests list/approve/decline/delete + count | None | R1 | C |
| Seerr | jobs list/run/cancel, logs paged | None | R5 | C |
| **Jellyfin** | auth-by-name + bearer header build | None | R3 | C |
| Jellyfin | restart/shutdown | None | **R1** | manual only |
| Jellyfin | user CRUD + full `JellyfinUserPolicy` round-trip (libraries, devices, channels, schedules, parental, transcoding, bitrate, remote) | None | R4 | C — heavy fixture coverage; this is the largest payload in the app |
| Jellyfin | virtual folder + media path + rename | None | R1 | C |
| Jellyfin | library items pagination, search, find, series episodes | None | R5 | C |
| Jellyfin | sessions: send message, stop playback | None | R5 | C |
| Jellyfin | scheduled tasks start/stop, plugin delete | None | R1 (delete) | C |
| Jellyfin | filesystem browse (drives/dir contents/validate) | Thin (decoder only) | R5 | C |
| **Cross-cutting** | `ArrServiceManager.connectService` health-check + retry + connection-error mapping | Initial-state only | R3 | U with injected fake clients |
| Cross-cutting | `ArrServiceManager.setupNotifications` (writes Arr notification config) | None | **R1** | C — this writes server-side state |
| Cross-cutting | iCal feed URL composition | None | R5 | U |
| Cross-cutting | Bazarr availability ↔ Arr library reconciliation | None | R2 | U |
| Cross-cutting | Jellyfin availability resolver vs Arr library | None | R2 | U |
| Cross-cutting | Magnet link handler (incl. share extension entry point) | None | R5 | U |
| Cross-cutting | `FilterSortPipeline`, torrent sort orders, library filter | None | R5 | U |
| **Auth / lock** | `AppLockController` scene-phase transitions, `BiometricAuthService` availability mapping | None | R3 | U with injected biometric stub |
| **ViewModels** | `OnboardingViewModel.validateAndSave`, all `*SetupViewModel.connect/validateAndSave` (incl. URL canonicalisation + secret persistence) | None | R3, R4 | U + C |
| ViewModels | `TorrentListViewModel` bulk pause/resume/delete with selection set | None | R1 | U with `TorrentService` fake |
| ViewModels | `AddTorrentViewModel.submit` (magnet vs file, defaults pickup) | None | R1 | U |
| ViewModels | `SearchViewModel` reconciliation of TMDb + Arr lookup + library | None | R2 | U |
| ViewModels | `UnifiedUserViewModel` merge of Jellyfin + Seerr users | None | R2 | U |
| **Extensions** | Share extension: magnet detection, profile selection, save handoff | None | R1 | M (extensions are hard to unit-test in CI; do one launch test) |
| Extensions | Widgets: calendar + speed widget render with empty/error/loaded state | None | R5 | E preview snapshot if time allows |

### Where I'm unsure

- **Bazarr settings get/save**: the get returns a deep `[String: JSONValue]` and the save accepts form items. The server tolerates partial submission, but I don't know which keys are required for the calls we send today; need to capture one real request to drive contract tests.
- **Seerr cookie rotation observer**: works in practice, but I haven't traced whether the observer fires on non-2xx responses where Seerr still sets a cookie. Worth verifying empirically before locking a test in.
- **`ArrServiceManager.setupNotifications`**: writes a webhook config into the user's Arr server. Either we mock it end-to-end at HTTP level (preferable), or we keep it as a flagged manual smoke. I lean toward HTTP-level contract test.
- **Jellyfin `updateUserPolicy`**: 1,300-line editor view. Confidence that every nested field round-trips is low. Worth a dedicated fixture matrix.
- Whether the existing `ProwlarrIndexer` `fields: nil` initialisation in tests reflects how Prowlarr really returns indexer fields — that test is brittle to schema drift.

---

## Phase 3 — Plan

### Strategy summary

1. **Stop testing on the real wire.** Introduce a single seam at `URLProtocol` so `HTTPTransport` + `QBittorrentAPIClient` can be exercised against recorded responses without changing production code.
2. **Drive everything from fixtures recorded from real services.** One fixture set per integration, checked in under `TrawlTests/Fixtures/<Service>/<feature>.json`. New responses are dropped in by hand from an env that the developer points the app at.
3. **Three test surfaces, in order of leverage**:
   - **Contract tests** against fixtures (highest ROI; catch decode/encode regressions and request-shape drift).
   - **Pure-logic unit tests** for cross-integration reconciliation, validators, formatters, view-model state machines.
   - **A thin UI smoke** (XCUITest using launch arguments to inject a stub-mode AppServices) that proves each top-level navigation destination renders without crashing on canned data.
4. **Manual pre-release smoke** keeps a small set of genuinely destructive paths (restore-backup, delete-with-files, Jellyfin shutdown, Seerr DVR delete) — these are not worth automating against a live service.
5. Keep the existing pure-decoder tests; delete only the empty Apple-template UI test files.

### Test-infrastructure changes

All new files unless noted. Listed in build order — each one unlocks the next.

#### A. Test-only seams

1. `TrawlTests/Support/StubURLProtocol.swift` — registers a `URLProtocol` that matches `(method, path, queryItems?)` against a registered response (status, headers, body). Threadsafe per test.
2. `TrawlTests/Support/URLSessionConfiguration+Stub.swift` — `.stub` factory returning a config with `StubURLProtocol` first in `protocolClasses`.
3. **One-line production change** in `HTTPTransport.init`: accept an `URLSessionConfiguration` (already does — confirmed line 69). Add a static helper `URLSessionConfiguration.makeTrawlStub()` in the test target. No prod refactor needed.
4. `QBittorrentAPIClient` and friends: confirm they accept an injectable session/config; if not, the smallest possible injection (default param) — but verify before refactoring. *Flag: I haven't read `QBittorrentClientFactory` end-to-end.*
5. `TrawlTests/Support/FixtureLoader.swift` — `Fixture.json(_:)`, `.data(_:)`, `.responding(status:headers:bodyFixture:)` helpers.
6. `TrawlTests/Support/FakeKeychain.swift` — in-memory `KeychainHelper` substitute behind a protocol. Adds a protocol to production (one file change in `Services/KeychainHelper.swift`).
7. `TrawlTests/Support/FakeBiometricAuthService.swift` — same pattern, behind a protocol.
8. `TrawlTests/Fixtures/<Service>/...` — fixture tree. Initial set is captured ad-hoc from the dev's real services; do not require live calls from CI.

#### B. CI configuration

- Add a Swift Testing test plan `Trawl.xctestplan` with two configurations: **`unit`** (default, runs everything that uses stubs/fakes) and **`live`** (gated on `TRAWL_LIVE_TESTS=1` env var; skipped in CI). Live tests use `@Suite(.enabled(if: ProcessInfo.processInfo.environment["TRAWL_LIVE_TESTS"] == "1"))`.
- `xcodebuild test` in CI runs only the `unit` plan. Add a GH Action / pre-commit later — out of scope for this plan but the test plan makes it trivial.

### Files to create (ordered by risk reduction)

Each block represents one PR-sized increment. Tests in earlier blocks unlock later ones.

**Block 1 — Transport + auth + keychain (R3, R4 foundation)**
- `TrawlTests/HTTP/HTTPTransportTests.swift` — request building (path, query, headers), auth header injection per `HTTPAuth` case, status→error mapping table per service mapper, response observer fires for 2xx + non-2xx, multipart body shape, form-encoded body shape, `allowsUntrustedTLS` propagation (assert delegate identity).
- `TrawlTests/HTTP/URLEncodingTests.swift` — qB query joiner + percent-encoding edge cases.
- `TrawlTests/Services/KeychainHelperTests.swift` — save/read/delete via the fake; verify the protocol matches the real implementation's contract.
- `TrawlTests/Utilities/ServerURLValidatorTests.swift` — schemes, ports, trailing slashes, IDN, empty/whitespace.

**Block 2 — Per-client contract tests against recorded fixtures**
- `TrawlTests/QBittorrent/QBittorrentAuthTests.swift` — login cookie capture, logout, expired cookie reauth.
- `TrawlTests/QBittorrent/QBittorrentTorrentTests.swift` — list with filter/category/sort, add magnet, add file (multipart payload assertions), delete (with `deleteFiles` flag round-trip), pause/resume/recheck, set category, set location.
- `TrawlTests/QBittorrent/QBittorrentSyncTests.swift` — `syncMainData` rid handling, additions/removals/updates merge into local cache.
- `TrawlTests/QBittorrent/QBittorrentTrackersTests.swift` — pseudo vs real tracker filtering, add/remove/edit, edit with empty URL guard.
- `TrawlTests/QBittorrent/QBittorrentRSSTests.swift` — rules get/set/remove, items list/add folder/add feed/move/refresh.
- `TrawlTests/QBittorrent/QBittorrentPreferencesTests.swift` — preferences decode + `setDefaultSavePath` partial update payload.
- `TrawlTests/Arr/ArrSharedContractTests.swift` — backups list/create/restore/upload/delete request shapes, blocklist + import-list-exclusion paging, manual import scan + commit, naming config get/update generic round-trip, queue delete (with `blocklist`/`removeFromClient` flags), download clients full CRUD + test, remote path mappings CRUD, indexers schema, scheduled tasks, calendar combined.
- `TrawlTests/Arr/ArrQualityProfileRoundTripTests.swift` — extend the existing single test into a matrix: empty / minimum / full custom-format-scoring / multi-group / multi-language. Encode → decode → re-encode, asserting no field drops.
- `TrawlTests/Arr/SonarrSeriesTests.swift` — add/update/delete (incl. `addImportListExclusion`), interactive search, season/episode search, refresh.
- `TrawlTests/Arr/RadarrMovieTests.swift` — symmetric set for movies (incl. tmdb/imdb lookup, `addImportExclusion`).
- `TrawlTests/Arr/ProwlarrTests.swift` — applications CRUD + test (with secret-field round-trip), search across categories, indexer stats date range, indexer statuses.

**Block 3 — Bazarr / Seerr / Jellyfin contract tests**
- `TrawlTests/Bazarr/BazarrSettingsTests.swift` — settings get parse, save form-encoding (assert exact form payload for known fields), language profile save round-trip.
- `TrawlTests/Bazarr/BazarrSubtitlesTests.swift` — download/delete subtitle for episode + movie, subtitle track action payloads, interactive search + download.
- `TrawlTests/Bazarr/BazarrCorrelationTests.swift` — series/movie ↔ Sonarr/Radarr id resolution + status caching in `ArrServiceManager` (pure unit, no HTTP).
- `TrawlTests/Seerr/SeerrAuthTests.swift` — Jellyfin login, cookie observer rewrites mutable auth, observer fires on 4xx that still rotates cookie, logout clears it.
- `TrawlTests/Seerr/SeerrDVRTests.swift` — DVR CRUD per kind, `testDVRConnection` payload shape.
- `TrawlTests/Seerr/SeerrIssuesTests.swift` — list/get/comments/reply/resolve/reopen.
- `TrawlTests/Seerr/SeerrRequestsTests.swift` — list paged with filters, approve/decline/delete, count.
- `TrawlTests/Seerr/SeerrPermissionsTests.swift` — pure bitmask math for `SeerrPermission`.
- `TrawlTests/Jellyfin/JellyfinAuthTests.swift` — authenticate-by-name, bearer header build, ping, public vs full system info.
- `TrawlTests/Jellyfin/JellyfinUserPolicyTests.swift` — **the big one.** Fixtures of real `JellyfinUserPolicy` payloads (admin user, restricted user, parental-locked user, schedule-restricted user). Encode → POST → decode → re-encode, no field drops. Drives the editor view.
- `TrawlTests/Jellyfin/JellyfinLibrariesTests.swift` — virtual folder CRUD, media paths add/remove, rename, refresh.
- `TrawlTests/Jellyfin/JellyfinLibraryItemsTests.swift` — items paged, find/search, series episodes.
- `TrawlTests/Jellyfin/JellyfinSessionsTests.swift` — sendMessage + stopPlayback payloads.
- `TrawlTests/Jellyfin/JellyfinTasksAndPluginsTests.swift` — start/stop scheduled task, delete plugin.

**Block 4 — Cross-cutting orchestration**
- `TrawlTests/Arr/ArrServiceManagerConnectionTests.swift` — `connectService` happy path + health check failure path + TLS failure → connectionError + retry behaviour. Inject fake clients.
- `TrawlTests/Arr/ArrServiceManagerNotificationsTests.swift` — `setupNotifications` writes the expected `ArrNotification` body, `notificationSetupStatus` reports correctly per service. *R1; the highest-value contract test in the manager.*
- `TrawlTests/Arr/ICalFeedTests.swift` — `iCalFeedURL`/`webcalFeedURL` composition.
- `TrawlTests/Services/SyncServicePollingTests.swift` — start/stop, refresh, local-mutation cache (category/tag add/remove) survives a refresh diff.
- `TrawlTests/Utilities/MagnetLinkHandlerTests.swift` — full magnet, btih variants, encoded magnet, non-magnet.
- `TrawlTests/Utilities/FilterSortPipelineTests.swift` — filter+sort against representative torrent fixtures.

**Block 5 — View models**
- `TrawlTests/ViewModels/OnboardingViewModelTests.swift` — `validateAndSave` with valid/invalid URL, duplicate, secret persisted to keychain.
- `TrawlTests/ViewModels/SetupViewModelsTests.swift` — all three setup VMs against stubbed transport: connect, edit-existing, delete, untrusted-TLS toggle.
- `TrawlTests/ViewModels/TorrentListViewModelTests.swift` — bulk pause/resume/recheck/delete, selection mutation, sort order persistence.
- `TrawlTests/ViewModels/AddTorrentViewModelTests.swift` — magnet vs file path, defaults loaded from last-used profile, submit success/failure.
- `TrawlTests/ViewModels/SearchViewModelTests.swift` — Arr lookup + TMDb reconcile + library presence flag.
- `TrawlTests/ViewModels/UnifiedUserViewModelTests.swift` — merge Jellyfin + Seerr users, apply update/delete from each side.

**Block 6 — UI smoke**
- Delete `TrawlUITests/TrawlUITests.swift` (template only).
- `TrawlUITests/SmokeNavigationTests.swift` — launches with `-TrawlUseStubBackend 1`. Production reads the flag in `TrawlApp.swift`; on true, `AppServices` is wired to a stub backend exposing canned data. The test taps each major destination (`TorrentList`, `ContentView` tabs, `MoreView` hubs, each integration's settings detail) and asserts a known label is visible. **One test per top-level destination, no deeper assertions.** This is leverage, not coverage.

### What runs in CI vs by hand

**CI (every PR + every push to `main`)**
- All of Blocks 1–5 against stubs/fixtures.
- The Block 6 UI smoke against the stub backend.
- A `xcodebuild build` for each target (`Trawl`, `TrawlMac`, `TrawlShare`, `TrawlWidgets`) to catch the membership-exception trap CLAUDE.md warns about.

**Local opt-in (developer command, `TRAWL_LIVE_TESTS=1`)**
- Optional live contract tests that hit a dedicated dev instance per service. Use the same suites as the stub ones; the live config swaps the URL session. Useful when capturing new fixtures or after server upgrades.

**Manual pre-release smoke (run by hand, see checklist)**
- Anything that can destroy server state or that we can't reasonably stub.

### Pre-release manual checklist

Run against a real instance of each service shortly before tagging a release. Tick off each line.

**Onboarding**
- [ ] Add qB profile via URL+creds; confirm cookie persists across cold launch.
- [ ] Add Sonarr/Radarr/Prowlarr/Bazarr profiles with API keys.
- [ ] Add Seerr profile (Jellyfin login). Confirm rolling session survives a 24h+ background.
- [ ] Add Jellyfin profile via username/password. Confirm bearer token persists.
- [ ] Toggle "allow untrusted TLS" on a self-signed server and re-test.

**Destructive paths (don't automate)**
- [ ] qB: delete torrent with delete-files on a dummy torrent.
- [ ] Sonarr: delete series with files + import-list-exclusion enabled. Verify exclusion appears.
- [ ] Radarr: same for movie.
- [ ] Arr: backup → restore on a throwaway docker instance.
- [ ] Bazarr: backup → restore.
- [ ] Seerr: delete a dummy user, delete a request, delete a DVR settings entry.
- [ ] Jellyfin: delete a dummy user, remove a virtual folder, restart server (in isolation).

**Cross-integration**
- [ ] Add a series in Sonarr → confirm it appears in Bazarr's Trawl series view within one refresh.
- [ ] Add Trawl notifications for each Arr → confirm a release grab fires an APNs push via the worker.
- [ ] Open a Seerr issue → reply → resolve → reopen; confirm comments thread correctly.
- [ ] Jellyfin user policy: edit a user end-to-end (library allow/block, schedule, parental, transcoding), save, re-open, confirm all fields persisted.

**App lock + extensions**
- [ ] Enable biometric lock; force a scene-phase background → foreground; confirm prompt.
- [ ] Share extension: share a magnet from Safari; pick a qB profile; confirm torrent appears.
- [ ] Widgets: confirm both widgets render after a fresh install (no cached profile yet) and after one is set up.

**Regressions specific to this release**
- [ ] Anything called out in the current release's commits — keep this list short and concrete; do not let it grow into a parallel test suite.

### Open decisions to make before starting

1. **Fixture capture mechanism**: capture-by-hand vs a tiny in-app recording mode behind a debug flag. I'd start by-hand and add recording if/when the fixture set grows past ~50 files.
2. **Stub backend for UI smoke**: build it as a fake `AppServices` (clean) vs `URLProtocol`-level stubbing of every real client (more faithful, more work). I lean fake `AppServices`.
3. **Live test policy**: do we want one of us to run `TRAWL_LIVE_TESTS=1` weekly against a docker compose, or only when capturing fixtures? Affects whether we maintain the live config rigorously.
4. **Snapshot tests for SwiftUI?** Deliberately omitted above — they break on iOS minor version bumps and the FEATURE_AUDIT.md treats UI churn as normal. Re-evaluate after Block 6 if smoke alone proves insufficient.
