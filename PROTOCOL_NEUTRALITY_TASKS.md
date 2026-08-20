# Protocol Neutrality — Task List

**Created:** 2026-08-20 · **Branch:** `rework/downloads-navigation-experience`

The goal: torrent and Usenet are both just *downloads*. The user should never have to
know which server owns the next step. SABnzbd was added late, so it is integrated
unevenly — this list is the remaining unevenness, ranked.

Sizes are S / M / L. Paths are relative to `Trawl/`.

---

## Already landed (do not redo)

- [x] Torrents tab → Downloads; Arr queue + history merged in
- [x] SABnzbd client: service manager, API client, setup, settings, manager view
- [x] Downloads rows actionable — pause/resume/recheck/retry/remove, **Blocklist & Remove**, **Blocklist & Search Again**
- [x] Untappable Issues rows fixed
- [x] Seeding / Issues / History dedup; nondeterministic dict-order dedup replaced
- [x] Arr queue cache consolidated onto `ArrServiceManager`, one timer, 5s foreground / 60s background
- [x] Add Download sheet: magnet / .torrent / **NZB** / URL with per-destination options
- [x] SABnzbd live state linked into movie/series detail; `ArrQueueItem.quality` decoded
- [x] Accessory `Activity | Actions` — six fan-out global verbs
- [x] Accessory failure tier — "N downloads need attention", shares its rule with the Issues segment
- [x] `RecentNotificationsSheet` moved out of `MoreView.swift` (4785 → 4131 lines)
- [x] **`TrawlSegmentBar` now scrolls the selected item into view** — `Views/Components/TrawlSegmentBar.swift`.
  The bar is a horizontal `ScrollView` and nothing ever scrolled the selection on screen, so a
  selected segment past the trailing edge was invisible. Affected all 28 usages; worst on
  Downloads (5 segments) and at large Dynamic Type. Found by rendering the Add Download sheet
  at AX 2, where the selected "URL" segment was entirely off-screen.
  *This was also silently undermining P1.9 — `trawl://downloads/issues` selects the last of five segments.*

---

## P0 — Usenet parity blockers

These are the ones where a Usenet-only user hits a wall.

- [ ] **P0.1 — Cannot add SABnzbd as a Sonarr/Radarr download client** · M
  `ArrStack/ArrAddDownloadClientSheet.swift:67,94,104,254`
  Hardcoded to qBittorrent: `implementation ?? "QBittorrent"`, title "Add qBittorrent",
  schema lookup `first { $0.implementation == "QBittorrent" }`, error "qBittorrent is not available".
  `ArrDownloadClientListView.swift:182-184` already sections Torrent/Usenet/Other and can
  enable/disable/edit an existing SAB client — so the fix is contained to the sheet:
  generalise schema selection and the profile picker.
  *Blocks the core Usenet setup path. Everything else in P0 is downstream of this.*

- [ ] **P0.2 — No NZB ingestion from outside the app** · M
  `Share/ShareViewController.swift:27-68` handles magnet / `.torrent` / magnet-as-text only.
  `Views/ContentView.swift:193-232` handles `magnet:` and `trawl://` only.
  Getting an NZB in from Safari or Files is impossible; magnets work fine.
  *Asymmetric on the most common entry gesture.*

- [x] **P0.3 — More → Integrations → Download Clients is qBittorrent-only** · S
  `Views/MoreView.swift:2112, 2295-2343` (`targets: [.qbittorrent]` on both rows),
  `:114` (`MoreDestinationAccent.downloadClients` hardcoded to qBit brand colour).
  Empty state reads "Connect Sonarr or Radarr…" with the qBit glyph.
  **Done — identity only.** Accent is now `.mint`, glyph `shippingbox.fill`, subtitles read
  "Torrent and Usenet clients used by Sonarr and Radarr".
  **`targets: [.qbittorrent]` was deliberately left alone:** `IntegrationRelationshipRow.serviceFlow`
  (`MoreView.swift:2806-2828`) renders it as a literal source→target icon flow, so adding `.sabnzbd`
  would draw an icon promising a path `ArrAddDownloadClientSheet` still hardcodes to qBittorrent.
  **Once P0.1 lands, add `.sabnzbd` to both rows — it's a one-line follow-up.**

---

