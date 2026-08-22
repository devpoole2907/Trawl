# Trawl reliability and test audit

**Audit date:** 22 August 2026  
**Repository snapshot:** `rework/downloads-navigation-experience` at `a5f29d9`, plus the uncommitted working tree present during the audit  
**Scope:** iOS app, macOS app, share extension, widgets, test architecture, build configuration, network boundaries, service state, concurrency, persistence boundaries, and representative SwiftUI accessibility

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
