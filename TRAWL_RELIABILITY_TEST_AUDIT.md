# Trawl reliability and test audit — current state

**Last updated:** 28 August 2026
**Branch:** `rework/downloads-navigation-experience`
**Posture:** approaching release-candidate. **Not App Store submit-ready** — see
[Remaining release gates](#remaining-release-gates).

This document is deliberately short. It records **what is true now** and **what is still
open**. The full historical narrative — the original 22 August audit, eleven
implementation tranches, and every defect write-up — is frozen in
[`TRAWL_RELIABILITY_AUDIT_ARCHIVE.md`](TRAWL_RELIABILITY_AUDIT_ARCHIVE.md).

Read this file first. Go to the archive only when you need the evidence behind a specific
finding. **Do not treat the archive as current** — it describes conditions that were fixed
days later.

Companion documents:
- [`TRAWL_TEST_COVERAGE_MAP.md`](TRAWL_TEST_COVERAGE_MAP.md) — which suites to read and run before changing a production surface. Consult it before editing behaviour.
- [`TRAWL_WIDGETS_AUDIT.md`](TRAWL_WIDGETS_AUDIT.md) — the widget surface, its defects and its roadmap.

---

## Current state

| Check | Result |
|---|---:|
| Complete `Trawl.xctestplan` | **701 passed, 0 failed, 0 skipped** (653 Swift Testing across 79 suites + 49 XCTest/UI) |
| Generic iOS Simulator build (Trawl) | **Passed** |
| Generic macOS build (TrawlMac) | **Passed** |
| `git diff --check` | **Passed** |

Counts come from the result bundle via `Scripts/assert-test-results.py`, never from an
`xcodebuild` exit code. The previous complete checkpoint was 658.

Coverage at the last full measurement: overall app 37.36%; AuthService 88.52%,
HTTPTransport 81.21%, Seerr API 78.9%, Onboarding 75.3%, Arr manager 71.74%,
SAB manager 68.22%, Jellyfin API 58.91%, Arr setup 53.17%, Arr API 49.51%,
Sync 42.94%, qB client 32.44%.

---

## Open items

Everything still outstanding. Nothing else in this repository is a tracked open defect.

| ID | Item | Status |
|---|---|---|
| **M-03** | qBittorrent non-403 status validation is only **partially** fixed. Status rejection for 401/404/429/500 is covered, but a deterministic 403 reauthentication contract still needs an injectable credential/reauthentication seam. | Open, partial |
| **N-06** (Arr) | The Arr services configuration screen was never wired up. Multi-instance configuration is **deferred from 1.0, not rejected** — see [Product direction](#product-direction-multi-instance-arr). | Deferred, post-1.0 |
| **W-01** | Both download widgets aggregate qBittorrent **and** SABnzbd, but `SelectServerIntent` is titled "qBittorrent Server" and enumerates only `ServerProfile`. A SAB-only user is shown a picker that lists nothing. | Open |
| **W-02** | `upSpeed`, `dlLimit` and `upLimit` are read from qBittorrent alone while download speed blends both clients. A SAB-only user sees a live download figure beside a permanent `↑ 0 B/s`. | Open — fix before release |
| **W-05** | The Seerr widget decoding tests are hand-authored JSON that has never met a live payload; the test Seerr instance reports `"initialized": false`. They pass, but may pin a shape Seerr does not emit. | Open |
| — | SABnzbd returns `kbpersec` as a **string**; the in-repo sample uses a number. Production is safe via `lossyDouble`, but no fixture would catch a regression to a plain `Double` decode, which would silently zero the download widgets. | Open, not a defect |
| — | `BazarrAPIClient.resetProviders` is unpinned. It is **not** a configuration wipe: the UI labels it "Reset Provider Status" and enabled-provider configuration saves separately through `saveEnabledProviders`. Do not test or document it as deleting provider configuration without captured live proof. | Standing caveat |

### Closed on 28 August 2026

- **W-03** — SABnzbd per-job speed is synthesised (one global rate credited to the first downloading slot). Deliberate; documented, accepted.
- **W-04** — widget content unreachable from XCTest. Resolved as test design; see [Standing constraints](#standing-constraints).
- **W-06** — Calendar widget shapes validated against a live Sonarr and Radarr. See [Live validation](#live-validation).
- **Widget UI cleanup** — `WidgetInstalledProcessUITests` records the pre-test Trawl-widget count and removes only widgets added by that run in async teardown. If setup fails before the count is captured, teardown preserves everything. This closes the unbounded Home Screen state growth that likely triggered the simulator's PosterBoard crash-loop.

---

## Original findings — disposition

The 22 August audit raised these. All detail is in the archive.

| Finding | Disposition |
|---|---|
| B-01 `TrawlMac` did not compile | Fixed |
| H-01 same-ID Arr repoint left screens on the old client | Fixed |
| H-02 failed Arr reconnect left a stale client exposed | Fixed |
| H-03 out-of-order qB sync / polling after stop | Fixed |
| H-04 calendar refresh duplication and profile mixing | Fixed |
| H-05 SAB unauthorized polling / client lifecycle | Fixed |
| H-06 slow SAB response overwriting a new profile | Fixed |
| H-07 Arr same-ID cache repoint | Fixed |
| M-01 retry skipping failed secondary Arr instances | Fixed |
| M-02 Add Movie/Series intents failing open | Fixed |
| M-03 qB non-403 status validation | **Partially fixed — still open** |
| M-04 share-extension provider failure paths | Fixed |
| M-05 canceled torrent filter overwriting a newer query | Fixed |
| M-06 multipart header injection | Fixed |
| N-01 repointing an Arr profile left the library empty | Fixed |
| N-02 opening the SABnzbd queue crashed the app | Fixed, and the class closed at the root |
| N-03 a rejected SAB key silently emptied Downloads | Fixed |
| N-04 SAB add-only key gave the wrong explanation | Fixed |
| N-05 (two defects share this ID) Jellyfin cached availability failures forever; and a cancelled attempt showed a raw Swift error | Both fixed |
| N-06 (two defects share this ID) the Jellyfin setup form leaked the previous server; and the Arr services screen was never wired up | First fixed; second **deferred post-1.0** |

⚠️ **The N-05 and N-06 identifiers were each reused for two unrelated defects.** When
citing an N-series finding, quote its title, never the bare number.

---

## Product direction: multi-instance Arr

Multi-instance Sonarr/Radarr configuration is **deferred from 1.0, not rejected**.

The intended setup is HD + 4K Sonarr and HD + 4K Radarr presented as **one blended
logical library**. Server identity is provenance and optional filtering plus command
routing — it must not create four separate primary library surfaces. The eventual work is
therefore larger than wiring up the dead settings view: setup must make a second instance
discoverable, and Series/Movies must merge and de-duplicate across instances while
preserving enough identity to route commands back to the correct server.

For 1.0: **preserve the existing multi-instance manager/profile architecture and its
switching/routing tests**, but do not advertise multi-instance setup as a complete user
feature. Do not delete or collapse that architecture merely because the configuration
entry point is deferred. N-06 is not an App Store blocker under this scope.

---

## Live validation

Validated read-only against the disposable `trawl-test` stack. **No credentials, keys or
host addresses belong in this repository** — keep it that way.

| Surface | Result |
|---|---|
| qBittorrent v5 login | `204`, empty body, port-suffixed `QBT_SID_<port>` cookie |
| qBittorrent `transfer/info` | `dl_info_speed`, `up_info_speed`, `dl_rate_limit`, `up_rate_limit` — exactly what the Speed widget reads |
| SABnzbd two-tier keys | Reads succeed with either key; a control op with the add-only key returns `403 API Key Incorrect` |
| Arr health (all four instances) | 3 checks each, `type` `error`/`warning`, mapping correctly through `healthSeverity` |
| Arr queue | Paged envelope; the widget's `queue.records` access is correct |
| Sonarr calendar | `airDateUtc` without fractional seconds, `airDate` day-only, `series.title`, `series.images[coverType=poster]`, `hasFile` — every field the widget reads. Requires `includeSeries=true`, which the widget passes |
| Radarr calendar | `inCinemas` / `digitalRelease` / `physicalRelease` (nullable), `title`, `year`, `hasFile`, `images[coverType=poster].remoteUrl`. One movie correctly yields one event per populated release date |
| `parseISO` / `parseDayDate` | Live Arr timestamps carry **no** fractional seconds; the non-fractional fallback is what actually parses them |
| `series/lookup` | Carries **no** `id` — confirmed again |

Calendar validation required adding one movie and one series with search disabled; both
were deleted afterwards and both instances verified back to zero.

**Still unvalidated:** Seerr widget decoding (W-05) — that instance was never
initialised, so it holds no requests or issues.

---

## Standing constraints

Hard-won rules. Violating these has cost real sessions.

**Evidence**
- A green `xcodebuild` exit code is not evidence. `-only-testing` with a wrong suite name runs **zero** tests and still reports success. Always verify counts with `Scripts/assert-test-results.py`; zero executed is a failure.
- Swift Testing reports separately from XCTest. `Executed 0 tests` in the XCTest summary is normal for a swift-testing-only run.
- `xcodebuild` **hangs after `TEST FAILED`**. Read the log for the result, then kill it. Never chain a command after it.
- Never grep `-quiet` output for "error" — successful builds print `error: ... exit code 0`.
- A hang is not evidence. A negative control that hung proves nothing and must be rerun.
- Pass `-derivedDataPath` when Xcode is open, or builds fail with "database is locked".

**Test design**
- No timing sleeps, no skipped tests, no method-mock tautologies, no direct installation of final UI state. Exercise production request/state paths with deterministic fixtures or explicit barriers.
- Fixtures written by reading Trawl's own code reproduce the API generation Trawl already assumed, and pass while being wrong. Capture real shapes — see `TrawlTests/LiveCapturedShapeContractTests.swift`.
- Compare parsed JSON, not `JSONEncoder` bytes; key order is not stable.
- In XCUITest, a tap on an element that exists but is not yet hittable is silently dropped and the failure surfaces against an unrelated element later. Wait for hittability before every tap.
- Widget content is rendered by `com.apple.chrono.WidgetRenderer`, a separate process XCTest cannot read into. Assert only on SpringBoard-owned attributes; the installed widget is an icon carrying `value: Widget`, which the app icon does not have.

**Architecture**
- A view model owns the request, the resulting state and the error. The **presenting view** owns the user-facing feedback. Both announcing produces duplicate banners.
- Endpoints that take a whole collection generally **replace** rather than merge. When adding one, assume no merge until proven otherwise, and pin the untouched members rather than the edited one.
- Features must degrade gracefully when an integrated service is not configured.

**Process**
- Only one writer may edit `Trawl.xcodeproj/project.pbxproj` at a time.
- New Swift files are auto-compiled by every target via synchronized folders unless listed in that target's `membershipExceptions`. Forgetting this breaks TrawlShare/TrawlWidgets with "cannot find type in scope".
- SourceKit "cannot find type in scope" diagnostics are indexing noise. Validate with a real `xcodebuild` run.

---

## Remaining release gates

Not submit-ready until all of these pass.

1. Refreshed complete `Trawl.xctestplan` run after any further change.
2. All-target **Debug and Release** builds for Trawl, TrawlMac, TrawlShare and TrawlWidgets. Release has not been separately run.
3. Signed archive / distribution validation.
4. Physical-device smoke: first-run onboarding, one real service connection, the Share extension, **all widget families and refresh behaviour**, deep links, notifications.
5. App Store metadata and privacy review.
6. W-02 fixed, or an explicit decision to ship a SAB-only install showing a permanent zero upload figure.