## P1 — Structural

- [ ] **P1.1 — Two different screens both called "Download Clients"** · M
  `Views/MoreView.swift:2343` (Arr's clients — cannot add SAB) vs
  `DownloadsStack/DownloadClientManagementView.swift:87` (Trawl's own clients — *can* add SAB, `:64-76`).
  No cross-link. The one that works is buried in the Downloads tab.
  *Users will find the wrong one. Needs a naming and routing decision, not just a rename.*

- [ ] **P1.2 — "Torrents" hub is protocol-shaped and permanently empty for SAB-only users** · M
  `Views/MoreView.swift:2971-3016` — `navigationTitle("Torrents")` at `:3016`,
  gated on `hasQBittorrent` at `:2972`; children are Transfer Stats / Categories & Tags / RSS.
  Search index mirrors it at `:1634-1673` (category "Torrents", keywords `["qbittorrent", …]`).
  None of the three children have a SAB analogue, so this needs re-shaping, not renaming.
  *A SABnzbd-only user sees a top-level row that leads to "qBittorrent Not Set Up".*

- [x] **P1.3 — Prowlarr manual release search — DEFERRED BY DESIGN, do not delete** · decided 2026-08-20
  `ArrStack/ProwlarrViewModel.swift:359` (`performSearch()`), `:401` (`clearSearch()`), `:55` (`searchResults`) — zero call sites.
  Reachable only via `AppIntents/SearchProwlarrIntent.swift:33`, which bypasses the view model.
  **Decision: keep it unsurfaced.** It is held for a possible future manual-search screen, not
  abandoned. Code comments have been added at each site saying so.
  *Do not build UI for it, and do not let a dead-code sweep remove it.*

- [x] **P1.4 — Cannot add a second client from Download Clients** · S
  `DownloadsStack/DownloadClientManagementView.swift:49`
  "Add qBittorrent" / "Add SABnzbd" render only when that client list is **empty**.
  *No route to a second qBittorrent server or second SABnzbd from this screen at all.*

- [x] **P1.5 — SABnzbd single-instance — WON'T DO, this is intended** · decided 2026-08-20
  `SABnzbdStack/SABnzbdServiceManager.swift:33` (`profiles.first`),
  `SABnzbdSettingsView.swift:11, 43-47` (one Edit/Add row).
  **Decision: SABnzbd stays single-instance.** The divergence from qBittorrent/Sonarr/Radarr is
  deliberate, not an oversight. Do not add multi-instance scaffolding for SABnzbd anywhere,
  and do not "fix" the `profiles.first` call as if it were a bug.

- [ ] **P1.6 — No protocol filter anywhere** · M
  `Views/SearchView.swift:960-980` (`SearchScope` = library/arr; `SearchResultFilter` = all/series/movies),
  `SonarrSeriesSearchViews.swift`, `RadarrMovieSearchViews.swift`,
  `DownloadsStack/DownloadSection.swift:3-9`.
  `ArrRelease.protocolName` is shown as a chip (`ArrReleaseActionContent.swift:107,408`) but is never
  filterable or sortable. `ArrQueueItem.protocol_` likewise (`:504`).
  Also: **"Seeding" is a torrent-only concept shown unconditionally**, including to SAB-only users.

- [ ] **P1.7 — No SABnzbd job detail view** · M
  `SABnzbdStack/SABnzbdManagerView.swift` has no `NavigationLink`; compare `Views/TorrentDetailView.swift`.
  Tapping a torrent opens a rich detail screen; tapping an NZB job does nothing.
  *Currently worked around with an inline panel in the Arr detail views.*

- [ ] **P1.8 — No SABnzbd widget coverage** · L
  `TrawlWidgets/ActiveTorrentsWidget/ActiveTorrentsWidget.swift:210-211` ("Active Torrents" / "Active qBittorrent downloads"),
  `SpeedWidget/SpeedWidget.swift:284-285` ("from qBittorrent"),
  `Shared/WidgetDataFetcher.swift:446-472` (builds only a `QBittorrentAPIClient`).
  *User-facing strings, and making them neutral needs a SAB fetch path in the widget target.*

- [x] **P1.9 — `DownloadsView.initialSection` is init-only, blocking two features** · S
  `DownloadsStack/DownloadsView.swift:17-19` — never called with an argument.
  Blocks: tapping an accessory failure landing on the **Issues** segment, and
  `trawl://downloads` deep-linking to a segment (the handoff spec asked for the latter).
  Needs observable state rather than an `.id()` re-init, which would wipe the tab's nav stack.

- [ ] **P1.10 — No App Intents for either download client** · M
  `ArrStack/AppIntents/` covers Arr + Prowlarr only. Neither qBittorrent nor SABnzbd is in Siri/Shortcuts.
  *Symmetric, so a coverage gap rather than a parity gap — but the intents layer is the natural
  home for reusable action implementations, which the accessory's fan-out verbs also want.*

---

## P2 — UI issues

- [x] **P2.1 — Pull-to-refresh leaks into the add-client sheet** · S
  `ArrStack/ArrDownloadClientListView.swift:146`
  `.refreshable` is applied *after* the three `.sheet` modifiers, so it wraps the sheet
  presentation. `RefreshAction` lives in the environment and sheets inherit their presenter's
  environment — so `ArrDownloadClientEditorSheet`'s form grows a pull-to-refresh it never asked for.
  **Fix is ordering, not deletion:** attach `.refreshable` directly to the `List` at `:88`, before `.sheet`.
  Then check the same pattern at `SeerrStack/SeerrSetupSheet.swift:223` and `JellyfinStack/JellyfinSetupSheet.swift:355`.

- [x] **P2.2 — Add Download sheet uses a segmented picker, not `TrawlSegmentBar`** · S
  `Views/AddTorrentSheet.swift:203` (`.pickerStyle(.segmented)`).
  `TrawlSegmentBar` is used in 28 files including `DownloadsView`, `SearchView`,
  `SABnzbdManagerView`, `TorrentListView`. Move it to the top of the sheet, matching those.
  Decide separately whether the other four `.pickerStyle(.segmented)` sites are deliberate
  in-form pickers or the same drift: `ArrSetupSheet.swift:105`,
  `ArrRemotePathMappingListView.swift:388`, `ArrRootFoldersView.swift:323`, `JellyfinSetupSheet.swift:72`.

- [x] **P2.3 — Prowlarr schema picker has no protocol filter** · S
  `ArrStack/ProwlarrAddIndexerSheet.swift:16-22, 53` — filters by name only.
  Adding a Usenet indexer means scrolling a flat list. Low effort, real friction.
  *Note: Prowlarr is otherwise already protocol-aware — see the correction at the bottom.*

- [ ] **P2.4 — SABnzbd settings screen is thin vs qBittorrent's** · M
  `SABnzbdStack/SABnzbdSettingsView.swift:15-105` vs `Views/SettingsView.swift:449-552`.
  Missing polling interval, speed limit, default path. **Scope carefully** — some of these
  have no SAB API method implemented at all (see the "not implemented" note below).

- [x] **P2.5 — `RecentNotificationsSheet` previews left behind in MoreView** · S
  The sheet moved to `Views/NotificationTabBarAccessory.swift` but its `#Preview`s stayed in
  `Views/MoreView.swift` (they use the file-private `MorePreviewFixtures`) without the service
  environments the moved sheet now requires. They compile but will trap when opened.

- [ ] **P2.6 — Arr history rows are read-only** · M
  No `markAsFailed` / `history/failed` / redownload plumbing exists anywhere in the repo, so
  "redownload from history" needs a genuinely new endpoint. The one remaining gap in the
  resolve story now that the queue rows are actionable.

---

- [ ] **P2.7 — `DirectIndexerSchemaPickerSheet` has the same flat-list problem** · S
  `ArrStack/ProwlarrIndexerListView.swift` — identical to P2.3 (schema picker with no protocol
  sectioning), missed because it lives in a different file. Apply the same fix: reuse
  `IndexerListSection` from `ProwlarrIndexerListHelpers.swift`.

- [x] **P2.8 — Eyeball the Add Download segment bar** · S
  `Views/AddTorrentSheet.swift` — `TrawlSegmentBar` is attached via `.safeAreaInset(edge: .top)`
  inside `AppSheetShell`. Spacing against the sheet's title bar has not been visually verified.

## P3 — Cleanup

- [x] **P3.1 — `.qbittorrentSettings` missing from `MoreSearchIndex`** · S
  `Views/MoreView.swift:1974-2042`. Every other service's settings page is searchable; this one isn't.

- [x] **P3.2 — "Dead" protocol helpers — KEEP, comment instead of delete** · decided 2026-08-20
  `ArrStack/ProwlarrModels.swift:110` (`ProwlarrIndexerProtocol.isTorrent`), `:335`, `:337`
  (`ProwlarrSearchResult.isTorrent` / `.isMagnet`) — zero call sites, but they are residue of
  P1.3, which is deferred by design rather than abandoned. Commented, not deleted.
  `SABnzbdStack/SABnzbdAPIClient.swift:43` (`getAuthentication`) — has a real call site in
  `SABnzbdSetupViewModel.swift:66`, so it was never dead.

- [x] **P3.3 — `queueIssueItems` / `queueIssueCount` have no reader** · S
  `ArrStack/ArrServiceManager.swift` — exposed during the cache consolidation but everything
  currently goes through the combined rule in `DownloadsViewModel.attentionItems(...)`.
  Either wire them or drop them.

- [ ] **P3.4 — Torrent-specific copy** · S
  `Views/TorrentListView.swift:65,78,88,513,553-574`, `Views/QBittorrentCategoriesAndTagsView.swift:99,139,193,222`,
  `Views/MoreView.swift:1659`.
  **Mostly correct as-is** — these sit under qBittorrent-scoped screens where "torrent" is the
  right word. Only revisit if P1.1 / P1.2 restructure moves them.

---

## Known broken — pre-existing, not from this work

- [ ] **TrawlMac does not compile** · S
  `JellyfinStack/JellyfinUserEditorView.swift:804,811,823,835` — `.pickerStyle(.wheel)` is iOS-only,
  unguarded. File is unmodified; last touched in commit `9682cd0`. Expect more iOS-only API in
  that target once these four are fixed — it clearly hasn't been built in a while.

- [ ] **Mac code signing** · needs your Apple Developer account, not a code change
  Provisioning profile "Mac Team Provisioning Profile: com.poole.james.Trawl" does not include
  the signing certificate "Apple Development: Greg Poole (Q6CRVA425J)".

---

## Corrections to prior assumptions

**Prowlarr already handles Usenet.** `ProwlarrIndexerProtocol` models usenet/torrent
(`ArrStack/ProwlarrModels.swift:99-101`); the indexer list sections into Torrent / Usenet / Other
(`ProwlarrIndexerListHelpers.swift:3-23`, applied at `ProwlarrIndexerListView.swift:211,655-663`)
and shows a protocol chip (`:446`). `ProwlarrAddIndexerSheet` is schema-driven and preserves
`protocol` on save (`:454`), so Newznab indexers can be added today. The only gap is the schema
picker's missing protocol facet — P2.3, an S.

**Remote path mappings are already protocol-neutral.** `ArrStack/ArrRemotePathMappingListView.swift`
is Arr-side and service-shaped, not protocol-shaped. No work needed.

**SABnzbd features that are not implemented at all** — no API method *and* no UI, so these are
build-from-scratch rather than surface-an-existing-call: servers config, scheduling, category
management, history retention, speed limit, job priority/reorder. `SABnzbdAPIClient` has 13 public
methods total. Add-time categories are scraped from existing jobs because SAB has no category
endpoint (`ViewModels/AddTorrentViewModel.swift:315-322` — deliberate, documented).

---

## Suggested order

1. **P0.1** — unblocks the Usenet setup path; everything else in P0 is downstream
2. **P0.3** then **P1.1** — settle what "Download Clients" means before adding more to it
3. **P0.2** — NZB in from Safari/Files
4. **P1.2** — reshape the Torrents hub once P1.1 has decided the structure
5. ~~small independent fixes~~ — done 2026-08-20 (P0.3, P1.4, P1.9, P2.1, P2.2, P2.3, P2.5, P3.1, P3.3)
6. **P1.6** — protocol filter, and decide what "Seeding" means for a Usenet-only user

**Decided and closed, not pending:** P1.3 (Prowlarr search stays hidden),
P1.5 (SABnzbd stays single-instance), P3.2 (helpers kept and commented), P3.4 (copy is fine as-is).
