# Trawl reliability and test audit

**Audit date:** 22 August 2026  
**Repository snapshot:** `rework/downloads-navigation-experience` at `a5f29d9`, plus the uncommitted working tree present during the audit  
**Scope:** iOS app, macOS app, share extension, widgets, test architecture, build configuration, network boundaries, service state, concurrency, persistence boundaries, and representative SwiftUI accessibility

## Implementation addendum — 22 August 2026

The first reliability tranche has now been implemented against repository commit `ee84c0a` plus the working tree. These are behavior-driven regression tests, not coverage padding: production request builders/managers run against recording `URLProtocol` fixtures, loopback HTTP servers, manual clocks, and checked-continuation barriers.

### Completed in this tranche

| Audit item | Result | Regression evidence |
|---|---|---|
| B-01 macOS compile failure | Fixed | `SearchView` now selects a macOS-compatible search placement; a clean `TrawlMac` generic macOS build exits 0. |
| H-03 out-of-order qB sync / stopped polling | Fixed | Controlled RID 20-before-15 ordering cannot move state backward or duplicate completion; a delayed response after `stopPolling()` cannot apply. |
| H-05 SAB unauthorized polling/client lifecycle | Fixed | A controlled 401 now stops polling and clears the active client; mutation and subsequent manual poll tick produce no request. The pre-fix test failed five intended assertions. |
| H-07 Arr same-ID cache repoint | Fixed | Real manager reconnects from loopback server A to B for both Sonarr and Radarr. Pre-fix, both returned A and B received no library request; post-fix, both fetch B while an unrelated profile cache remains fresh. |
| M-03 qB non-403 status validation | Partially fixed and covered | Real-client request tests reject 401/404/429/500 before text/JSON decoding and assert method/path/query. A deterministic 403 reauthentication contract still needs an injectable credential/reauthentication seam. |
| M-06 multipart header injection | Fixed | Byte-level helper tests and a captured real upload request prove hostile CR/LF/quotes cannot create injected part headers. |
| Final 3xx handling gap | Fixed | Shared `HTTPTransport` now accepts only 2xx; a terminal 302 is mapped as an HTTP error. |

Shared HTTP contract coverage now also asserts GET path/query/static authorization, successful JSON decoding, and domain mappings for 401/404/429/500.

### Validation after integration

| Check | Result |
|---|---:|
| Six new focused suites together | **Passed:** 15 logical tests / 20 concrete executions, 0 failed, 0 skipped |
| Entire `Trawl` scheme | **Passed:** 159 logical tests / 236 concrete executions, 0 failed, 0 skipped |
| Generic iOS Simulator build | **Passed** (also compiles share/widget dependencies) |
| Generic macOS `TrawlMac` build | **Passed** |
| `git diff --check` | **Passed** |

Integrated result bundles are under Xcode DerivedData, including `Test-Trawl-2026.08.22_17-09-17-+1200.xcresult` for the focused tranche and `Test-Trawl-2026.08.22_17-09-38-+1200.xcresult` for the full scheme.

## Second tranche — 22 August 2026

### Completed in this tranche

| Audit item | Result | Regression evidence |
|---|---|---|
| H-04 calendar refresh ordering | Fixed | A refresh generation guard plus deferred state commit. Overlapping refreshes leave each event in state exactly once, and a stale profile-A refresh released after profile B has loaded cannot overwrite B. Refresh also no longer blanks the calendar while it reloads. |
| M-05 canceled torrent filter overwriting a newer query | Fixed | Behavioral red captured first: a canceled Alpha filter applied after and overwrote Beta. A filter generation plus cancellation checks on both sides of the computation now prevent it. |
| H-01 same-ID Arr repoint leaves screens on the old client | Fixed | Two real loopback servers per test. A deliberately retained Sonarr and Radarr view model is driven through an in-place host edit; after the reconnect, server A receives no further request and server B receives both the library `GET` and the command `POST`. |
| H-02 failed Arr reconnect leaves a stale client exposed | Fixed | A same-ID reconnect to a 401 server clears the entry's client and rotates its revision. Every manager and retained-view-model entry point — `sonarrClient`, `sonarrClient(for:)`, `loadSeriesLibrary()`, `loadHealth()`, `refreshQueues()`, the view model's library load and its search command — is exercised after the failure, and server A receives nothing. |

### A real defect the H-02 test caught

The first green run was not green. `ArrLibraryViewModel.client` resolved as `clientProvider?() ?? storedClient`, so whenever the live resolver correctly returned `nil` — exactly the failed-reconnect case — the `??` fell back to the client the view model had been constructed with. A retained view model could still reach the old server after a failed credential edit, which is H-02 itself surviving its own fix. The resolver is now authoritative when present.

The same pass replaced the `Client??` tri-state override that guarded this property. Its only two callers were `SonarrViewModel` and `RadarrViewModel` preview initializers, both assigning `nil`; that intent is now an explicit `detachClientForPreview()`, so previews still issue no network work and the double optional is gone.

### Validation after integration

| Check | Result |
|---|---:|
| Three second-tranche suites together | **Passed:** 6 tests, 0 failed, 0 skipped |
| Entire `Trawl` scheme | **Passed:** 165 logical tests / 242 concrete executions, 0 failed, 0 skipped |
| Generic iOS Simulator build | **Passed** |
| Generic macOS `TrawlMac` build | **Passed** |

New and extended test files in this tranche: `TrawlTests/ArrClientLifecycleTests.swift`, `TrawlTests/ArrCalendarConcurrencyTests.swift`, `TrawlTests/TorrentListViewModelConcurrencyTests.swift`.

### Still open after the second tranche

H-06 and M-01, M-02, M-04 remained, along with the qBittorrent 403 reauthentication contract. All five were taken in the third tranche below.

## Third tranche — 22 August 2026

This tranche closed every remaining item from the original prioritized list.

### Completed in this tranche

| Audit item | Result | Regression evidence |
|---|---|---|
| H-06 slow SABnzbd response overwriting a new profile | Fixed | A connection generation, stamped on entry and re-checked before every shared-state write, plus an `activeClient === client` identity check that catches connections cleared in place by a 401. Two fake SABnzbd servers behind one injected `URLProtocol`: profile A's refresh is parked mid-flight, B connects, A is released — `activeProfileID`, queue, history and completion notifications stay exclusively B's. A parked *connect* handshake is covered the same way. |
| H-06 `isRefreshing` starvation | Fixed | The boolean gate became `refreshingGeneration`, so a newly connected profile's first refresh is no longer swallowed by the previous profile's in-flight one. Pre-fix, B connected but never loaded history at all. |
| M-01 retry skipping failed secondary Arr instances | Fixed | `retryDisconnected()` now decides per profile via `isConnected(_:profileID:)` and a new `isConnecting(_:profileID:)`, not from the active instance's state. Two loopback Sonarr servers: the failed profile is reconnected while the healthy one gets no second handshake. |
| M-02 Add Movie/Series intents failing open | Fixed | `try?` around the duplicate-check read replaced with an explicit `do/catch` in both intents. Real intents run against a loopback server that fails only the library `GET`: the read failure is surfaced as `ArrIntentError.requestFailed` and no add `POST` is sent. Counterpart tests prove a genuinely empty library still adds. |
| M-04 share-extension provider failure paths | Fixed | Every input path now funnels through one idempotent termination, so the sheet cannot be stranded and cannot be completed twice. Four paths previously returned without ending the request at all. |
| qBittorrent 403 reauthentication contract | Covered, one bug fixed | A `QBittorrentCredentialProviding` seam plus an injectable login transport make the retry path deterministic. The contract itself was already correct — one re-auth, one retry, same request replayed with a refreshed cookie, no retry after a failed re-auth. The bug: credential-resolution failures escaped into the catch-all and surfaced as *"Network error: Keychain read failed…"* instead of an authentication error. |

### Making M-04 testable without a project-file change

The audit assumed `ShareViewController.swift` compiled into the app target. It does not — it is listed individually in the `Trawl` and `TrawlMac` `membershipExceptions` blocks, so `@testable import Trawl` cannot reach it, and `NSExtensionContext` cannot be injected into a `final` `UIViewController` anyway.

Because those exceptions name the two files individually rather than the `Share/` directory, a *new* file at `Share/ShareInputResolution.swift` is in no exception list and is therefore compiled by every target, tests included. The pure decision logic — which provider outcome means what, and the idempotent termination gate — moved there as Foundation-only code, and `ShareViewController` became a thin adapter over it (`extractSharedContent` went from 130 lines of nested callbacks to 41). No `project.pbxproj` edit was needed.

### Two test defects the integration run caught

Both were faults in the new tests, not in production, and both were fixed by making the test more precise rather than less demanding.

- The M-01 test compared the healthy server's entire request list before and after the retry. `ArrServiceManager.initialize(from:)` ends by spawning a detached health/blocklist prefetch, so that list keeps growing on its own timeline. The assertion now counts `system/status` requests — the handshake every reconnect begins with — which is what "was not reconnected" actually means.
- A share-extension fixture used `https://indexer.example/api?t=get&id=99/Example.Release.nzb`, whose `.nzb` is in the query string, not the path. Production correctly declined to treat it as an NZB link. The fixture now uses a path-based link, and a second test pins the query-string case so the path rule cannot loosen silently.

### Validation after integration

| Check | Result |
|---|---:|
| Entire `Trawl` scheme | **Passed:** 214 logical tests / 298 concrete executions, 0 failed, 0 skipped |
| Generic iOS Simulator build | **Passed** |
| Generic macOS `TrawlMac` build | **Passed** |
| `TrawlShare` build | **Passed** |
| `TrawlWidgets` build | **Passed** |
| `git diff --check` | **Passed** |

New test files in this tranche: `TrawlTests/SABnzbdProfileSwitchTests.swift`, `TrawlTests/ArrRetryDisconnectedTests.swift`, `TrawlTests/ArrAddIntentDuplicateCheckTests.swift`, `TrawlTests/ShareExtensionInputTests.swift`, `TrawlTests/QBittorrentReauthContractTests.swift`. New production file: `Trawl/Share/ShareInputResolution.swift`.

### Still open after the third tranche

Every numbered finding in the original prioritization was fixed and covered. What remained was structural, and the fourth tranche took most of it.

## Fourth tranche — 23 August 2026

### Service contract matrices

The audit's first recommendation — "network contract tests that run production request code" — is now implemented for four services. Each suite drives the real request builder, auth layer, serializer, status validator, decoder and error mapper against a faked *server*, never a faked Trawl method.

| Suite | Approach | Notes |
|---|---|---|
| `JellyfinContractTests` | Loopback `NWListener` | No production change needed. Asserts the real `Authorization` header field-by-field, exact query encoding, pagination boundaries, and the documented `AnyProviderIdEquals` quirk — including that the `SearchTerm` fallback actually fires and narrows. |
| `SeerrContractTests` | Recording `URLProtocol` | Needed a defaulted `sessionConfiguration:` on `SeerrAPIClient`; the default is identical to the configuration it built for itself. |
| `ArrAPIClientContractTests` | Loopback `NWListener` | Covers method/path/query, the `X-Api-Key` header and its configurable name, mutation bodies, and each `ArrError` mapping. Model decoding stays with `ArrStackTests`. |
| `SABnzbdAPIClientContractTests` | Recording `URLProtocol` via the existing `sessionConfiguration:` seam | `SABnzbdAPIClient` was at **0%** line coverage. Now covers the query-driven API shape, both unauthorized signals, and the NZB multipart upload including hostile-filename header injection. |

Every suite covers the audit's checklist: exact method/path/query/headers/body, documented success, mixed-shape fields, 401/403/404/429/5xx, malformed JSON, empty bodies, HTML error pages, and cancellation. No suite relies on `Task.sleep`.

### CI and all-target gating

The audit's other structural gap was that nothing stopped a `TrawlMac` compile failure reaching a branch. That is now gated:

- `Trawl.xctestplan` — code coverage on the app target, test timeouts enabled, and **randomized execution order**;
- **shared schemes** for `TrawlMac`, `TrawlShare` and `TrawlWidgets`. Only `Trawl.xcscheme` was shared before, so those three schemes existed purely as local autocreated artifacts and a fresh clone could not have built them at all;
- `.github/workflows/ci.yml` — six build gates (iOS Debug + Release, macOS Debug + Release, Share, Widgets) plus a serialized test job. Parallel testing is disabled deliberately: several suites stand up loopback servers and share process-wide state;
- `Scripts/assert-test-results.py` — reads the `.xcresult` and fails the job unless `passed > 0`, `failed == 0` and `skipped == 0`.

That last gate is not theoretical. A `test-without-building` invocation during this tranche produced a run with **zero tests** and still exited 0; the script caught it. It also rejects fabricated zero/skipped/failed summaries, verified directly.

### Accessibility labels

Every icon-only control named in the audit now carries an action-shaped `.accessibilityLabel`, plus two more found by sweeping the same files. The calendar's filter menu also gained an `.accessibilityValue`, because the icon's fill state was the only indication of the current filter.

One honest limitation: `TrawlSegmentBar`'s collapsed search affordance uses a bare `.gesture()`, so labeling the image stops VoiceOver reading the SF Symbol name but does not make the tap target actionable. Fixing that means restructuring the control, not adding a modifier.

### Two flaky assertions caught by running the suite repeatedly

Both were faults in the new tests, and both were fixed by making the assertion more precise rather than weaker.

`JSONEncoder` gives no key-order guarantee for synthesized `CodingKeys`, so asserting an encoded body byte-for-byte fails intermittently on an encoder implementation detail. One Seerr assertion and one Arr assertion did exactly that — the Arr one passed on the first run and failed on the second. Both now compare **parsed JSON**, which still pins the exact key set (so a stray or omitted optional still fails) without depending on ordering.

This is precisely what the test plan's randomized ordering plus a repeated run is for. The final validation ran the whole plan three times.

### Validation after integration

| Check | Result |
|---|---:|
| Entire `Trawl` scheme via `Trawl.xctestplan`, run **three times** | **Passed each time:** 318 logical tests / 436 concrete executions, 0 failed, 0 skipped |
| Generic iOS Simulator build | **Passed** |
| Generic macOS `TrawlMac` build | **Passed** |
| `TrawlShare` build | **Passed** |
| `TrawlWidgets` build | **Passed** |
| `git diff --check` | **Passed** |

Coverage grew from 133 logical tests at the original audit to **318**, and from 205 concrete executions to **436**.

### Still open after the fourth tranche

Keychain/App Group coverage, meaningful UI journeys, extension behavioral tests and the Swift 6 warning backlog remained. The fifth tranche took the first two.

## Fifth tranche — 23 August 2026

### Keychain and App Group

`KeychainHelper` was at **0%**. It now has a behavior matrix run inside the app's test host, so it exercises the real Keychain under the app's own entitlements: round-trips including non-ASCII, combining diacritics and a ~21,000-character value; overwrite proven single-item by a raw `SecItemCopyMatching` with `kSecMatchLimitAll` (a plain `read` would return one either way); delete-then-read returning `nil`; reads of never-written keys; and deletes of absent keys not throwing. Every key is namespaced outside all production prefixes and removed on both the success and failure paths.

App Group coverage proves the shared container resolves and is writable, that `ArrIntentSupport.makeModelContainer()` — the helper widgets and App Intents actually use — opens against `TrawlModelSchema.full`, and that a record written through one container is read back through a second, independently constructed one, which is what proves it is really in the shared store rather than a live object graph.

### A latent sharp edge found and recorded, not papered over

A test was written asserting that a `ModelContainer` on an unentitled App Group *throws*, since `TrawlApp.init`'s App Group → local → in-memory fallback ladder depends on exactly that. It does not throw — **it crashes the process**. So that `catch` cannot rescue an entitlement mismatch; it only rescues a store that fails for a catchable reason. The identifier is hardcoded and correct today, so this is a latent sharp edge rather than a live defect. The test was removed (a crashing test takes its whole process with it) and the finding recorded as a comment where the test used to be.

### UI journeys, and the wall that had to be broken first

The three `TrawlUITests` methods were Xcode templates asserting nothing. Replacing them surfaced why real journeys had never been written: with no services configured the app shows `WelcomeFlowView`, whose "Go" button stays disabled until a service exists, and **every setup sheet only persists a profile after a live `testConnection` call succeeds**. The entire tab UI was therefore unreachable from a test.

Two DEBUG-only hooks in `TrawlApp.init()` break that wall along the lines the audit prescribes — seed external state, never Trawl's own behavior:

- `-TrawlUITestInMemoryStore` points the `ModelContainer` at an in-memory store. Deliberately not a "wipe the store" hook: an in-memory container is inherently empty and cannot touch anything on disk, so passing the flag by accident can never destroy real data.
- `TRAWL_UITEST_SONARR_BASE_URL` seeds one real `ArrServiceProfile` plus its Keychain API key. Everything after that is the real app: the real `ArrServiceManager.connectService`, the real `SonarrAPIClient`, real HTTP to a loopback fixture server hosted by the test process, real SwiftData, real navigation.

The end-to-end journey asserts the app clears the welcome gate, reaches the Series tab, renders the fixture's series title, **and** that the fixture server actually received the library request — so the on-screen text is proven to have arrived over real HTTP rather than from a stub.

### Two ordering traps, both found by running rather than reasoning

- Awaiting the async `KeychainHelper` from `init()` under a `DispatchSemaphore` hangs the main thread at launch. XCUITest reports this as *"Timed out while fetching snapshot from testmanagerd"*, which names neither the app nor the deadlock.
- Seeding asynchronously instead is too late: `ContentView` **latches** its welcome-vs-tabs decision the first time it evaluates, so a profile inserted from a `Task` arrives after the app has already committed to the welcome screen.

Both writes are therefore synchronous, which removes both races. A comment at the seed site records why, so neither trap gets reintroduced.

### Validation after integration

| Check | Result |
|---|---:|
| Entire `Trawl` scheme via `Trawl.xctestplan`, run **twice** | **Passed both times:** 324 logical tests / 329 concrete executions, 0 failed, 0 skipped |
| UI journeys specifically | 6 executions, all passed, real app launches of 7–12s each |
| Full six-way CI build matrix run locally as CI runs it | **All passed**, including **Release** for iOS and macOS, which had never previously been built |
| `git diff --check` | **Passed** |

## N-01 — repointing an Arr profile left the library list empty (found and fixed)

**Found 23 August 2026 by a UI journey, after H-01/H-02 were already fixed and unit-covered.** A second-order defect the unit tests structurally could not catch, because they drive the view model directly and never exercise the view that owns the load.

**Symptom.** With Sonarr connected to server A, edit that profile to point at server B and save. The save succeeds and the app really does connect to B — yet the Series tab shows **"No Series"**.

**Evidence from a real simulator run.** Server A received *zero* further requests after the edit (17 before, 17 after), so H-01/H-02 were genuinely fixed and the stale client really was silenced. Server B served the whole connect sequence *and* `GET /api/v3/series`. The screen still rendered the empty state.

**Isolating it.** `ArrRepointLibraryReloadTests` reproduces the model half in-process — real manager, real client, real cache, two loopback servers — driving a freshly created view model through exactly the appear-time sequence the list runs. **Both tests passed**, which proved the manager/cache/view-model layer was correct and the defect lived purely in view lifecycle.

**Root cause.** [`ArrMediaListView`](Trawl/ArrStack/ArrMediaListView.swift) keyed its initial-load task on `activeInstanceID(serviceType)` — the profile ID, which is *exactly what stays the same* across a same-ID repoint. The list view correctly recreates its view model when the client revision rotates, but on re-appear the load task had already started against the **previous** view model, leaving a freshly created, empty one that nothing ever asked to load.

An earlier attempt to add a client-revision component to that task id did **not** work, for the same reason: on re-appear the id was already at its new value, so the swap of the view model an instant later restarted nothing. That attempt was reverted rather than committed.

**Fix.** Key the task on `ObjectIdentifier(viewModel)`. Identity changes exactly when the list swaps view models, which covers both a same-ID repoint and an instance switch, and still re-runs on every appear as before.

**Regression cover.** `ArrRepointJourneyUITests` drives the entire repoint through the real Settings UI against two loopback servers and asserts the list repoints, the old server's title disappears, the new server received the library request, and server A stays silent. It failed before this fix and passes after.

## UI journey #4 — switching Arr instances

Landed alongside the N-01 fix, because instance switching drives the same view-lifecycle machinery by a different route and was worth pinning while that code was fresh.

Two Sonarr fixture servers are seeded as two real profiles. The journey asserts the first instance's library renders, switches through the real "Instance" toolbar menu, asserts the second instance's library replaces it and the first title is gone, asserts the second fixture actually received `GET /api/v3/series`, then switches back and asserts the first instance renders again — a one-way switch could otherwise pass by accident.

The DEBUG seed hook now takes an optional second Sonarr base URL. Both profiles are seeded synchronously with fixed, distinct UUIDs, for the reasons documented at the seed site.

## N-02 — opening the SABnzbd queue crashed the app (found and fixed)

**Severity: high — a hard crash, not a degradation.** Found 23 August 2026 by the SABnzbd unauthorized UI journey, on its very first run.

**Symptom.** Navigating Downloads → Downloads Options → Client Management → SABnzbd → Queue terminated the app. The crash report showed only a SwiftUI `EnvironmentValues` assertion inside a `DynamicViewList` update, with no app frames symbolicated. The actual message came from the simulator's own log:

> `SwiftUICore/Environment+Objects.swift:34: Fatal error: No Observable object of type SyncService found.`

**Root cause.** `SABnzbdManagerView` reads `@Environment(SyncService.self)` and `@Environment(TorrentService.self)`, both non-optional and therefore fatal when absent. The qBittorrent branch of `DownloadClientManagementView` hands both to its hub explicitly; the SABnzbd branch handed over only `SABnzbdServiceManager`, and `SABnzbdClientHubView` likewise forwarded only that to `SABnzbdManagerView`. The fix mirrors the qBittorrent branch.

**Severity was measured, not assumed.** The obvious hypothesis was that this only affected users with no qBittorrent configured — a "services are optional" failure. That was tested by reverting the fix and re-running with a second service (Sonarr) also configured: **it still crashed.** So the defect is in the navigation chain itself and does not depend on SABnzbd being the only service. The one configuration not yet exercised is with a qBittorrent server present, so the blast radius may be the entire SABnzbd queue screen for every user.

**Why nothing caught this earlier.** No test had ever opened that screen. It is reachable only four navigations deep, and the SABnzbd client hub is recent. Unit tests cannot see it at all: the defect is a missing SwiftUI environment injection, which only exists once views are actually rendered and navigated.

**Regression cover.** `SABnzbdUnauthorizedJourneyUITests` walks that exact path, so any future regression crashes the test rather than a user.

## N-03 — a rejected SABnzbd key silently emptied the Downloads tab

Noticed while writing the SABnzbd journey. Not a crash, but the worst *kind* of failure: silent data loss.

When SABnzbd rejected the API key, its jobs simply vanished from the unified Downloads list with no explanation anywhere on that tab. `DownloadsView` never read `sabnzbdServiceManager.connectionError`, and its one error branch explicitly required `!hasSABnzbdServer` — so configuring SABnzbd actively *suppressed* the error. The only screen that surfaced it was the SABnzbd manager view, four navigations away.

The fix adds a compact warning above the unified list. It deliberately does **not** blank the screen: this is a unified view and qBittorrent may still be perfectly healthy, so a failing SABnzbd should annotate, not take over. The SABnzbd journey now asserts the warning appears on the Downloads tab itself.

## UI tests no longer depend on the public internet

`SonarrSeriesDetailView` fires a real TMDb cast lookup through a Cloudflare worker. In the UI suite that was genuine outbound traffic sitting out a 15s timeout repeatedly — **one journey took 140 seconds** — and it would fail outright on a sandboxed CI runner, making the suite's result depend on network conditions rather than on Trawl.

`TMDbClient`'s base URL now honours a DEBUG-only override, and the journeys point it at a closed loopback port so the lookup fails immediately. The cast lookup is `try?` fire-and-forget, so nothing under test depends on it. That journey now runs in **20.8 seconds**, and the whole UI suite is hermetic.

## Fixtures validated against live services — 23 August 2026

A disposable test environment was made available (qBittorrent, two Sonarr, two Radarr, SABnzbd, Jellyfin, Seerr, Prowlarr, Cleanuparr). Every fixture in this repo had until now been written from a reading of Trawl's own code, which by construction cannot catch *"we modelled the API wrong in the first place"*. Real shapes were captured and frozen into `TrawlTests/LiveCapturedShapeContractTests.swift`.

**Verdict: production was right in every case, and the fixtures were wrong.** No production defect was found — but two live behaviors had no coverage at all, because the hand-written fixtures were reproducing an older generation of each API.

| Captured from | Real behavior | What the fixtures had assumed |
|---|---|---|
| qBittorrent **v5.2.3** successful login | **204** with an empty body and a **`QBT_SID_8080`** cookie — the name carries the server's port, and the value contained `/` and `+` | `200` with an `"Ok."` body and a plain `SID` cookie |
| qBittorrent v5.2.3 rejected login | **401** with a plain-text `Unauthorized` body | `200` with a `"Fails."` body |
| qBittorrent `sync/maindata` on an idle server | The **`torrents` key is absent entirely**, not an empty object | An always-present `torrents` object |
| SABnzbd (CherryPy 18.10.0) bad API key | **403** with plain-text `API Key Incorrect` | `401`, or a `200` carrying a JSON error envelope |

`AuthService.performLogin` already accepts 204 *or* 200-with-`"Ok."`, and `extractSessionCookie` already handles both `QBT_SID_*` and legacy `SID`. `SABnzbdAPIClient` already maps both 401 and 403 to `unauthorized`, and `SyncMainData.torrents` is already optional. So Trawl handles all of this correctly — but the modern paths were only ever exercised by accident, and a regression in any of them would have been caught by nothing.

Two operational notes for anyone re-running this: qBittorrent v5 validates the `Host` header, so calls from another machine need `-H "Host: localhost:8080"` naming the container's internal port. **SABnzbd does the same**, which is not in the environment's own notes — without that header every request returns a bare `403 Forbidden` HTML page, which is indistinguishable from a rejected key until the header is added. The SABnzbd API keys in the handoff notes were themselves rejected, so they appear to have drifted from the container's actual config.

### A real Sonarr payload, captured without writing anything

The Sonarr instance had no root folder configured, so adding a series would have meant changing the environment's configuration. `GET /api/v3/series/lookup` returns the same `SonarrSeries` shape from Sonarr's metadata server, so a genuine 36-field payload was captured with **zero writes**.

The load-bearing detail is what a real lookup result is *missing*: **no `id`**, because the series is not in the library yet. Every hand-written fixture here included one, so the real shape of the add-a-series-you-don't-own path had never been decoded in a test. `SonarrSeries` already handles it — a missing `id` becomes a stable negative one derived from the tvdb id, falling back through tvMaze, tvRage and finally a title hash. A non-optional `id` would have failed to decode and taken the whole discover-and-add flow with it.

That makes five for five: every shape captured from a live service confirmed production was already correct and the hand-written fixture was the naive one.

### Still worth doing against live services

- Radarr's equivalent lookup shape, and a real movie payload.
- Re-check the qBittorrent onboarding journey (on `wip/ui-journeys`) against a real server, since its flakiness is in the sync-then-render half and may well be a fixture-shape problem rather than a timing one.
- Jellyfin's `AnyProviderIdEquals` quirk, which the `SearchTerm` fallback is built on, has still only been reproduced against a fixture.

## N-02's whole class closed at the root

N-02 was one screen crashing on a missing `@Environment` value. The question worth asking before a store release was how many *other* screens could do the same, so the environment graph was enumerated rather than guessed at.

There are **211 non-optional `@Environment(Type.self)` reads across 11 types**. SwiftUI traps at runtime when one is missing — a missing value is a hard crash, not a degraded view. `TrawlApp` injects 7 of those types at the app root, so they can never be missing.

The two that are not root-injected are **`SyncService` (28 required reads)** and **`TorrentService` (15)**, because both come from `AppServices`, which only exists once a qBittorrent server is configured. Those 43 reads were the exposed surface, and they are exactly the two types N-02 crashed on.

Both are now injected at `ContentView`'s root using the same `appServices ?? disconnectedServices` fallback `tabContent` already used, so no navigation path below it can lose them. Per-screen injections further down still win for their own subtrees; this is a floor, not a replacement.

**The fix was verified, not assumed.** The site-specific N-02 fix in `DownloadClientManagementView` was temporarily reverted and the SABnzbd journey re-run: it passed, proving the root injection alone prevents the crash. The site fix was then restored as defence in depth.

## A navigation smoke walk, because untested screens are where the crashes were

N-02 crashed on a screen four navigations deep that no test had ever opened. `NavigationSmokeWalkUITests` exists to make "nobody has opened this screen" untrue for as much of the app as can be reached with fixture-backed services.

It is deliberately broad rather than deep — the other journeys assert business behavior; this one asserts that screens *render and pop back*. Five focused methods cover the tab bar, the More tab's destinations, Downloads' management routes and both client hubs, the Automation and System hubs' children, and the calendar sheet plus Settings' service rows. Each screen is asserted on real on-screen content, never on `app.exists`, which stays true even when the app under test has died and therefore proves nothing.

**It found no crashes on its first run**, which is itself the result worth recording: it ran against the root-injection fix above, which had already closed the class N-02 belonged to.

It did surface one genuine ambiguity. `SABnzbdClientHubView` and `SABnzbdSettingsView` both use `.navigationTitle("SABnzbd")`, so popping back from settings lands on a screen with the same title. That is not a defect, but it is worth knowing: any test — or any breadcrumb-based reasoning about where the user is — cannot distinguish those two screens by title alone.

The walk costs roughly five minutes of simulator time, which is the bulk of the UI suite's runtime. If that becomes a problem on CI, split it out of the pull-request plan rather than thinning the assertions.

## Onboarding — from 0% to covered

`OnboardingViewModel` was at **0%**, and it is the first thing every new user touches. Fifteen tests now drive the real view model against a loopback qBittorrent, using the response shapes captured from a live v5.2.3 server.

Covered: pre-flight validation (empty and whitespace hosts, missing credentials, unsupported schemes, URLs carrying a path) with the assertion that **no request is made**; a rejected 401 login and a 5xx login persisting nothing; a successful connection persisting exactly the entered values, with the display name defaulting to the normalized host; a new active server deactivating the previous one; editing a server in place; and the legacy `200`/`"Ok."`/`SID` login still working alongside the modern `204`/`QBT_SID_<port>` one.

**M-03 is pinned at the integration level**: a 500 carrying an HTML body, and a non-UTF8 body, are both rejected rather than being turned into a version string that passes onboarding.

### What is still not covered, and why

Rollback on a persistence failure — the audit's named concern — is **deliberately not covered**. The attempt relied on `ServerProfile.id`'s `@Attribute(.unique)` making `modelContext.save()` throw for a colliding pending insert. Against an in-memory store it does not throw, so the test ran straight through the success path while asserting it had exercised rollback. It was removed rather than reshaped into something that merely goes green, and the reasoning is recorded at the site.

Covering it properly needs an injectable persistence or Keychain seam in `OnboardingViewModel`. Worth knowing meanwhile: **the rollback runs as an unstructured, unawaited `Task` inside a `defer`**, so `validateAndSave` returns `false` before the undo has necessarily completed. A caller inspecting the profile or Keychain immediately after a `false` result can observe half-rolled-back state. That is a real latent defect, found by reading rather than by a failing test.

Also pinned as current behavior rather than fixed: a 5xx during **login** is indistinguishable from a bad password to the user, because `AuthService.performLogin` treats anything that is not `204` or `200`+`"Ok."` as `.authFailed`.

### The qBittorrent onboarding journey remains parked

Its fixture now sends the real v5 shapes rather than v4 ones, which is progress, but the journey still cannot reliably leave the welcome flow: the "Go" button exists and reports enabled, yet never becomes *hittable*, so the tap never lands. That is a UI-automation problem rather than a product one — the button's action is a plain `isInWelcomeFlow = false`.

It stays on `wip/ui-journeys`. The onboarding logic it was meant to cover is now covered far more thoroughly, and deterministically, by the fifteen unit tests above.

## Search — from 0% to covered

`SearchViewModel` was at **0%**: *"Search, library reconciliation, cancellation, and profile changes are unverified."* Fifteen tests now cover it, driving the real view model against loopback Arr servers with a continuation gate holding responses until the test releases them. No sleeps.

The load-bearing one is **stale-result suppression**: two concurrent lookups where the newer completes first and the older is released afterwards. The older must not overwrite the newer. That is the M-05 defect class, which has already been found twice in this codebase, and search was the obvious next place for it.

Also covered: cancellation leaving no stuck spinner; library reconciliation by `tmdbId` and by case-insensitive title, including a nil-`tmdbId` row that must not match against an unrelated arr-internal id that happens to share the same number; switching the active Sonarr instance discarding the previous instance's results; a failed reconnect clearing the lookup view model entirely; and empty, no-match, and 500-error searches each producing the real user-facing state rather than a silent empty list.

**Two things found by reading, not changed.** In `ArrMediaLibraryViewModel.performLookup`, a `guard !Task.isCancelled else { return }` after the network await returns *without* resetting `isSearching`. It is currently unreachable, because `HTTPTransport` maps cancellation to a thrown `CancellationError` and the `catch` branch does reset the flag — but if that mapping ever regresses, the symptom is a spinner that never stops. And `resetArrLookup()` cancels its task without setting it to `nil`.

**Not covered:** the real 300ms debounce, which needs a clock seam the view model does not have (the tests use its `immediate: true` path, exercising the same cancel/restart logic without the delay), and the `force:`/re-trigger dedup guard.

## N-04 — pasting SABnzbd's add-only key gave the wrong explanation

Found on 23 August 2026, once real SABnzbd credentials were available. This is the clearest example so far of something no fixture written from our own code could have caught.

SABnzbd issues two API keys: a full one, and an add-only "NZB key". Measured against a real SABnzbd 5.1.1 with the NZB-only key:

| mode | status |
|---|---|
| `version` | **200** |
| `queue` | **403** |
| `history` | **403** |

So the add-only key is not simply rejected — it is *accepted* for some modes and refused for others.

`SABnzbdServiceManager` already had the right message for this — *"Trawl needs the full SABnzbd API key, not the add-only NZB key."* — sitting in a `catch SABnzbdAPIError.insufficientAPIKey` arm. **But nothing in the codebase ever threw that error.** Grep confirms the case was declared, caught, and given an `errorDescription`, and never produced. An existing contract test had even noticed the arm was unreachable without acting on it.

The result: a user who pasted the NZB key was told *"SABnzbd rejected the API key. Update it in Settings."* and sent off to re-copy a key that was never wrong.

**Fix.** `connectService` ran `getVersion()` and `getQueue()` under a single `async let` + combined `try await`, which discards *which* of the two failed — the only signal that separates the two cases. They now run concurrently but with separate outcomes: a version call that succeeded alongside a rejected queue call is the signature of the right key from the wrong tier.

Both branches are pinned in `LiveCapturedShapeContractTests` using the exact statuses measured above, so the add-only key reads as a tier problem and a wholly wrong key still reads as a rejected key.

## Three swallowed taps, one pattern

The UI suite hit the same failure three times in different places: the welcome flow's "Go", the Downloads overflow's "Blocklist", and the SABnzbd actions menu. In each case a tap was dispatched at an element that existed but was not yet hittable, the tap was silently dropped, and the test failed on the *next* assertion — which then blamed the destination screen for a tap that never landed.

All three now wait for the target and retry within a bounded loop built only from `waitForExistence`. The SABnzbd journey was run three times consecutively to confirm, and the full plan twice.

This is worth recording because the misleading part is not the flake, it is the *attribution*: every one of these failures pointed at the wrong screen.

## The Jellyfin provider-id quirk, finally confirmed against a real server

The project's working assumption has been that Jellyfin ignores `AnyProviderIdEquals`, and the `SearchTerm` fallback in `JellyfinAvailabilityResolver` is built entirely on that. It had never been reproduced against anything but our own fixture.

Confirmed against **Jellyfin 10.11.11** with a two-item library. The filter is not merely unreliable — it is **ignored outright**:

| query | result |
|---|---|
| `AnyProviderIdEquals=Tmdb.9836` (really present) | both items |
| `AnyProviderIdEquals=Imdb.tt0859444` (really present) | both items |
| `AnyProviderIdEquals=Tmdb.999999999` (**matches nothing**) | **both items** |

The last row is the decisive one. A query that should match nothing returns the entire library, so a client that trusted the server to filter would mark **everything** as available.

Trawl does not: `JellyfinAvailabilityResolver` re-filters every candidate locally via `localMatches`, and `providerID(for:)` matches the key both exactly and case-insensitively. Real Jellyfin returns `Tmdb`, `Imdb` and `Tvdb`, which the production key lists already cover.

The captured payload is pinned in `LiveCapturedShapeContractTests`, with the false-positive guard asserted directly: an absent id must match nothing, and `TmdbCollection` (Happy Feet's is `92012`) must never be read as a Tmdb id, since that would make an unrelated title look available.

That makes **seven for seven**: every behavior captured from a live service has confirmed production was already correct. The value has consistently been that these paths were passing by accident, with nothing to catch a regression.

## UI journey #2 — pause, resume, delete, with the server mutation asserted

`TorrentListView` and the Downloads surface were **1,145 executable lines at 0%** — the app's core, and completely untested.

The earlier attempt to reach it by driving the real onboarding UI was abandoned. qBittorrent is now seeded the same way Sonarr and SABnzbd already are, so the app launches already connected and lands in Downloads. The fixture is **stateful**, unlike the read-only ones: pausing, resuming and deleting change what the next sync poll reports, so the on-screen result is driven by the server rather than by a local flag.

Each action is asserted twice — the user-visible change, and the **recorded server request**:

| action | asserted request |
|---|---|
| Pause | `POST /api/v2/torrents/stop` with the torrent's hash |
| Resume | `POST /api/v2/torrents/start` with the hash |
| Delete | `POST /api/v2/torrents/delete` with the hash **and `deleteFiles=false`**, proving the right confirmation button wired the right value |

Note the v5 path names: `stop`/`start`, not v4's `pause`/`resume`.

### Absence is not assertable in this view, and that took four attempts to learn

`DownloadsView` deliberately keeps its `List` mounted even when the current segment filters down to nothing, so the segment-bar search field does not lose keyboard focus. A row filtered out of the visible segment therefore stays in the accessibility tree indefinitely. Every obvious way to assert it is gone fails, each differently:

- `exists` — stays `true`; the element is mounted, just invisible.
- `count` on a scoped query — still counts it (observed as `2`).
- `isHittable` — **throws** rather than returning false, because the frame has collapsed to zero: *"Activation point invalid and no suggested hit points based on element frame"*.

The assertions are therefore written as the **positive empty state** the user actually sees. That is also the more honest test: the load-bearing proof that a mutation happened is the recorded server request, not the absence of a row from a tree that deliberately retains it.

Also worth knowing: an app-wide `app.buttons` match for the torrent's name matches the success banner raised after a delete, which names the torrent — so an "is it gone anywhere" assertion fails on the confirmation of the very thing being asserted. Scope such queries to the list.

Ran three consecutive times before landing, plus the full plan.

## Radarr — the symmetric gap, now covered

Sonarr had several journeys; Radarr had none, and `RadarrMovieDetailView.swift` was **1,952 executable lines at 0%** — the largest untested file in the project. That matters more under the planned 4K + HD model, where Radarr stops being a mirror of Sonarr.

`RadarrJourneyUITests` seeds a Radarr profile, renders the Movies tab from a fixture, opens the movie detail screen and asserts real payload content (studio, and the overview verbatim — neither of which appears on the list row, so they cannot be satisfied by a row still mounted underneath during the push). It then toggles **Monitored** off from the detail toolbar and asserts both halves: the badge disappears, and the fixture received exactly one `GET /api/v3/movie/{id}` followed by one `PUT` whose body carries `"monitored": false`. A wrong value there would make the toggle a silent no-op against real Radarr.

The fixture's movie fills every field the detail screen renders, because a two-field stub renders an empty screen and asserts nothing.

### A crash trap in XCUITest worth knowing

Two element queries **crashed the test runner outright** rather than failing:

```
*** Assertion failure in -[XCUIElementQuery _predicateWithType:identifier:]
```

Both were subscript lookups by a long or punctuated string — `app.navigationBars["Fixture Movie: Trawl Signal"]` and `app.staticTexts[<a ~160-character overview>]`. The runner dies, the whole journey is lost, and the log names no assertion, so the failure looks like an infrastructure problem rather than a test bug. Match long or punctuated text with a `CONTAINS` predicate on a distinctive fragment instead of subscripting by the whole string.

Also: the system back button's title is dropped when it does not fit, and the remaining chevron is not reliably reachable by label or by position when the toolbar also carries a trailing item. The interactive pop gesture is what a user does anyway and depends on neither.

## A flaky assertion removed rather than retried

The SABnzbd journey's final step drove the actions menu to prove a mutation is inert once disconnected. It passed consistently alone and failed intermittently in full-suite runs, where load delays the menu's presentation.

Retrying the tap made it **worse**: tapping a `Menu` toggles it, so a retry can close a menu that had in fact opened, and an even number of attempts leaves it shut. The step was removed rather than tuned into apparent stability.

The property is not lost. `SABnzbdServiceManagerConcurrencyTests` already proves it deterministically at the manager level — after an unauthorized response clears the active client, a mutation issues no network request. What is no longer covered is only the UI affordance being reachable while disconnected, which is not worth an intermittently red suite.

### Note: multi-instance Arr is heading somewhere else

Confirmed by the project owner on 23 August 2026: multi-instance Sonarr/Radarr is intended to become a **4K + HD pair that are both active at once**, presented unified the way the Downloads view is — not the switch-between-one-active model the app has today (which is the shape Seerr uses).

That means journey #4 above pins **current** behavior only. When the unified model lands, that journey should be rewritten rather than extended, and its cost is deliberately low for that reason.

Two things worth knowing before that work starts:

- `ArrLibraryCache` is already **instance-keyed**, which is the right shape for a unified view: two instances' libraries stay separate in the cache and are merged for presentation. This will not need reworking.
- The obstacle is the *singleton* "active instance" concept in `ArrServiceManager` — `activeSonarrEntry`, `sonarrClient`, `activeSonarrInstanceID` and friends. A unified view turns each of those into a collection, and every caller of `sonarrClient` has to answer "which one?". That is where the risk lives, and it is broad.
- **N-01's lesson gets more important, not less.** With two live clients, any view-lifecycle key must track the identity of the thing being displayed rather than a profile ID. The same defect class re-appears immediately if a list keys work off "the active instance".

The fixture harness generalizes to this without change: two loopback servers are already stood up per test, and the DEBUG seed hook already seeds two Sonarr profiles.

## One UI journey written but not landed

`QBittorrentOnboardingJourneyUITests` plus `QBittorrentFixtureServer` are preserved on the branch `wip/ui-journeys` rather than committed, because the test is not reliably green and a flaky test is worse than none.

It covers the audit's journey #1 — failed login, then successful login, then the torrent list — driving the real onboarding UI with no production hooks at all, and asserting the real `QBError.authFailed` copy. The login half is sound. **It passed once and then failed three consecutive runs**, always on the final assertion that the fixture's torrent appears in the Downloads tab, and always after burning its timeout. That is timing sensitivity, not a stable regression test: the sync-then-render half needs a deterministic signal rather than a longer wait, and most likely needs a real qBittorrent to confirm the fixture's login and `sync/maindata` shapes are right in the first place.

Two UI-query facts worth keeping for whoever picks this up: the More/Settings rows are `Button`s whose accessibility label merges title and subtitle (`"Settings, App and server configuration"`), and `ArrSetupSheet` overrides `ServerURLField`'s title with an example URL, so its host field must be matched on `placeholderValue`. `XCUIElement+Scrolling.swift` exists because SwiftUI renders `Form`/`List` rows lazily — a control merely below the fold is absent from the accessibility tree entirely, so a plain `waitForExistence` fails for something the user could reach by scrolling.

### Still open

- **Extension behavioral tests.** `ShareViewController` remains unreachable from `TrawlTests`; only its extracted decision logic is covered. Reaching the controller needs a `project.pbxproj` membership change, deliberately not made — see the note in the third tranche.
- **True cross-process Keychain/App Group verification.** The current tests prove the shared configuration round-trips within one process; proving the signed entitlements agree across installed binaries needs an extension-side probe.
- **More UI journeys.** The harness now exists and one journey uses it; the audit lists nine. The remaining ones need fixture servers for qBittorrent, SABnzbd, Jellyfin and Seerr alongside the Sonarr one.
- **The Swift 6 isolation/sendability warning backlog.** Deliberately not attempted: it is a broad mechanical refactor across files that were just stabilized, and the audit itself classes it as warning debt rather than proven races.
- An `LSSupportsOpeningDocumentsInPlace` / `UISupportsDocumentBrowser` Info.plist decision. Trawl reads a shared file's bytes and uploads them without editing it, so opening a copy is the correct semantic — but declaring that explicitly is a product call.
- The optional scheduled real-service contract lab.

## Sixth tranche — 24 August 2026

Four commits (`4924a8f`, `6001d6e`, `5fa4016`, `0869b5e`) taking the plan from **383 executions to 614**, and finding four more defects. Every surface in this tranche was chosen the same way: the largest files with no coverage at all.

### Jellyfin and Seerr — the state machines above the wire contracts

Both stacks already had contract tests for their API clients. Nothing above them was covered. 93 tests now drive the real production paths — a loopback `NWListener` for Jellyfin, whose `JellyfinAPIClient.init` has no session seam, and a recording `URLProtocol` for Seerr, whose `SeerrAPIClient` takes a `sessionConfiguration`.

`JellyfinAvailabilityResolver` was the load-bearing target. Its three-tier lookup — provider-ID `findItems`, then a dash-normalised title search, then the most distinctive word — exists because real Jellyfin servers ignore `AnyProviderIdEquals`. The tests pin that a tier-1 hit means **tiers 2 and 3 are never requested** (asserted by request count against an item whose name and year match nothing), and that a junk tier-1 response still resolves through the fallback. Both cache caps are pinned by eviction: 64 availability entries, 32 episode entries. Note the eviction is FIFO by *first insertion*, not LRU — `insertionOrder.append` only runs when the key is new, so re-resolving a hot key never refreshes its position. The tests assert the actual behaviour; the name is the only thing misleading.

Seerr's issue list got the pagination arithmetic at its boundaries, the `requestVersion` guard that rejects stale in-flight responses, and the search loop's break-on-empty-page protection against a server that over-reports its total.

### Single-instance, pinned as a contract in both stacks

`JellyfinSetupViewModel.persist` and `SeerrSetupViewModel.login` both resolve their save target as `first(where: \.isEnabled) ?? first`. Signing in against a *different* server therefore **repoints the existing profile** rather than adding a second one. This surfaced as a test failure — the test had assumed a second profile would appear — and was resolved by pinning the real behaviour across three tests: empty-store creation, the repoint, and exclusive-enable collapsing a two-enabled store back to one.

This is the single-instance model the rest of both stacks depend on. It is recorded here because multi-instance Radarr/Sonarr (4K vs HD) is planned; if Jellyfin or Seerr ever need the same, these tests fail loudly instead of silently overwriting a configured server.

### N-05 — Jellyfin cached availability failures forever (found and fixed)

`state(for:)` TTL-expired only `.resolved`. A `.failed` entry fell straight through, and `ensureLoaded` returns early on `.failed` — so one dropped connection or 500 pinned that card in an error state for the life of the resolver. Nothing retried it except `invalidate`/`invalidateAll`, which in practice only happen on `connectService`/`disconnect`.

The failure row does render a **Retry** button, so this was never a silent hang. But the asymmetry was real: navigating away and back would not re-attempt. Failures now expire on their own 60-second window while successes keep the 300-second one — a transient error self-heals on next appearance, a good answer is not re-fetched on every glance. The 60s figure is a judgement call, not a measured one.

**Latent, not fixed:** `.loading` is also never TTL-expired, and both `guard !Task.isCancelled else { return }` gates in `performLookup` exit without writing state. Today the only canceller is `invalidate`, which removes the entry first, so a stuck spinner is unreachable — but it is one new cancellation call site away from a permanent `.loading` that `ensureLoaded` will also refuse to retry.

### N-06 — the Jellyfin setup form leaked the previous server (found and fixed)

`seed(from: nil)` means "add a new server". It set `hasSeededInitialState`/`seededProfileID`/`error` and then returned **before** resetting the form, leaving the previously seeded server's host, display name, auth mode and TLS setting on screen. One careless save from repointing the server just edited — which matters more given the single-instance behaviour above, since `persist` would have overwritten it rather than adding a second. The nil branch now clears to defaults.

### A clock seam, because the TTL branches were unreachable

Timestamps came from a bare `Date()` with no seam, so neither expiry branch could be tested at all. `JellyfinAvailabilityResolver` now takes `init(now: @escaping () -> Date = Date.init)`; production is unchanged. `JellyfinManualClock` drives expiry directly. The shipped 60/300s values are the ones exercised — the tests move the clock rather than shortening the windows, so expiry is asserted exactly and cannot flake under load.

### N-07 — Bazarr went on talking to the old host (found and fixed)

`SonarrViewModel` and `RadarrViewModel` both hand their base `ArrLibraryViewModel` a `clientProvider` closure, so a retained view model resolves the client on every access — exactly what `ArrClientLifecycleTests` proves for both. `BazarrViewModel.init` passed only `client: serviceManager.activeBazarrEntry?.client`, a snapshot taken once. A retained `BazarrViewModel` therefore kept issuing requests against the host it was born with: editing a Bazarr profile's URL and reconnecting left the screen silently reading from the **old server**.

This is the same stale-client class as N-01 and the H-01/H-02 work. Bazarr was simply the sibling that got missed.

**Worth recording about how it was nearly cemented rather than fixed.** The test written for it originally asserted the *broken* behaviour as though it were the contract — named "keeps using its original client", with a careful comment explaining why Bazarr "differs" from Sonarr and Radarr. Taken at face value it would have locked the bug in permanently and made the eventual fix present as the regression. Reading the assertions rather than the pass count is what caught it. Subsequent agent briefs now carry an explicit instruction: never pin a bug as the contract, and if current behaviour must be recorded, make that unmistakable in the test name.

### Prowlarr, and the seam that invites worthless tests

`ProwlarrViewModel` is written against a protocol seam, which makes "conform a fake, assert the fake was called" trivially easy and completely without value. None of the 32 tests do that: every one drives the real `ProwlarrAPIClient` → `ArrAPIClient` → `HTTPTransport` → `URLSession` against a socket, resolved through a real `ArrServiceManager` via the production `connectService` path. Mutation bodies are asserted as parsed JSON, never encoder bytes.

This suite needed **no `Task.yield` loops at all** — every search is awaited directly and every ordering barrier is a `CheckedContinuation` resumed from the fixture server's own connection callback. It is the cleanest synchronisation story in the plan and the model to copy.

One assumption in the brief was wrong and was corrected rather than fabricated around: there is no per-indexer partial-failure path inside the view model, because Prowlarr fans out server-side — `performSearch` makes exactly one `GET /api/v1/search` for all indexers.

### The import grouping engine

`LibraryImportScanViewModel` decides which bucket every scanned file lands in: new, in-library, identified-pending-add, unidentified, or blocked. Getting it wrong shows the user the wrong section and can import the same file twice. 54 tests across four suites cover bucket membership, selection state — including that ready and blocked selections stay independent — the pure path/poster/summary helpers, and the identification transitions.

### Multi-instance indexer routing, and a gap that would have passed under its own bug

`ArrIndexerManagementViewModel` operates on two Arr instances at once. Every operation must reach the instance it was addressed to; misrouting edits the wrong server's indexers with no visible sign. The tests stand up two independently-ported Sonarr/Radarr instances on one `ArrServiceManager` and assert each operation's socket saw it and the other's did not.

As first written, the `addIndexer` and `updateIndexer` routing tests addressed only the **first-connected** profile — which is also the manager's active instance. A profile-blind client lookup would have routed those correctly, so they would have passed under precisely the bug they exist to catch. The non-active-profile variants were added for both, these being the destructive cases: creating or renaming an indexer on the wrong server. The negative control now fails **6 of 11** tests instead of 4.

### Negative controls as the standard of evidence

Every behavioural claim in this tranche was verified by breaking the production behaviour, watching the right tests fail for the right reason, and restoring from a plain file copy — never `git stash` or `git checkout`, and diffed afterwards to prove an exact restore.

| Control injected | Result |
|---|---|
| Revert Bazarr's `clientProvider` | Exactly the retained-client test fails, on both assertions; other 20 pass |
| `StreamingSearchTracker.isCurrent` → `true` | Exactly the 2 token-identity search tests fail; other 5 pass |
| Drop `toggleIndexer`'s server-record write-back | Exactly the 1 test distinguishing canonical from optimistic fails |
| `sonarrClient(for:)`/`radarrClient(for:)` → profile-blind | 6 of 11 indexer-management tests fail, all on the non-active profile |
| Drop `!isIdentifiedPendingAdd` from the unidentified bucket | 5 grouping/selection tests fail, incl. "exactly one bucket" |
| Revert the Jellyfin seed fix and the failure TTL | Exactly the 4 intended tests fail; the resolved-TTL test correctly stays green |

### Two harness traps that manufacture false confidence

Both produced a *green* result rather than a visible failure, which is what makes them dangerous. Both are now recorded outside this document as well.

- **`xcodebuild -quiet` prints `error:` lines on builds that succeeded** — `error: the following command failed with exit code 0 but produced no further output`, emitted for tasks that print nothing. Grepping that output for `error:` reported TrawlMac and TrawlWidgets as broken when both were fine. Verification runs no longer use `-quiet`.
- **`-only-testing:` with a name matching no suite runs zero tests and still prints `** TEST SUCCEEDED **`.** Swift Testing suite names frequently do not match their filename: `LibraryImportScanViewModelTests.swift` declares four suites, none named after the file. A guessed name produced a passing run that proved nothing. Every validation now goes through `-resultBundlePath` and `Scripts/assert-test-results.py`, which fails an empty run explicitly.

### Validation

| Check | Result |
|---|---:|
| Full `Trawl.xctestplan`, after each commit | **Passed:** 476 → 480 → 533 → **614 executions**, 0 failed, 0 skipped |
| Every new suite, run twice in isolation | Identical results both runs |
| Six negative controls | Each failed exactly the intended tests, nothing else |
| `Trawl`, `TrawlMac`, `TrawlShare`, `TrawlWidgets` | **All build** |

### Still uncovered, stated plainly

- **The import screen's network paths** (`loadFiles`, `loadInLibraryStatus`, `searchCatalog`) and its **auto-identify loop**. The agent covering this surface was interrupted before filing a report, so the gap is inferred from the suite names rather than from its own account — treat the import coverage as "grouping and selection verified", not "screen covered". It also left an injected negative-control edit in the production file, which was reversed by hand.
- **UI coverage is roughly 12–15% of screens.** 18 UI test functions against ~138 `.navigationTitle` call sites across 89 files and 118 sheet presentations. Of those 18, only 9 are real journeys; 5 are the render-without-crashing smoke walk, 3 onboarding, 1 a launch screenshot.
- **Five stacks have no UI coverage at all** — Jellyfin, Seerr, Bazarr, Prowlarr, Cleanuparr appear in the UI test target only in a comment recording their exclusion.
- **`MoreView` (4,134 lines), `SettingsView` (1,037) and `NotificationTabBarAccessory` (1,811)** are effectively untested at both tiers.
- **TrawlMac still has no UI tests.**
- **Parked with the maintainer's agreement:** the unawaited rollback `Task` in `OnboardingViewModel.validateAndSave`, and the widget/share-extension provider shells, which need a `project.pbxproj` membership change.

### On the two tiers, since this tranche is evidence for both

Of the four defects found *before* this tranche, three — N-01, N-02, N-03 — were view-layer faults that no view-model test could structurally have caught: a `.task(id:)` identity bug, a missing `.environment()` injection that crashed on open, and conditional rendering that blanked a list. All four defects found *in* this tranche were logic-level and were caught by view-model tests.

The two tiers are not ranked; they catch disjoint classes. View-model tests catch wrong answers. UI tests catch the app being assembled wrong — crash on open, blank screen, dead navigation — which the view model cannot see because the view model is fine. The recommended split is the bulk of effort on view models and services, cheap render-and-navigate coverage across all screens to catch the crash class, and full journeys reserved for destructive paths.

## Seventh tranche — 24 August 2026

Six commits (`a80fa74`, `be42867`, `a84865e`, `6d15e04`, `e77c463`, `25ee6bd`) closed the five service stacks that had no UI coverage at all. Eight new journeys launch the real app against per-test loopback servers; no production client, manager, decoder, navigation route, mutation method, or final view state is mocked.

The shared harness is DEBUG-only and synchronous. `TrawlApp` creates a fresh in-memory store, writes the fixture credential to the same Keychain key production reads, inserts the real profile model, and completes all of that before `ContentView` evaluates the welcome gate. Fixed test-only UUIDs keep repeated launches from leaking orphaned credentials. Release behavior is unchanged.

### The five stacks now covered through their real UI

- **Seerr:** More → Requests & Access → Issues → issue detail. The fixture proves authenticated list/detail requests, detail-only comment rendering, the Resolve mutation, and the resulting Reopen state.
- **Jellyfin:** More → Media Server → Sessions. A decoded user and episode are rendered; Stop Playback drives the confirmation, sends exactly one authenticated production POST, reloads, and ends in the server-backed empty state.
- **Bazarr:** Movies → a real Radarr movie detail → Subtitles. The journey combines real Radarr and Bazarr profiles, renders the assigned profile and missing language, and proves the authenticated `radarrid[]=501` request reached Bazarr.
- **Prowlarr:** three journeys cover Indexers/detail/Test Indexer, Linked Applications, and Proxies plus Tags/create. Every displayed row comes from documented `/api/v1` response shapes and every mutation is asserted at the receiving socket.
- **Cleanuparr:** the healthy dashboard renders decoded activity, service-health errors and readiness; Include Dry Runs changes the real query and remains visibly enabled. A separate launch returns a real 503 and asserts the user-facing unavailable state and exact service message.

The Cleanuparr journey also exposed two reusable UI-test lessons. A SwiftUI `LabeledContent` row may be one combined accessibility element rather than separate label/value texts, and a test that walks down a long `List` cannot then use a down-only discovery helper to find content above it. The final journey follows screen order and queries the combined row. The toggle itself needed a tap on the switch control's trailing region; a center tap hit its label without changing the value. These were harness defects, not product defects, and were fixed without weakening the HTTP or rendered-state assertions.

### Validation

| Check | Result |
|---|---:|
| Five new UI classes together | **Passed:** 8 executions, 0 failed, 0 skipped |
| Full `Trawl.xctestplan` | **Passed:** **622 executions**, 0 failed, 0 skipped |
| Zero/incomplete-result guard | Both result bundles accepted by `Scripts/assert-test-results.py` |
| `Trawl`, `TrawlMac`, `TrawlShare`, `TrawlWidgets` | **All build** |

Authoritative results: `/tmp/trawl-tier1-ui-2.xcresult` for the five-stack UI gate and `/tmp/trawl-full-after-tier1-ui.xcresult` for the complete plan.

### Still uncovered, stated plainly

- **More/Settings breadth is now the best next UI target.** These screens own most service-admin navigation and remain much larger than their journey coverage. Cheap open/render/back checks can catch missing environment injection, dead destinations and blank assembly without turning every screen into a slow end-to-end test.
- **High-value sheets and destructive flows** remain uneven: setup/edit forms, delete confirmations, path mappings, import scanning and notification settings should follow.
- **TrawlMac still has no UI-test target.** It is protected by compilation and shared logic tests, not platform-specific navigation journeys.
- **Widget and ShareViewController process shells remain parked** with the maintainer's agreement. Their pure decision logic and target builds are covered; installed-extension behavior needs deliberate test-host and target-membership work.
- UI coverage is meaningfully broader but is not “every screen”: 26 UI test functions now exist, including smoke, onboarding and 17 real journeys. The remaining work should continue to prioritize assembly risk and user mutations rather than raw screen-count inflation.

## Eighth tranche — 24 August 2026

Five commits (`83e0fd0`, `7b1427f`, `93f2bd8`, `804ed2e`, `f6c0fd9`) took the next highest-risk iPhone surface: More/Settings assembly and the destructive management flows reachable from it. Nine journeys use the public UI and real production clients against per-test loopback servers. They do not install final view-model state or substitute method mocks.

### More and Settings breadth

- Settings opens configured Sonarr and Radarr profile management after their real connection handshakes.
- More → Library Management → Subtitles reaches Bazarr Language Profiles and renders authenticated fixture data.
- More → Automation & Clients → Remote Path Mappings loads the Sonarr/Radarr fan-out destination.
- More → System → Health aggregates real multi-client health responses and renders the all-clear state.
- Removing a configured service uses the real Settings confirmation flow and verifies the profile disappears rather than merely checking that an alert exists.

### Destructive management journeys

- **Remote path mappings:** the journey loads server state, adds with the exact production POST body, edits with the exact PUT body, and deletes only after the confirmation dialog. Every mutation is asserted at the receiving socket and followed by visible list reconciliation.
- **Jellyfin libraries:** an authenticated GET renders the server library; swipe Remove presents the destructive confirmation, sends the exact DELETE, refetches, and ends in the server-backed `No Libraries` state.
- **Library import:** one Sonarr journey scans a real fixture root, verifies manual-import query shape, separates one owned episode from one ready file, selects the importable group, and reaches Review Selection without prematurely posting a command. A second journey expands a blocked group, opens Identify File, performs a real catalog lookup, and proves no import command is sent before explicit confirmation.

The import journey exposed a real accessibility defect in the collapsed Blocked section. SwiftUI exposed only static header text and an unreliable implicit hit region, so VoiceOver and UI automation had no dependable disclosure control. The header is now an explicit button with an identifier, expanded/collapsed value, hint, and visible chevron; the journey exercises that production affordance.

### Validation

| Check | Result |
|---|---:|
| Five Settings/management UI classes together | **Passed:** **9 executions**, 0 failed, 0 skipped |
| Full `Trawl.xctestplan` | **Passed:** **631 executions**, 0 failed, 0 skipped |
| Zero/incomplete-result guard | Both result bundles accepted by `Scripts/assert-test-results.py` |
| `Trawl`, `TrawlMac`, `TrawlShare`, `TrawlWidgets` | **All build** |

Authoritative results: `/tmp/trawl-settings-management-integrated.xcresult` for the nine-journey gate and `/tmp/trawl-full-plan-settings-management.xcresult` for the complete plan.

### Still uncovered, stated plainly

- **Notification settings and the remaining setup/edit forms** are the next iPhone UI tranche. Prioritize user-visible persistence, validation failures and destructive confirmation over open-and-close screenshots.
- **More iPhone destructive journeys** remain useful where a view owns mutation wiring that view-model tests cannot observe.
- **TrawlMac UI remains deferred at the maintainer's request.** Its target still passes the compile gate and shares the tested service/view-model logic.
- **Widget and ShareViewController installed-process shells remain parked** by agreement; their pure decision logic and build membership are covered.
- The suite now contains approximately 35 UI test functions. This is broad, meaningful coverage, but not literal every-screen coverage; continue using cheap navigation checks for assembly risk and full journeys for mutations.

## Ninth tranche — 24 August 2026

Four commits (`f199589`, `6739201`, `2785041`, `d9146f6`) closed the next iPhone Settings slice: Arr notification-webhook management, notification configuration and history, and qBittorrent/SABnzbd server edits. Five UI journeys drive the public app against deterministic loopback services; seven manager tests exercise real Arr clients and exact webhook requests.

### Notification reliability

- **Arr webhook manager:** matching webhooks are reused rather than duplicated; creation and update preserve Sonarr/Radarr event flags and tag filters; test requests use the production endpoint; 401 and 500 failures retain their public error categories. Request method, path, authentication and JSON bodies are asserted at the fixture socket.
- **Notification Settings:** a DEBUG-only launch hook seeds only an APNs token, not final screen state. The journey opens the real Settings hierarchy, loads an existing Sonarr webhook and tag, changes an event toggle, removes the tag, saves through the real manager, and verifies an exact authenticated PUT with no duplicate POST.
- **Visible failure:** a real notification-list HTTP 500 is shown to the user and leaves the configuration flow open; it cannot silently dismiss as success or send a mutation.
- **Recent Notifications:** removing a Jellyfin library through the real UI produces the in-app notification. The Notifications screen then verifies Clear → Cancel preserves history and Clear → Confirm reaches `No Notifications Yet`.

### Download-client setup and edit reliability

- **qBittorrent:** the journey opens the active server editor, verifies prefilled values, changes host and credentials, observes a rejected real login without dismissal, retries successfully, verifies the form-encoded login plus version request, and confirms the replacement host persists after dismissal.
- **SABnzbd:** the corresponding journey verifies prefill, exact `mode=auth` validation with API key parameters, visible 401 handling without dismissal, successful retry through auth/version/queue/history, and persisted replacement host.
- The setup journeys hardened real accessibility behavior discovered during validation: direction-aware form scrolling handles restored scroll positions, lazy fields are searched through the scroll container, and secure fields receive explicit focus before typing.

### Validation

| Check | Result |
|---|---:|
| Four new coverage stacks together | **Passed:** **12 executions**, 0 failed, 0 skipped |
| Full `Trawl.xctestplan` | **Passed:** **643 executions**, 0 failed, 0 skipped |
| Zero/incomplete-result guard | Both result bundles accepted by `Scripts/assert-test-results.py` |
| `Trawl`, `TrawlMac`, `TrawlShare`, `TrawlWidgets` | **All build** |

Authoritative results: `/tmp/trawl-notification-setup-integrated.xcresult` for the twelve-test gate and `/tmp/trawl-full-plan-notification-settings.xcresult` for the complete plan.

### Still uncovered, stated plainly

- **Remaining setup/edit journeys:** Jellyfin, Seerr and the Arr-family forms still benefit from the same validation-failure, successful persistence and reconnect coverage now protecting qBittorrent and SABnzbd.
- **Remaining high-value destructive/admin flows:** indexer/application/proxy/tag management, Bazarr profile/provider actions, Jellyfin user/password/policy changes, and queue/blocklist/wanted confirmations should be selected by mutation risk rather than screen count.
- **Search/detail action breadth** remains uneven where the view itself wires commands or confirmations that lower-level contract tests cannot observe.
- **TrawlMac UI remains deferred at the maintainer's request.** Its product still passes the compile gate and shares the tested state/request layers.
- **Widget and ShareViewController installed-process shells remain parked** by agreement; pure decision logic, target membership and product compilation are covered.
- The suite now contains approximately 40 UI test functions. It is a strong regression net, not a literal every-screen proof; future work should keep pairing cheap assembly smoke checks with full socket-asserted journeys for state-changing actions.

## Tenth tranche — 26 August 2026

Six commits (`109c43f`, `62f1ac3`, `2676fa1`, `2edf29a`, `f442f53`, `5a90128`) closed the core content-acquisition stream and the last two service families without setup/edit coverage. Two streams ran in parallel — acquisition in the main worktree, Jellyfin/Seerr setup/edit in an isolated worktree — with simulator builds serialized on one device throughout.

### Release acquisition through the real UI

- **Sonarr and Radarr release search:** `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` drives automatic command routing, interactive-search query parameters, release rendering, the exact grab bodies and visible success feedback against loopback fixtures. **2 executed, 0 failed, 0 skipped.**
- **Adding a brand-new Radarr movie from Search:** `TrawlUITests/RadarrSearchAddJourneyUITests.swift` covers success, duplicate suppression and server-failure behavior, closing the last open item on that coverage-map row. **1 executed, 0 failed, 0 skipped.**

### Jellyfin and Seerr setup/edit

- `TrawlUITests/JellyfinSeerrSetupEditJourneyUITests.swift` and its 435-line fixture server verify prefill, a rejected authentication whose exact user-visible error appears without dismissing the editor, a corrected retry, the exact production method/path/headers/body at the fixture socket, persistence of the replacement host, and the service manager reconnecting to the replacement rather than the old server. **2 executed, 0 failed, 0 skipped.**
- Every service family except the Arr forms now has this shape: qBittorrent and SABnzbd (ninth tranche), Jellyfin and Seerr (here).

### Negative controls, including one that did not prove what it looked like

- **Radarr add-new:** removing the production post-add `loadMovies()` refresh did *not* fail the journey, because the detail screen's completion callback independently refreshes Search's library state. That control was discarded rather than counted: it shows the journey survives that internal refactor, but it did not exercise the network seam. Breaking the production add endpoint instead failed the journey exactly at sheet dismissal, and the restored build returned green.
- **Seerr setup/edit:** reverting the detent fix below failed the journey exactly at the Sign In tap.

### A real defect the Seerr journey caught

Both Seerr editor presentations declared `detents: [.medium, .large]` and opened at medium. At that height the form is too short to scroll while **Sign In** sits below the bottom of an iPhone 17 Pro screen — `isEnabled == true`, `isHittable == false`, and unreachable by any swipe. A user adding or editing a Seerr server could not submit the form without knowing to drag the sheet up first. `5a90128` presents both at `.large`, matching the existing sheets whose primary action must always be on screen (`SABnzbdNewsServerEditorSheet`, the library import scan sheet). The journey guards it: it reaches Sign In with no expand step, and `tapInEditor` requires `isHittable` without scrolling, so restoring the medium detent fails the test.

### Validation

| Check | Result |
|---|---:|
| Release acquisition journeys | **Passed:** **2 executions**, 0 failed, 0 skipped |
| Radarr add-new journey | **Passed:** **1 execution**, 0 failed, 0 skipped |
| Jellyfin/Seerr setup-edit journeys | **Passed:** **2 executions**, 0 failed, 0 skipped |
| Integrated checkpoint (add-new + both setup/edit) | **Passed:** **3 executions**, 0 failed, 0 skipped |
| Seerr detent fix, focused re-run | **Passed:** **2 executions**, 0 failed, 0 skipped |

**The full `Trawl.xctestplan` has not been run since the ninth tranche.** These are focused-suite results only. A complete-plan checkpoint is owed before the next release gate.

### Still uncovered, stated plainly

- **Arr-family setup/edit forms are the last family without validation-failure coverage.** Sonarr, Radarr, Bazarr and Prowlarr connection forms have no journey proving a rejected key keeps the editor open with the exact production error and then persists a corrected retry. `ArrRepointJourneyUITests` covers the reconnect half for Sonarr's host only. This is the top open item.
- **Remaining destructive/admin flows:** indexer/application/proxy/tag management, Bazarr profile/provider actions, Jellyfin user/password/policy changes, and queue/blocklist/wanted confirmations, still to be selected by mutation risk rather than screen count.
- **M-03 remains partially fixed:** a deterministic qBittorrent 403 reauthentication contract still needs an injectable credential/reauthentication seam.
- **TrawlMac UI remains deferred** at the maintainer's request; **widget and `ShareViewController` installed-process shells remain parked** by agreement.

## Eleventh tranche — 26 August 2026

Two commits (`17f93d2`, `f93af96`) closed the top open item from the tenth tranche and repaid the full-plan debt it recorded.

### The full-plan checkpoint that was owed

The complete `Trawl.xctestplan` ran for the first time since the ninth tranche: **648 executions, 0 failed, 0 skipped**, accepted by `Scripts/assert-test-results.py`. That is the ninth tranche's 643 plus the five journeys added on 26 August, and it validates the Seerr detent fix alongside everything else already landed.

### Arr setup/edit — the last family without validation-failure coverage

`TrawlUITests/ArrSetupEditJourneyUITests.swift` drives the seeded Sonarr profile's real editor against a second loopback server that accepts exactly one key: a wrong key shows the exact production `ArrError.invalidAPIKey` description with the editor still open, server B sees that exact key at the socket, and server A is left untouched — a failed validation must not repoint anything, which the ordering inside `validateAndSave` (the connection test precedes every write) is what actually guarantees. The corrected key then dismisses, persists the host visibly, and reconnects the manager to B.

One Sonarr journey covers all four Arr services: they share `ArrSetupSheet` and `validateAndSave`, and the service type only selects which client `testConnection` builds, below the failure handling under test.

`SonarrFixtureServer` gained an optional `acceptedAPIKey:` that answers a mismatched `X-Api-Key` with a real 401. It defaults to nil, so the five existing consumers are unaffected.

**Negative control:** breaking the production dismissal guard so a failed save dismisses anyway failed the journey at the error-visibility assertion; the restored build returned green.

### A flake that blamed the product, and a harness trap worth remembering

`ArrInstanceSwitchJourneyUITests` failed once during the integrated run and passed in isolation 21 seconds later. The failure was `Failed to tap Button: Timed out while synthesizing event` after 167 seconds — the *tap* failing, not an assertion, because a toolbar menu and its popover items exist in the tree before they can accept an event. Left alone this reads as a product hang. The four menu taps now wait for hittability first. `ArrRepointJourneyUITests` also still carried debug prints from an earlier session; they are gone.

This is the third distinct way this suite has manufactured a misleading failure — after the swallowed taps of the sixth tranche and the below-the-fold controls of the tenth. The pattern is constant: **an element that exists is not an element that can be used**, and every new journey should assume it.

### Validation

| Check | Result |
|---|---:|
| Full `Trawl.xctestplan` | **Passed:** **648 executions**, 0 failed, 0 skipped |
| New Arr setup/edit journey | **Passed:** **1 execution**, 0 failed, 0 skipped |
| Every suite sharing `SonarrFixtureServer` | **Passed:** **8 executions**, 0 failed, 0 skipped |
| Zero/incomplete-result guard | All bundles accepted by `Scripts/assert-test-results.py` |

### Still uncovered, stated plainly

- **Remaining destructive/admin flows** are now the top open item: indexer/application/proxy/tag management, Bazarr profile/provider actions, Jellyfin user/password/policy changes, and queue/blocklist/wanted confirmations, selected by mutation risk rather than screen count.
- **M-03 remains partially fixed:** a deterministic qBittorrent 403 reauthentication contract still needs an injectable credential/reauthentication seam.
- **The Arr *add-new-service* path is still uncovered.** Every setup journey in the suite, across all six services, starts from a seeded profile and edits it, because the pre-seed welcome gate is unreachable from a UI test driving the UI alone. First-run onboarding remains covered only at the view-model level.
- **TrawlMac UI remains deferred**; **widget and `ShareViewController` installed-process shells remain parked** by agreement.

## Executive verdict

Building a real safety net now is a good idea. Trawl's current tests are useful, but they are not broad enough to make iteration safe.

The iOS scheme is green: the full run completed 133 logical tests / 205 concrete parameterized executions with no failures or skips. However, only **2.66% of `Trawl.app` production lines** executed. The three UI-test methods are Xcode templates: they launch, measure launch, or take a screenshot without asserting application behavior. Meanwhile, a `TrawlMac` Debug build from fresh DerivedData fails to compile.

The core problem is not the raw number of tests. The current suite is concentrated in model decoding, formatting, equality, and small helper behavior. It does not exercise the failure-prone boundaries where Trawl talks to services, switches profiles, refreshes concurrently, stores credentials, uploads files, polls, or reacts to stale responses.

This audit found:

- one directly reproduced build blocker;
- several high-confidence stale-client and out-of-order-response defects;
- important HTTP, extension, and multipart failure paths with no coverage;
- no CI, test plan, all-target build gate, or meaningful UI regression suite.

The recommended approach is not to inflate coverage with trivial tests. First add deterministic contract tests at the network boundary and state-machine tests around managers, then a small set of end-to-end user journeys backed by a local fixture server. Coverage should be a guardrail, not the definition of quality.

## What was actually run

| Check | Result | Evidence |
|---|---:|---|
| `Trawl` scheme, iPhone 17 Pro / iOS 26.4.1, full `test`, code coverage enabled | **Passed** | 133 logical tests, 205 concrete executions, 0 failed, 0 skipped |
| `TrawlTests` unit bundle rerun during the WIP | **Passed** | 130 logical tests, 201 concrete executions, 0 failed, 0 skipped; discovery occurred before Claude's new cache-test file was picked up |
| Focused run requested for Claude's newly added cache suite | **Inconclusive** | Xcode/CoreSimulator spent eight minutes unable to materialize/launch its cloned test worker (`NSMachErrorDomain -308`); no test case started, so the run was interrupted and is not counted as pass/fail |
| `Trawl.app` production coverage | **2.66%** | Approximately 3,890 / 146,220 instrumented lines in the current unit run |
| `TrawlMac` Debug build, generic macOS | **Failed** | [`SearchView.swift:62`](Trawl/Views/SearchView.swift#L62) uses an iOS-only search placement |
| Share and widget compilation | **Passed as dependencies** | Both extension products were built by the iOS scheme; neither has a behavioral test bundle |
| Release configuration | **Not separately run** | Debug already exposes the macOS blocker; add Release to CI |

The original full result bundle is `/tmp/trawl-audit-tests-20260822.xcresult`. The latest unit-only result bundle is `/tmp/trawl-audit-current-unit-20260822.xcresult`. These are local audit artifacts, not repository files.

The working tree changed during the audit. The user confirmed that Claude was concurrently implementing the uncommitted `ArrLibraryCache` work and adding its tests. Findings that concern those files are explicitly marked as WIP-specific and should be handed back to that owner rather than edited in parallel. The product files were not changed by this audit.

## Current test-suite quality

### What is already valuable

The existing 130 Swift Testing declarations across 21 suites are not fake. Several use realistic payloads and assert production behavior:

- [`SABnzbdTests.swift`](TrawlTests/SABnzbdTests.swift) covers realistic mixed-shape queue/history responses, normalized statuses, API error messages, and completion transitions.
- [`TMDbCreditsModelTests.swift`](TrawlTests/TMDbCreditsModelTests.swift) covers full, missing, and null fields in realistic credits/person responses.
- [`ArrStackTests.swift`](TrawlTests/ArrStackTests.swift) covers Arr error presentation, filesystem/query construction, queue/release behavior, Codable payloads, and parsing.
- [`ArrIntentSupportTests.swift`](TrawlTests/ArrIntentSupportTests.swift) covers quality/root-folder selection and entity identifier behavior.
- [`CleanuparrTests.swift`](TrawlTests/CleanuparrTests.swift) covers documented stats decoding and base-path normalization.

These tests should stay. They are simply a narrow slice of the product.

### What gives false confidence

- [`TrawlUITests.testExample()`](TrawlUITests/TrawlUITests.swift#L25) only launches the app and has no assertion.
- [`TrawlUITests.testLaunchPerformance()`](TrawlUITests/TrawlUITests.swift#L36) only measures launch.
- [`TrawlUITestsLaunchTests.testLaunch()`](TrawlUITests/TrawlUITestsLaunchTests.swift#L20) only saves a screenshot.
- There are no `URLProtocol` tests, mock transport tests, loopback fixture-server tests, or request recorders.
- No test verifies HTTP method, path, query, authorization header, form body, multipart body, retry policy, or status mapping for a production API client.
- No behavioral tests cover qBittorrent, Jellyfin, Seerr, Keychain/Auth, SyncService, onboarding, search, settings, torrent-list state, widgets, the share extension, or macOS.
- There is no `.xctestplan`, CI workflow, Fastlane/test script, or shared test action for `TrawlMac`, `TrawlShare`, or `TrawlWidgets`.

The hosted unit bundle launches enough production code that some lines execute incidentally. A covered line therefore does not necessarily have a meaningful assertion behind it.

## Coverage map

Representative production-file coverage from the full audit run:

| Production area | Line coverage | Interpretation |
|---|---:|---|
| `KeychainHelper.swift` | 0% | Credential save/read/delete behavior is unverified |
| `OnboardingViewModel.swift` | 0% | Connection validation and persistence rollback are unverified |
| `SearchViewModel.swift` | 0% | Search, library reconciliation, cancellation, and profile changes are unverified |
| `TorrentListViewModel.swift` | 0% | Filtering, optimistic actions, and stale work are unverified |
| `SABnzbdAPIClient.swift` | 0% | No request/auth/status/upload contract coverage |
| `QBittorrentAPIClient.swift` | 1.78% | Essentially no endpoint or retry coverage |
| `SyncService.swift` | 3.79% | Polling/delta behavior is not meaningfully asserted |
| `HTTPTransport.swift` | 4.64% | Shared status, decoding, upload, and error behavior is not tested |
| `SeerrServiceManager.swift` | 4.70% | Mostly incidental initialization |
| `ShareViewController.swift` | 0% in the app target | No extension input/error behavior is asserted |

Model/formatter files have much higher coverage. That explains why the suite can contain many passing executions while leaving service and workflow behavior exposed.

## Verified and high-confidence findings

Severity means user/release impact, not how difficult the fix is. Each finding includes the regression test that should exist before or alongside the fix.

### B-01 — `TrawlMac` does not compile

**Evidence:** [`SearchView.swift:59-64`](Trawl/Views/SearchView.swift#L59) always supplies `.navigationBarDrawer(displayMode: .always)` to `.searchable`. That placement is explicitly unavailable on macOS. `xcodebuild -scheme TrawlMac -destination 'generic/platform=macOS' build` exited 65 at line 62.

**Impact:** the macOS product cannot be built from the audited branch.

**Authentic regression test/gate:** build `TrawlMac` on every pull request. Add a small macOS launch test that opens the main window and verifies the search field is accessible. A source-level test of an `#if` flag would not be sufficient; the target itself must compile.

### H-01 — Editing/reconnecting a Sonarr or Radarr profile can leave screens using the old server client

**Evidence:**

- [`SonarrSeriesListView.swift:47-57`](Trawl/ArrStack/SonarrSeriesListView.swift#L47) and [`RadarrMovieListView.swift:58-71`](Trawl/ArrStack/RadarrMovieListView.swift#L58) recreate their view models only when the active profile ID or connected boolean changes.
- [`ArrServiceManager.swift:661-669`](Trawl/ArrStack/ArrServiceManager.swift#L661) and [`ArrServiceManager.swift:701-709`](Trawl/ArrStack/ArrServiceManager.swift#L701) replace the manager's client while retaining the same profile ID.
- [`ArrSetupViewModel.swift:209-215`](Trawl/ArrStack/ArrSetupViewModel.swift#L209) reconnects an edited profile without disconnecting it when its service type is unchanged.
- [`SonarrViewModel.swift:26-33`](Trawl/ArrStack/SonarrViewModel.swift#L26) and [`RadarrViewModel.swift:17-24`](Trawl/ArrStack/RadarrViewModel.swift#L17) capture a concrete client at initialization.

On a successful same-ID reconnect, both the ID and `isConnected` remain unchanged, so the existing view model continues to own the old client.

**Impact:** refresh, monitor toggles, deletes, details, and searches can continue calling the previous host/API key after the user saved a replacement.

**Authentic regression test:** inject a client factory with two request-recording clients. Connect profile ID X to server A, edit the same ID to server B, then refresh and perform a mutation. Assert that A receives no post-edit requests and B receives every request. Exercise the real manager/view-model handoff; do not merely test that a string revision changes.

### H-02 — A failed Arr reconnect leaves a stale client exposed while the service says disconnected

**Evidence:** [`ArrServiceManager.setError`](Trawl/ArrStack/ArrServiceManager.swift#L1410) sets `isConnected = false` but does not clear the Sonarr/Radarr client. [`sonarrClient` and `radarrClient`](Trawl/ArrStack/ArrServiceManager.swift#L509) return the client regardless of connection state, and active-entry fallback can return a disconnected entry at [`ArrServiceManager.swift:142-154`](Trawl/ArrStack/ArrServiceManager.swift#L142).

**Impact:** a detail view, calendar refresh, cache loader, or other retained caller can keep issuing requests to the old endpoint after a failed credential/host edit.

**Authentic regression test:** connect A, attempt a same-ID reconnect to B that fails, then invoke every manager-level read/mutation entry point that uses the active client. Assert the stale client is unavailable and no request reaches A after failure.

### H-03 — qBittorrent sync responses can apply out of order and move `rid` backwards

**Evidence:** [`SyncService.startPolling`](Trawl/Services/SyncService.swift#L143) and [`SyncService.refreshNow`](Trawl/Services/SyncService.swift#L172) can overlap. Each reads the current `rid`, awaits the network, applies its delta, then unconditionally assigns the returned `rid`. Main-actor isolation does not serialize across `await`; an older request can resume last.

**Impact:** torrent/category state can regress, deleted items can reappear, deltas can replay, and completion notifications can be emitted more than once.

**Authentic regression test:** use controlled continuations in a fake `TorrentService` or a request-barrier fixture server. Start polling and refresh together, return `rid=20` first and stale `rid=15` second, and assert final state reflects only 20 and a completion is announced once. Also cancel a delayed polling request and prove it cannot apply after `stopPolling()`.

### H-04 — Calendar refreshes can duplicate events or mix two active profiles

**Evidence:** [`ArrCalendarViewModel.refresh`](Trawl/ArrStack/ArrCalendarView.swift#L63) has no serialization/generation guard, clears shared state, and merges asynchronous month results. [`mergeMonth`](Trawl/ArrStack/ArrCalendarView.swift#L252) deduplicates the month identifier but always appends its events. [`fetchMonthData`](Trawl/ArrStack/ArrCalendarView.swift#L154) captures clients for an in-flight request with no check that the active profile is still the same when results return.

**Impact:** initial load plus pull-to-refresh can duplicate releases; switching Sonarr/Radarr during a refresh can show releases from the previous server.

**Authentic regression test:** with delayed clients, overlap two refreshes and assert each event appears once. Then begin profile-A refresh, switch to B before A returns, and assert the final calendar contains only B's events.

### H-05 — SABnzbd unauthorized refresh keeps the invalid client and polling loop alive

**Evidence:** [`SABnzbdServiceManager.refresh`](Trawl/SABnzbdStack/SABnzbdServiceManager.swift#L100) handles unauthorized by setting `isConnected = false` but leaves `activeClient` intact. [`startPolling`](Trawl/SABnzbdStack/SABnzbdServiceManager.swift#L169) continues its loop, and mutations such as [`pauseAll`](Trawl/SABnzbdStack/SABnzbdServiceManager.swift#L188) and [`addURL`](Trawl/SABnzbdStack/SABnzbdServiceManager.swift#L372) guard only the client, not connection state.

**Impact:** after an API key is revoked, Trawl presents a disconnected state but continues periodic unauthorized traffic and can still send user actions through the invalid client.

**Authentic regression test:** return a controlled 401 from refresh, advance an injected clock past the next polling interval, and assert only one request occurred, polling stopped, the client was cleared, and a mutation produces no network request.

### H-06 — A slow SABnzbd response can overwrite a newly selected profile

**Evidence:** [`connectService`](Trawl/SABnzbdStack/SABnzbdServiceManager.swift#L45) and [`refresh`](Trawl/SABnzbdStack/SABnzbdServiceManager.swift#L100) assign shared queue/history state after awaits without a profile generation or client-identity check. A new connection's call to `refresh()` also returns immediately if an old refresh still owns `isRefreshing`.

**Impact:** switching servers can leave the UI displaying the old server's queue/history under the new profile.

**Authentic regression test:** delay A's refresh, connect B and return B's initial data, then release A. Assert active ID, queue, history, and completion events remain exclusively B's.

### H-07 (Claude-owned WIP) — same-ID profile changes do not invalidate the new shared Arr library cache

**Evidence at the captured WIP snapshot:** the uncommitted [`ArrLibraryCache.swift`](Trawl/ArrStack/ArrLibraryCache.swift) keys data by profile UUID. The captured `connectService` path replaces a client's host/API key for the same UUID but does not invalidate that UUID's library. A recent sequence guard correctly prevents an older forced request from overwriting a newer one, but an appear-time load can still return an already-fresh library from the old server. Recheck this handoff item against Claude's final diff before acting on it.

**Impact:** after repointing an existing profile, Series, Movies, Search, or Seerr navigation can show server A's cached library while requests are now configured for server B.

**Authentic regression test:** cache A under profile ID X, reconnect X to B, then execute the normal appear-time load. Assert B is fetched and displayed. Use a controllable clock and request barriers. The new WIP tests cover cache freshness, forced refetch, isolation, and one stale-response ordering case; they do not yet cover manager-driven same-ID repointing.

## Medium-priority findings

### M-01 — foreground retry skips disconnected secondary Arr instances

[`ArrServiceManager.retryDisconnected`](Trawl/ArrStack/ArrServiceManager.swift#L617) makes a service-type-wide decision from the active instance's `isConnected`/`isConnecting` state, then either skips or reconnects every profile of that type. With one connected Sonarr and another failed Sonarr, the failed profile can be skipped indefinitely.

**Regression test:** configure two same-type profiles with independent state, keep one connected and one failed, call retry, and assert only the failed profile reconnects.

### M-02 — Add Movie/Series App Intents fail open when duplicate detection cannot load the library

[`AddRadarrMovieIntent.swift:66-70`](Trawl/ArrStack/AppIntents/AddRadarrMovieIntent.swift#L66) and [`AddSonarrSeriesIntent.swift:70-74`](Trawl/ArrStack/AppIntents/AddSonarrSeriesIntent.swift#L70) turn a failed library request into `[]` with `try?`. If later profile/root-folder/add calls recover, the intent proceeds despite not knowing whether the item exists.

**Regression test:** make only the duplicate-check GET fail while later calls would succeed. Assert the intent reports the read failure and never sends an add mutation.

### M-03 — qBittorrent reads do not validate non-403 HTTP status codes

[`QBittorrentAPIClient.performRequest`](Trawl/Services/QBittorrentAPIClient.swift#L489) special-cases 403 but returns every other status as if transport succeeded. `getAppVersion()` converts any UTF-8 response body to a version string, so a proxy's 500 text page can pass onboarding connection validation at [`OnboardingViewModel.swift:130`](Trawl/ViewModels/OnboardingViewModel.swift#L130). JSON endpoints turn 401/404/500 into misleading decode failures.

**Regression test:** use `URLProtocol` to return 401, 404, 429, and 500 for both a text endpoint and a JSON endpoint. Assert status-specific errors, verify the single 403 reauthentication path, and verify a failed retry status is also rejected.

### M-04 — share-extension provider failures can leave the sheet open indefinitely

[`ShareViewController.swift:76-112`](Trawl/Share/ShareViewController.swift#L76) returns without closing when a provider advertises NZB/torrent data but returns an error or non-URL item. The plain-text path at lines 116-125 similarly does nothing for non-magnet text.

**Regression test:** pass providers that call back with an error, `Data`, and invalid text. Assert the extension context completes exactly once and temporary state is cleared.

### M-05 — canceled torrent-filter work can overwrite a newer query

[`TorrentListViewModel.scheduleFilterUpdate`](Trawl/ViewModels/TorrentListViewModel.swift#L208) cancels the previous detached task, but the synchronous computation never observes cancellation. It then creates a separate main-actor task that applies the result without checking a generation or current inputs. The compiler also warns about the inconsistent `self` capture at line 218.

**Regression test:** inject a computation gate, start query A then B, complete B before A, and assert B's results/counts remain. Avoid timing sleeps; explicitly control task release.

### M-06 — two multipart builders interpolate unsanitized filenames into headers

[`HTTPTransport.postMultipartVoid`](Trawl/Services/HTTP/HTTPTransport.swift#L356) and [`Data.appendMultipart`](Trawl/Services/HTTP/Data+Multipart.swift#L3) place field names and filenames directly into `Content-Disposition`. The adjacent generic multipart implementation already sanitizes these values, confirming inconsistent behavior. User-selected backup/torrent filenames can contain quotes or newline characters.

**Regression test:** capture the real outgoing body for `backup\"\r\nX-Test: injected.zip`; assert raw CR/LF and quotes cannot create a second header and the server parses exactly one file part.

## Lower-priority but real gaps

- [`HTTPTransport.validate`](Trawl/Services/HTTP/HTTPTransport.swift#L222) accepts all 3xx statuses as success. `URLSession` follows ordinary redirects, but a final 304 or redirect without a usable location is then decoded as a success body. Add request-level 3xx tests and make the intended policy explicit.
- Several icon-only controls lack user-facing accessibility labels, including clear search in [`TrawlSegmentBar.swift`](Trawl/Views/Components/TrawlSegmentBar.swift#L210), manual path submit in [`RemotePathBrowserView.swift`](Trawl/Views/RemotePathBrowserView.swift#L122), and close controls in [`ArrCalendarView.swift`](Trawl/ArrStack/ArrCalendarView.swift#L425) and [`ArrWantedView.swift`](Trawl/ArrStack/ArrWantedView.swift#L233). UI tests should query the intended spoken labels, not SF Symbol names.
- Swift 6.2 emits many isolation/sendability warnings through `HTTPTransport`, `ArrAPIClient`, Jellyfin, Seerr, and widget clients. The current build still succeeds, so these are warning debt rather than proven races, but they obscure new warnings and increase future compiler-migration risk.
- The build warns that document opening is supported without declaring `LSSupportsOpeningDocumentsInPlace` or `UISupportsDocumentBrowser`. Confirm intended file-import semantics and make the Info.plist declaration explicit.

## A suspected issue that was deliberately not reported as a defect

`KeychainHelper` tries to derive an explicit group from an `AppIdentifierPrefix` Info.plist key that is absent from the built products, so its query currently omits `kSecAttrAccessGroup`. This initially looked like broken app/extension sharing.

The built simulated entitlements were then inspected. `Trawl`, `TrawlShare`, and `TrawlWidgets` all have `L9DB7QA9DE.com.poole.james.Trawl.shared` as their first keychain access group. Apple's Security documentation states that `SecItemAdd` defaults an omitted group to the app's first keychain group, while unscoped reads search all allowed groups. Therefore the omission does **not** establish an iOS sharing defect in this build.

Credential sharing is still important enough to deserve one installed-app/extension smoke test, but the audit does not count it as a current bug. This is the standard the rest of the report follows: plausible concerns were excluded unless the code, build, documentation, or a reproducible path supported them.

## The test system Trawl needs

### 1. Network contract tests that run production request code

Use an injected `URLSession` with a recording `URLProtocol` for fast tests. Do not mock each API method's return value and then assert the mock was called. Run the actual request builder, auth layer, serializer, status validator, decoder, and error mapper.

For every supported service, cover at least:

- exact method, base path, endpoint path, query encoding, headers, and body;
- successful documented response;
- missing/optional/mixed-shape fields from redacted real payloads;
- 401/403, 404, 409, 429, and representative 5xx responses;
- retry/re-authentication count and the failure of the retry itself;
- malformed/empty/HTML response bodies;
- cancellation and timeout;
- form and multipart payload parsing at the receiving side.

The fake is the remote server, not Trawl's own logic. These tests are deterministic and high signal.

### 2. Manager and concurrency tests with controlled ordering

Introduce narrow client protocols/factories plus an injectable clock where polling is involved. Use actors as request recorders and checked continuations/barriers to release responses in an exact order.

Priority state machines:

- Arr profile add/edit/remove/reconnect, including multiple instances of one type;
- same-ID server repoint and cache invalidation;
- qBittorrent full sync, deltas, tombstones, refresh/poll overlap, cancellation, and completion deduplication;
- SABnzbd connect, unauthorized, profile switch, polling, history transitions, and mutations;
- calendar refresh/profile switch overlap;
- search/filter cancellation and stale-result suppression;
- onboarding persistence + Keychain rollback when any save step fails.

No concurrency test should rely on `Task.sleep(50ms)` to manufacture an order. If ordering matters, the test should own the barrier.

### 3. Persistence and cross-process integration tests

- Use an in-memory `ModelContainer` to test actual SwiftData profiles and rollback behavior.
- Give tests a unique Keychain service/account namespace and clean only that namespace.
- Add one installed simulator/device test that saves through the app and reads through a tiny extension-side probe, proving the signed entitlements and real Keychain behavior agree.
- Verify App Group data used by widgets/share is readable after app termination and handles missing/corrupt data.

### 4. A small, meaningful UI journey suite

Run the app against a deterministic loopback fixture server through launch arguments/environment. Use real navigation, view models, persistence, and HTTP requests. Seed only external state and test namespace data.

The first UI journeys should be:

1. first launch, failed qBittorrent login, successful login, torrent list appears;
2. pause/resume/delete a torrent and verify both UI state and the recorded server mutation;
3. add and then edit a Sonarr/Radarr profile with the same ID; confirm the new server is used;
4. switch between two Arr instances; confirm library/calendar/search belong to the selected instance;
5. search and add a movie/series, including duplicate and service-failure paths;
6. SABnzbd unauthorized transition stops polling and disables actions;
7. share a magnet, torrent, NZB, and invalid provider item; every path presents or dismisses correctly;
8. widget configured, unauthorized, empty, and populated states using actual App Group/Keychain plumbing;
9. macOS app launches and search is usable.

Every UI test must assert a user-visible result or recorded external side effect. A launch or screenshot by itself is a smoke artifact, not regression coverage.

### 5. Optional real-service contract lab

Fixture tests belong on every pull request because they are deterministic. A scheduled integration job can additionally exercise disposable, known-version instances of qBittorrent, Sonarr, Radarr, SABnzbd, Jellyfin, and Seerr when infrastructure is available. It should use isolated data and never depend on a developer's personal servers.

This catches upstream API drift without making ordinary pull requests flaky or credential-dependent.

## CI and gating recommendation

### Required on every pull request

- build `Trawl` Debug and Release for an iOS simulator;
- build `TrawlMac` Debug and Release;
- build `TrawlShare` and `TrawlWidgets` explicitly;
- run unit, network-contract, manager/state, and persistence tests on the documented iPhone 17 Pro simulator;
- run the short critical UI journey test plan;
- publish the `.xcresult` and coverage report;
- fail on a test skip unless it is explicitly allow-listed with an owner/reason;
- fail when changed non-UI production logic has no exercised branch or when critical-module coverage regresses;
- after the existing Swift concurrency warnings are cleaned up, treat new warnings as failures.

### Scheduled/nightly

- repeat concurrency/order tests many times under randomized response order;
- run the broader UI/accessibility matrix;
- run Release and archive/signing validation;
- run the disposable real-service contract lab;
- test network loss, timeouts, 401/403, rate limiting, malformed data, and slow responses across services.

### Coverage policy

Do not set “80% of the whole SwiftUI app” as the first goal. It encourages low-value view-construction tests.

Use these rules instead:

1. no decrease from the measured baseline;
2. regression test required for every confirmed bug;
3. changed-line coverage floor for testable non-View logic;
4. explicit scenario matrices for HTTP, auth, persistence, and concurrency code;
5. raise per-module thresholds only after meaningful suites exist.

For `HTTPTransport`, API clients, service managers, SyncService, cache logic, and onboarding persistence, a later 75–85% line/branch floor is reasonable only after the required success and failure scenarios are enumerated. Passing the scenario matrix matters more than the percentage.

## Rules for tests that are worth keeping

A test belongs in the suite when it does at least one of the following:

- reproduces a user-visible bug and fails before the fix;
- verifies an external contract Trawl does not control;
- verifies a state transition, persisted side effect, or outgoing mutation;
- verifies ordering/cancellation under controlled concurrency;
- protects a meaningful parsing edge from a real or documented payload.

Avoid tests that only restate enum raw values, instantiate a view without observing behavior, assert a stub returns its own configured value, sleep and hope for a race, or tap through UI without checking the result.

## Cost-effective delegation to DeepSeek-V4-Flash

**Recommendation: yes, with a bounded producer/reviewer workflow. Do not hand it the repository plus the instruction “add full coverage.”**

As of this audit, DeepSeek publishes V4-Flash at **$0.14 per million cache-miss input tokens, $0.0028 per million cache-hit input tokens, and $0.28 per million output tokens**. It supports tool calls and a 1M-token context window. At those rates it is economically well suited to repetitive test expansion. See the [official model and pricing page](https://api-docs.deepseek.com/quick_start/pricing/) and [V4 announcement](https://deepseek.com/en/news/v4-preview/).

The large context window is not a reason to send the entire repository on every task. Smaller slices reduce attention errors, prevent unrelated edits, improve cache reuse, and make review possible.

### Good work for V4-Flash

| Task | Delegate? | Conditions |
|---|---:|---|
| Expand endpoint contract cases from an approved `URLProtocol` example | Yes | Exact endpoint matrix and assertion template supplied |
| Turn redacted real responses into fixture/decoder tests | Yes | Fixtures reviewed for secrets and expected semantics specified |
| Add 401/403/404/429/5xx cases across similar clients | Yes | Must exercise production transport and assert request + resulting error |
| Add form/multipart request-body cases | Yes | A receiving-side parser or exact body assertions are provided |
| Inventory uncovered methods and map them to tests | Yes | Output is reviewed; inventory alone is not coverage |
| Pure formatter/parser boundary expansion | Yes | External/user contract is clear |
| Design dependency-injection architecture | No | Use GPT/Claude/senior review first |
| Decide concurrency semantics or fix H-01–H-07 | Assist only | More capable model owns design and reviews every diff |
| Cross-process Keychain, widget, share-extension harness | Assist only | Signing/entitlement semantics require senior ownership |
| Broad SwiftUI journey design | Assist only | Give it one predesigned journey at a time |
| Unsupervised product fixes while “making tests pass” | No | This is the easiest way to codify or hide a bug |

The efficient pattern is for GPT/Claude to create one **golden example** for each test shape—HTTP contract, manager race, persistence transaction, and UI fixture-server journey. V4-Flash can then expand that pattern across a precise list of endpoints/scenarios. GPT/Claude reviews the risky tests and all production-code changes.

### Mandatory handoff packet for each task

Give V4-Flash one audit ID or one endpoint family per task, with:

1. the exact production files it may read;
2. the exact test files it may create/edit;
3. the user-visible or external contract being protected;
4. request/response fixtures and the expected method/path/query/headers/body;
5. required success, auth, status, malformed-data, and cancellation cases;
6. the approved test seam and a golden example to copy;
7. the exact targeted `xcodebuild` command;
8. forbidden shortcuts;
9. required evidence in its handoff.

Forbidden shortcuts should explicitly include:

- no `Task.sleep` for correctness or ordering;
- no skipped/disabled tests;
- no weakening/deleting an existing assertion;
- no test-only reimplementation of production algorithms;
- no bypassing production request builders/managers by directly installing final state;
- no product behavior change unless the task explicitly authorizes it;
- no editing outside the allow-list;
- no claiming success without showing the test command and result.

Require the returned handoff to contain: changed files, test names, commands/results, coverage delta for the touched production files, assumptions, and any behavior it could not prove.

### Authenticity gate for generated tests

For a known bug, the new regression test must fail against the buggy revision before the fix. Preserve that red result in the task notes or CI artifact.

For behavior that is already correct, perform a mutation check in a disposable worktree: temporarily break the protected production behavior, confirm the new test fails for the intended reason, then discard the mutation. Sample at least every high-risk generated test and a rotating portion of repetitive endpoint tests. A green test that survives the relevant mutation does not protect the behavior and should not be merged.

Every V4-Flash batch should pass these gates before merge:

1. focused tests pass from a clean build;
2. full test plan passes;
3. no sleeps, skips, or unexpected product edits;
4. request/state assertions prove an observable contract;
5. mutation/red-before-green evidence exists;
6. GPT/Claude reviews concurrency, persistence, extensions, and all product changes.

Use separate branches/worktrees and non-overlapping file ownership for parallel agents. Stop and escalate a slice after two unsuccessful correction loops; repeated prompting can cost little in tokens but still produces expensive review noise.

### Cost controls

- Keep a stable, repeated instruction prefix so DeepSeek's automatic context cache can help.
- Send only the relevant production slice, golden test, audit entry, and fixtures.
- Cap output to what one reviewable diff needs; the model's maximum output is far larger than desirable for a test ticket.
- Batch structurally identical endpoints, but keep stateful/concurrent scenarios separate.
- Track accepted tests per dollar and reviewer minutes per accepted test. Reviewer time, not API cost, will be the binding constraint.

### Source-code/privacy caveat

Before uploading a private repository, confirm that DeepSeek's data terms are acceptable for this project and remove credentials, server URLs, logs, personal media metadata, signing material, and proprietary third-party payloads. DeepSeek's current [privacy policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html) says prompts and uploaded files may be collected and that personal data is processed/stored on servers in the People's Republic of China. A local agent harness does not make an external model call local; repository context sent to the API is still handled by that provider.

If that is not acceptable, use a locally hosted model or keep private-code tasks with an approved provider. Redacted, narrowly scoped fixtures and source slices reduce exposure but do not replace an acceptable data-processing policy.

### Example V4-Flash ticket

```text
Task: M-03 only — qBittorrent HTTP status contract tests.

Allowed production files to read:
- Trawl/Services/QBittorrentAPIClient.swift
- Trawl/Services/AuthService.swift

Allowed edits:
- TrawlTests/QBittorrentAPIClientContractTests.swift
- a minimal session-injection seam only if the existing API cannot use URLProtocol

Use the approved HTTP contract test as the pattern. Exercise the production request,
authorization, retry, response validation, and decoder. Cover 401, 403 then success,
403 then 500, 404, 429, and 500 for text and JSON endpoints. Assert request counts,
method/path/headers, and the exact public error category.

Do not change product behavior, use sleeps, skip tests, or mock the method under test.
Run the focused xcodebuild command and return changed files, results, coverage delta,
and assumptions. Demonstrate that at least one test fails on the current buggy status
handling before proposing a production fix.
```

This division should save substantial GPT/Claude usage without outsourcing the decisions most likely to create convincing-but-empty tests.

## Recommended order of work

1. Add an all-target CI build gate and fix B-01. This immediately prevents another silently broken product target.
2. Add client/session/clock seams without changing behavior.
3. Write the H-01 through H-07 regression tests, watch them fail on current code, then fix each issue.
4. Build the shared HTTP contract suite and qBittorrent status/auth tests.
5. Add SABnzbd, calendar, search/filter, persistence, extension, and multipart state tests.
6. Replace the template UI tests with the first five critical journeys; add the remaining journeys incrementally.
7. Add changed-line/per-module coverage gates after the signal-bearing suites are established.

The first milestone should not be “coverage went up.” It should be: all products build, the identified races and stale-client paths have deterministic regression tests, service failures are contract-tested, and the core user journeys fail in CI when their behavior breaks.

## Audit limitations

- No personal/live service credentials were used, and no mutations were sent to real servers.
- Physical-device-only behavior such as APNs delivery, biometric prompts, and production signing was not exercised.
- The macOS compile failure and simulator test results were executed; code-path findings are evidence-backed review findings whose proposed regression tests should be used to prove and fix them.
- Performance, memory, energy, localization, and a complete VoiceOver pass were outside this reliability-focused audit.
- Because the working tree changed during the audit, rerun the full matrix from a clean, frozen revision before release.
