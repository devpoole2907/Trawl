# Trawl production-to-test coverage map

Use this map before changing production behavior. It identifies the focused suites that should be read and run for each high-risk surface; it is not a replacement for the complete `Trawl.xctestplan` release gate.

## How to use this map

1. Find every production file or behavior touched by the change.
2. Read the mapped tests before editing so their protected contract is understood.
3. Run the focused suites while developing. If the changed behavior is not represented, add a regression test and update this map.
4. Run the complete test plan once at the final tranche/release checkpoint, not after every small edit.
5. Never remove or weaken a mapped assertion merely to make a behavior change green; explicitly update the contract and explain why.

## Arr library, add and release-search flows

| Production surface | Focused coverage to read/run | Current boundary |
|---|---|---|
| `Trawl/ArrStack/AppIntents/` — Siri/Shortcuts library checks, searches, adds, entities and registration | `TrawlTests/ArrIntentSupportTests.swift`; `TrawlTests/ArrAddIntentDuplicateCheckTests.swift` | Entity identifiers, pass-through library-title resolution, naturally spoken Radarr/Sonarr lookup titles, and safe add defaults are covered. The real intent execution path is covered against loopback Radarr/Sonarr servers for conversational availability answers, exact downloaded/monitored language, absence, failed reads, duplicate-check failures, and successful empty-library adds. App Shortcut discovery and Siri language routing remain physical-device release smoke-test work. |
| `Trawl/ArrStack/ArrReleaseActionContent.swift` | `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Request/response, stale-client routing, release rendering, selection, grab payload, success feedback, and dismissal are covered for Sonarr and Radarr. |
| `Trawl/ArrStack/SonarrSeriesSearchViews.swift` | `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlUITests/ArrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | New-series add plus existing-series Automatic Search and Interactive Search → Download Release are covered end to end. |
| `Trawl/ArrStack/RadarrMovieSearchViews.swift` | `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlUITests/RadarrJourneyUITests.swift`; `TrawlUITests/RadarrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Add-new movie plus existing-movie Automatic and Interactive acquisition are covered end to end. |
| `Trawl/ArrStack/SonarrSeriesDetailView.swift` | `TrawlUITests/SonarrConnectedJourneyUITests.swift`; `TrawlUITests/ArrRepointJourneyUITests.swift`; `TrawlUITests/ArrBlendedLibraryJourneyUITests.swift`; `TrawlUITests/ArrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Library, repoint, blended two-server library, add-new, automatic search, and interactive release acquisition assembly are covered. The blended-library journey replaced an instance-*switch* journey: the per-instance library picker was removed deliberately, so pinning it would have pinned the behaviour the merge exists to replace. N-01 (a recreated view model never asked to load) keeps its coverage through `ArrRepointJourneyUITests`, which reaches the same machinery by rotating `clientRevision`. |
| `Trawl/ArrStack/RadarrMovieDetailView.swift` | `TrawlUITests/RadarrJourneyUITests.swift`; `TrawlUITests/RadarrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift`; `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift` | Detail rendering, add-new transition, monitored mutation, automatic search, and interactive release acquisition are covered. |
| `Trawl/ArrStack/SonarrViewModel.swift`, `RadarrViewModel.swift`, `ArrLibraryViewModel.swift` | `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlTests/ArrLibraryCacheTests.swift`; `TrawlTests/ArrRepointLibraryReloadTests.swift`; `TrawlTests/ArrDualInstanceTests.swift` | Current-client resolution, cache invalidation and repoint behavior, plus blended-library loading across both instances. `loadLibraryItems` must load the union, not the active client — the routing suite's delete test caught it still reading one instance and is what keeps it honest. |
| `Trawl/ArrStack/ArrServiceManager.swift`, `ArrServiceManager+Instances.swift` | `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlTests/ArrRetryDisconnectedTests.swift`; `TrawlTests/ArrWebhookNotificationManagerTests.swift`; `TrawlTests/ArrDualInstanceTests.swift` | Multi-instance lifecycle, reconnect/retry and notification manager routing, plus the blended-library fan-out: the union of both servers' libraries, a partial library when one server is down, and the instance filter narrowing the library without disconnecting anything. |
| Arr/Bazarr user-facing missing-item terminology | `TrawlTests/ArrLibraryFilterNamingTests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift`; `TrawlUITests/BazarrSeriesDetailJourneyUITests.swift` | The combined destination is “Missing,” Radarr's narrower “wanted” state is “Released & Missing,” and Bazarr's internal wanted command is presented as “Search Missing Subtitles.” Raw API names remain internal. |
| `Trawl/ArrStack/ArrInstanceIdentity.swift`, `ArrLibraryEntry.swift`, `ArrLibraryMerging.swift`, `ArrInstanceFilter.swift` — the blended HD/4K library | `TrawlTests/ArrDualInstanceTests.swift` | Every failure in this family is silent rather than loud, because two *arr servers hand out the same small integer IDs for different titles. The load-bearing assertions: identity is `(server, library ID)` and not the ID alone — ID-only equality makes the HD copy of one film compare equal to the 4K copy of another, and the merged list then renders, selects and deletes the wrong rows; `instanceID` never appears in an encoded movie, because Radarr's update endpoint takes the whole object back and would be sent Trawl's own bookkeeping on every edit; merging is on TMDb/TVDb then IMDb then title **and year**, so a remake does not fuse into its original; and a delete of a merged row reaches *both* servers at *each server's own ID*, proven against two loopback servers that deliberately number the same film differently. The filter stores exclusions rather than inclusions so it fails open, and refuses to hide the last visible server — with no UI yet there would be nothing to undo it with. Badges come from the server's **declared** quality tier rather than from parsing its display name, so "Radarr (big box)" badges correctly; HD always sorts and colours before 4K whatever order the pair was added in. The two-instance cap is a consequence of there being two tiers, not a separate rule. Availability is folded into the row's server badges — filled means that server holds a file, hollow means the title is in its library with nothing downloaded — because a badge row saying "Default, 4K" beside a pill saying "Available Default & 4K" stated the same fact twice in the common case. The pill survives only where the badges cannot speak: a single-server setup, which has no badges, and a title downloaded nowhere, which still needs its status ("Announced", "In Cinemas"). The fill carries the state visually and the accessibility label carries it in words, since fill alone is invisible to some users. Its wording is a pill — "Available HD & 4K", "Available HD", "Available 4K", or plain "Available" on a single-server setup, where naming a tier would imply a library that does not exist — and its tiers are matched to copies **by instance, not by position**, because a filtered library hands back fewer refs than copies and zipping them labels a copy with the wrong server. An existing untiered pair is split HD/4K by profile age on launch, idempotently. |
| `Trawl/ArrStack/ArrInstanceFilter.swift` and the Movies/Shows title menu | `TrawlUITests/ArrBlendedLibraryJourneyUITests.swift` | The library is the union of both servers, and this menu narrows it — it does not choose an active one. That distinction is asserted rather than assumed, because a filter defaulting to a single server would be the old per-instance *switcher* wearing a new name: the menu must open on the union, narrowing must drop the other server's titles, the title must name the server while narrowed, and the union must be reachable again, since a user who narrows the library with no way to widen it is stuck looking at half of it. Servers are listed by the name the user typed, not by tier — this menu picks a box, and "Default" names a tier. The rebuild hangs off the menu's own action rather than off observing `instanceFilter`, because that state also settles during launch when it is loaded and pruned, and a rebuild triggered then runs before the servers have connected and blanks a list that had just loaded. Changing the filter drops cache freshness but keeps items, so the narrowed union is already in hand and the refetch behind it only restores freshness. The filter persists in `UserDefaults`, which no in-memory store resets and which the fixed UI-test profile UUIDs match on the next launch, so a narrowing test would otherwise leave every later launch of every other test hiding a server — `TrawlApp` clears it for UI-test launches. |
| `ArrLibraryViewModel.broadcast` — library-wide commands across a pair | `TrawlTests/ArrDualInstanceTests.swift` | "Refresh all", "check for new releases" and "search all missing" are claims about *the library*, and the library is the union of the pair — sending one to the active client alone does half the job and reports that it did all of it. Servers are tried independently, so one being down names it rather than abandoning the command on the other, and the confirmation names the servers actually reached instead of overclaiming. A total failure still throws, so the caller's error path fires. |
| `ArrAPIClient.deleteQueueItem` and `ArrLibraryViewModel.removeQueueItem` — queue removal and blocklisting | `TrawlTests/ArrAPIClientContractTests.swift` (Sonarr suite, "Queue deletion"); `TrawlTests/ArrQueueRemovalTests.swift` | The most destructive call in the app: both "delete the download from disk" and "blocklist this release forever" ride on query flags, so the exact `removeFromClient`/`blocklist` pairs are pinned per caller intent. Flipping either default fails these. The view-model half pins that the on-screen queue cannot lie: a rejected removal keeps the row and surfaces the error, and an accepted one drops only that item. Making the removal optimistic fails it. |
| `ArrAPIClient.getQualityProfileSchema` and `ArrQualityProfilesListView` — creating a quality profile | `TrawlTests/ArrAPIClientContractTests.swift` (Sonarr suite, "Quality profile schema"); `TrawlUITests/MoreSettingsBreadthUITests.swift` (Quality Profiles toolbar) | A profile's `items` have to mirror the qualities its own server knows about, so a blank one cannot be built client-side — it comes from the server, which is what Sonarr and Radarr's own Add button does. Before this the screen had no create path at all: its `plus` duplicated whichever profile sorted first and opened a sheet titled "Duplicate Profile" with "<name> Copy" prefilled, because the title was inferred from `apiID == nil` and so could not tell a new profile from a copy. The session now carries an explicit kind. Two things fail silently and are pinned: the path, which sits one suffix away from `/qualityprofile` — drop it and Add seeds from a real profile with no error — and the shape, which unlike every neighbouring endpoint is a single object with a nested `items` tree, so a decode that flattened it would strip every grouped quality out of the new profile. The schema is fetched from the *selected* server, since the two halves of an HD/4K pair need not share quality definitions. The admin journey also proves the toolbar retains New Profile but does not duplicate an arbitrary existing profile. |
| `SonarrAPIClient.deleteSeries` and `QBittorrentAPIClient.deleteTorrents` — the two calls that can erase media from disk | `TrawlTests/ArrAPIClientContractTests.swift` (Sonarr suite, "Series deletion"); `TrawlTests/QBittorrentAPIClientContractTests.swift` ("Torrent deletion") | `deleteFiles` decides whether files on disk go, and is always sent explicitly. Sonarr expresses `addImportListExclusion: false` by *omitting* it. qBittorrent joins hashes with a pipe — a comma sends one unrecognised hash, so nothing is deleted and the app still reports success. |
| `Trawl/ArrStack/ArrSetupSheet.swift`, `ArrSetupViewModel.swift` | `TrawlTests/ArrSetupViewModelTests.swift`; `TrawlUITests/ArrSetupEditJourneyUITests.swift`; `TrawlUITests/ArrAddInstanceJourneyUITests.swift`; `TrawlUITests/ArrRepointJourneyUITests.swift` | A rejected API key shows the exact production error, keeps the editor open and repoints nothing; the corrected retry persists and reconnects. One Sonarr journey covers the family — every Arr service presents this same editor and takes the same `validateAndSave` path. The **add** path is unit-covered separately, because it is different code from editing: it inserts rather than mutates, unwinds via `modelContext.rollback()` plus a Keychain delete rather than field restore, and adopts the existing profile for Prowlarr instead of inserting a second. Changing `unauthorizedStatusCodes`, the Prowlarr branch, or the add branch's `modelContext.insert` fails these tests by design. The sheet's service-type picker is unreachable from the app (N-06) and is deliberately uncovered. The add-instance journey starts with one Sonarr, adds the second into the only free 4K slot, proves the original survives, and proves the add entry disappears at the HD/4K cap. The same cap is enforced again in `validateAndSave` through one-server-per-tier conflicts so the limit holds however setup is reached; `ArrDualInstanceTests` pins the limits themselves. A cancelled attempt must report no error (N-05); `TrawlTests/UnansweringServer.swift` is the shared loopback server that keeps a request in flight while the task is cancelled. |
| `Components/ArrAddDestination.swift`, `RadarrMovieSearchViews.swift`, `SonarrSeriesSearchViews.swift` — choosing one or both add destinations | `TrawlTests/ArrDualInstanceTests.swift` (`ArrDualInstanceTests` and `ArrDualInstanceRoutingTests`); `TrawlUITests/ArrSearchAddJourneyUITests.swift`; `TrawlUITests/RadarrSearchAddJourneyUITests.swift` | Destination state, per-server profiles/folders, and partial-failure retry semantics are shared by Sonarr and Radarr. A library visibility filter is not an authorization boundary: add candidates come from every connected server, while cached provenance prevents offering a server already known to hold the title. An explicit destination fails closed if its client cannot be resolved; it never falls through to the active server. “Both Servers” dismisses only after every destination succeeds; a partial result stays open, names the failures, and retries only those servers. Feedback has one owner: the coordinator suppresses each low-level add banner and emits one aggregate success or failure, with the failure naming only destinations that need retrying. The dual-instance file contains two suites, so focused commands must select both suite names rather than only `ArrDualInstanceTests`. |
| `SonarrViewModel.loadEpisodes` / `loadEpisodeFiles` and the episode surfaces | `TrawlTests/ArrDualInstanceTests.swift` | Episodes belong to one server's copy of a series, and both servers number theirs from the same sequence. These fetched from the *active* client regardless of which copy the detail view was showing — so with the HD server down and 4K connected, 4K's episodes rendered under the HD series with no error — and cached the result under a bare series ID, where the second server's load silently replaced the first's. Both now take an `instanceID` and key on `ArrScopedID`. The season and episode screens were also pixel-identical with one server and with two — no badge, no name — so one server's "Downloaded" read as the episode's own; both now carry the owning server's badge. Merged episode rows remain deferred, and are recorded as such rather than missed. |
| `Trawl/ArrStack/ArrCalendarView.swift`, `Trawl/Views/TrawlPaneNavigationLink.swift` | `TrawlTests/ArrCalendarConcurrencyTests.swift`; `TrawlUITests/ArrBlendedLibraryJourneyUITests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift`; `TrawlUITests/IPadSurfaceCaptureUITests.swift` (`testCalendarAndMissingSelectionsUpdateTheDetailColumn`) | `IPadSurfaceCaptureUITests.testCalendarAndMissingSelectionsUpdateTheDetailColumn` covers two calendar selections through the real loopback calendar response, keeping the calendar visible beside the selected series. The row reads `hasDetailPane` below the pane container; reading it in the owning calendar view sees the ancestor default and incorrectly pushes. Overlap/profile ordering plus basic assembly. The series lookup is keyed by `ArrScopedID` — (server, library ID) — and built non-trapping: two servers both hand out a series 1, and a bare-`Int` key made `Dictionary(uniqueKeysWithValues:)` trap on the duplicate, killing the app during `initialize(from:)` before any screen rendered. Keying on the ID alone also resolved an episode against the wrong server's series. The blended-library journey seeds two servers that deliberately share library ID 1, which is what catches this from the UI side. `CalendarEvent.id` carries the owning server only when there is one, so an unstamped fixture keeps the plain `ep-101` form; with a pair configured the segment is what stops two servers' airings of the same episode collapsing into a single row. |
| `Trawl/ArrStack/AddImportLocationAndScanViewModel.swift` and import views | `TrawlTests/LibraryImportScanViewModelTests.swift`; `TrawlTests/ArrDualInstanceTests.swift`; `TrawlUITests/LibraryImportScanJourneyUITests.swift` | Scan/group/identify flow and no-premature-import boundary. Dual-instance routing drives a real scan against the selected 4K loopback server while proving the HD server receives no scan, and pins per-server root-folder isolation. |
| `Trawl/ArrStack/LibraryImportScanSessionStore.swift` — a folder's scan outliving one push of the scan view | `TrawlTests/LibraryImportScanViewModelTests.swift` ("Library import scan session store"); `TrawlUITests/LibraryImportScanJourneyUITests.swift` (`testAutoMatchResultsSurviveNavigatingAwayAndBack`) | The scan view held its view model in `@State`, so popping the view destroyed the grouped scan and every match Auto Match had earned; `.task`'s `hasPerformedInitialScan` guard then read false again and the folder was re-scanned and re-matched from scratch. The store keys on path + service + instance + library item + kind, and every component is pinned: an HD/4K pair can expose the same path with different libraries, and Library Import and Manual Import scan a folder under different server-side filtering, so a shared scan would show one server's or one flow's results under the other. The journey is the half that catches a regression here, because it asserts on the fixture's *request log* — returning to a scanned folder must issue no second `/api/v3/manualimport` and no second `/api/v3/series/lookup`, which a re-created view model cannot help doing. Retention is LRU-capped, so the unit suite also pins that eviction drops the least recently opened folder and that revisiting one refreshes its place. |
| `LibraryImportDisclosureHeader` — every collapsible section in the import screens | `TrawlUITests/LibraryImportScanJourneyUITests.swift` (`testOwnedTabRendersTheInLibraryTitlesItCounts`) | `Section(isExpanded:)` hides a section's content in this list style but draws no control to bring it back, so a section built on it was collapsed with no way to open it. The Owned tab shipped that way: "In Library (N)" counted titles the user could never see. Six sections across the scan view and the queue-resolution sheet used the dead binding; the blocked section alone had hand-rolled a working disclosure, and that is now the shared one. The test is deliberately not satisfied by the default being expanded — it collapses the section, asserts the rows go, re-expands, and asserts they come back, because a header that renders but does nothing is exactly the failure being fixed. |
| `Trawl/ArrStack/LibraryImportScanViews.swift` — Library Import's selection mode; `LibraryImportScanViewModel.selectionTag` / `selectionTags` / `applySelectionTags` | `TrawlTests/LibraryImportScanViewModelTests.swift` ("Library import scan selection"); `TrawlUITests/LibraryImportScanJourneyUITests.swift` (`testLibraryScanGroupsOwnedAndNewFilesThenReviewsTheSelection`) | Selection is `List(selection:)` plus edit mode, as in Downloads and the Series/Movies list, rather than a hand-drawn checkmark per row; the per-file and per-group `toggle…` methods the old rows called are gone. Rows are *groups* while the model tracks individual file IDs across the ready and blocked sets, so the List's selection values are `bucket|group-id` tags and the mapping lives on the view model, where it is testable without a view. Three things the suite pins, each a real way the mapping can lose a user's selection: a group ID is only unique within its bucket — the same series can be ready in one group and blocked in another, both carrying `id-7`, so tagging by group ID alone ticks both; the List has no partial state and writes a partly selected group's tag straight back, which must not promote a one-file selection into the whole group; and the write-back reconciles only the groups passed in — the ones on screen — so a selection hidden by the search field or moved between groups by auto-identification is left alone instead of silently dropped. Rows that cannot be imported (already-imported titles, the Season Folder toggle, section blurbs, the empty state) are `selectionDisabled` rather than tickable-then-ignored. |

| `Trawl/DownloadsStack/DownloadsListChrome.swift`, `DownloadListItem.batchTarget` — the Downloads tab's one toolbar and its mixed selection | `TrawlTests/DownloadsBatchSelectionTests.swift`; `TrawlUITests/DownloadsJourneyUITests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift` | The tab shows three lists — blended, SABnzbd, qBittorrent — through one toolbar, so each list publishes its capabilities into `DownloadsListChrome` rather than drawing buttons of its own. `reset()` is load-bearing: a value left behind by the previous list is a button acting on rows that are no longer on screen, which is why the test asserts every field and closure clears. `batchTarget` is the other half — a row in the blended list is a torrent, a SABnzbd job, an *arr queue row, or history, and only the first two name something a client can act on. An *arr row resolves to whichever download it is a *view of*, so pausing it pauses the real thing; an unlinked row and a history row resolve to nothing and are skipped and counted, because a batch that treated them as done would report more successes than it performed. Fixtures decode from real qBittorrent and SABnzbd payloads rather than being built field by field, so a model gaining a field cannot silently drift. Selection itself is `List`'s, not hand-drawn: the rows are `NavigationLink`s, which edit mode disables on its own, so there is no second tap handler to keep in step and no re-derived chrome to get wrong — the hand-rolled version applied its transparent row background to only one of its two branches, which over the services gradient rendered every selected-mode row as an opaque black block. `selectionDisabled` now refuses the rows `batchTarget` resolves to nothing for, so a history row cannot be ticked at all rather than being ticked and then silently dropped from the batch. |
| `DownloadsViewModel.activity(of:linkedTorrent:linkedSABJob:)` — which section a blended download row sits in | `TrawlTests/DownloadsBatchSelectionTests.swift` ("Downloads active/queue classification") | The blended list and the client-scoped lists have to agree about what a download is doing, and they didn't. A blended row backed by a download client was filed by the *arr's state, but `ArrQueueItem.normalizedState` is the *import* lifecycle — downloading, importPending, imported — and stays "downloading" while the client has the job paused. So one paused SABnzbd download read as Active in the blended list and Queue under the SABnzbd scope: the same download, filed by two different sources of truth depending only on which scope was on screen. The client wins whenever it has an opinion, because it is the only one that knows whether bytes are moving; when its state is terminal (seeding, completed, errored) the work left is the import, so the *arr decides. That fallback is not a nicety — it is what keeps the function total. The old code was a plain `isActive` / `!isActive` split, so every non-issue row landed in exactly one section, and a client-derived pair of predicates is not a complement. A test walks every status combination asserting a row is always in one section or the other, because losing that drops downloads off the tab entirely rather than misfiling them. |
| `ArrAddDestinationState.execute(targets:itemName:failureReason:operation:)` — what a failed add tells the user | `TrawlTests/ArrDualInstanceTests.swift` ("Arr dual instance"); `TrawlUITests/ArrSearchAddJourneyUITests.swift` | A 500 from Sonarr reached the add sheet as "Could not add to Sonarr", with the server's own words gone. The reason lives in `ArrLibraryViewModel.error`, which is *shared library state*: `loadLibraryItems` clears it, so any library reload racing the add wipes the message before the sheet renders. `execute` therefore reads the reason through `failureReason` at the point of failure and folds it into `failureMessage`, which belongs to the sheet and nothing else touches. The unit test pins that ordering by wiping the stand-in error immediately after the operation returns; the journey pins the whole path against a fixture that answers the add with a real 500. |

## Download clients and transport

| Production surface | Focused coverage to read/run |
|---|---|
| `Trawl/Services/HTTP/HTTPTransport.swift` | `TrawlTests/HTTPTransportContractTests.swift` |
| `Trawl/Services/QBittorrentAPIClient.swift`, `AuthService.swift` | `TrawlTests/QBittorrentAPIClientContractTests.swift`; `TrawlTests/QBittorrentReauthContractTests.swift` |
| `Trawl/Services/SyncService.swift` | `TrawlTests/SyncServiceConcurrencyTests.swift` |
| qBittorrent setup/edit and download actions | `TrawlUITests/ServiceSetupEditJourneyUITests.swift`; `TrawlUITests/DownloadsJourneyUITests.swift` |
| `Trawl/SABnzbdStack/SABnzbdAPIClient.swift` | `TrawlTests/SABnzbdAPIClientContractTests.swift` |
| `Trawl/SABnzbdStack/SABnzbdServiceManager.swift` | `TrawlTests/SABnzbdServiceManagerConcurrencyTests.swift`; `TrawlTests/SABnzbdProfileSwitchTests.swift` | Polling is requested by a view and performed by a connection, and those two do not arrive in that order. The Downloads tab asks from a `.task` that runs while the connection is still being established, so `startPolling()` must remember the request rather than no-op on a missing client — it used to no-op, and a cold launch straight into Downloads then never polled at all, freezing the queue for the whole session with nothing to retry it and no visible symptom. The distinction the tests pin is between *impossible* and *unwanted*: a rejected API key and a profile switch cancel the loop but keep the request, so reconnecting resumes it, while the view disappearing withdraws it so a later connection does not start polling for a screen nobody is looking at. H-05 is unaffected — no polling happens while there is no client. `SABnzbdUnauthorizedJourneyUITests` is the end-to-end witness: every assertion it makes past the unauthorized flip depends on the loop actually running, which is how the frozen queue was found at all. |
| SABnzbd setup/edit and unauthorized UI | `TrawlUITests/ServiceSetupEditJourneyUITests.swift`; `TrawlUITests/SABnzbdUnauthorizedJourneyUITests.swift` |
| `Trawl/ViewModels/TorrentListViewModel.swift` | `TrawlTests/TorrentListViewModelConcurrencyTests.swift` |

## Jellyfin, Seerr, Bazarr and Prowlarr

| Production surface | Focused coverage to read/run |
|---|---|
| `Trawl/JellyfinStack/JellyfinAPIClient.swift` | `TrawlTests/JellyfinContractTests.swift` |
| Jellyfin manager/setup/availability | `TrawlTests/JellyfinServiceManagerTests.swift`; `TrawlTests/JellyfinSetupViewModelTests.swift`; `TrawlTests/JellyfinAvailabilityResolverTests.swift` |
| Jellyfin and Seerr setup/edit sheets, their detents and primary-action reachability, validation, persistence and reconnect | `TrawlUITests/JellyfinSeerrSetupEditJourneyUITests.swift` |
| Jellyfin user administration — `JellyfinUserEditorViewModel`, `updateUserPolicy`, `deleteUser` | `TrawlTests/JellyfinUserPolicyTests.swift` |
| Jellyfin library administration | `TrawlUITests/JellyfinLibrariesJourneyUITests.swift`; `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| `Trawl/SeerrStack/SeerrJellyfinImportSheet.swift` — the Jellyfin -> Seerr user import picker | `TrawlUITests/SeerrJellyfinUserImportJourneyUITests.swift`; `TrawlTests/SeerrContractTests.swift` (Jellyfin account list and import payload) | The sheet picks accounts with `List(selection:)` and a pinned edit mode rather than a checkmark drawn per row, so the contract worth pinning is that ticked rows become exactly the right payload: the journey ticks two of three offered accounts and asserts the recorded POST body carries those two IDs and not the third — a picker that imported an untouched account, or dropped a ticked one, looks identical on screen. It was proven load-bearing by making the sheet import every listed account, which fails on that assertion. The second test is the cancel half: a sheet with a ticked row that is dismissed rather than confirmed must issue no import at all. `SeerrUIFixtureServer` buffers request bodies for this, since answering off the headers alone would record a POST whose payload arrived in a later TCP segment as an empty body — indistinguishable from the app sending nothing. The contract suite covers the load path the sheet's rows render from, including `SeerrJellyfinUser.displayName` falling back from username to email to the raw ID. |
| `Trawl/SeerrStack/SeerrAPIClient.swift`, linked Sonarr/Radarr editor, and Seerr view models | `TrawlTests/SeerrContractTests.swift`; the matching `TrawlTests/Seerr*ViewModelTests.swift` suites | Linked-application creation must send both the selected quality profile ID and its required name; omitting the name passes connection testing but Seerr rejects the save with HTTP 400. |
| `Trawl/ArrStack/BazarrViewModel.swift` | `TrawlTests/BazarrViewModelTests.swift` |
| `BazarrAPIClient.saveEnabledProviders` — the enabled subtitle-provider set | `TrawlTests/BazarrProviderSaveTests.swift` |
| `BazarrAPIClient.saveLanguageProfiles` and `saveEnabledLanguages` — whole-collection replaces | `TrawlTests/BazarrLanguageProfileSaveTests.swift` |
| Prowlarr management/search state | `TrawlTests/Prowlarr*StateTests.swift`; `TrawlTests/ArrIndexerManagementViewModelTests.swift` |

## App assembly, settings and notifications

| Production surface | Focused coverage to read/run |
|---|---|
| `Trawl/Views/ContentView.swift`, root environment injection and tab navigation | `TrawlUITests/NavigationSmokeWalkUITests.swift`; `TrawlUITests/TrawlUITests.swift`; `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| `Trawl/Utilities/NavigationDismissalGestures.swift` and notification-sheet presentation | `TrawlUITests/RecentNotificationsJourneyUITests.swift` | The notification sheet's real content/presentation is covered. A dedicated gesture-conflict regression should accompany future changes to the runtime recognizer matching. |
| More/Settings destinations, navigation guidance, and service removal | `TrawlTests/MoreNavigationGuidanceTests.swift`; `TrawlUITests/MoreSettingsBreadthUITests.swift`; `TrawlUITests/ServiceRemovalJourneyUITests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift` | User-facing breadcrumbs come from `MoreDestination.userFacingPath`, so instructional error copy cannot retain the removed name of a hub. The unit suite pins the canonical SABnzbd settings path; the UI journeys protect the renamed Integrations & Automation hierarchy and distinct SABnzbd hub/settings titles. |
| Arr notification webhook management | `TrawlTests/ArrWebhookNotificationManagerTests.swift`; `TrawlUITests/NotificationSettingsJourneyUITests.swift` |
| Recent notification history and clearing | `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| `Trawl/ArrStack/ArrOperationFeedback.swift`, plus Sonarr/Radarr mutation error ownership | `TrawlTests/ArrDualInstanceTests.swift`; `TrawlTests/ArrMediaFileDeletionTests.swift`; `TrawlTests/InAppNotificationActivationTests.swift` | Arr view models store failures through `capture`; the optional notification title decides whether the view model or its coordinating view owns the banner. Shared add fan-out emits one aggregate result, while media-file deletion deliberately stores errors without announcing because its presenting view owns the single banner. Success and failure presentation routes through one helper so these policies cannot drift into subtly different direct notification-center calls. |
| Onboarding persistence and validation, including cancellation (N-05): a cancelled attempt must return promptly and report nothing, and `AuthService.propagatesCancellation` stays opt-in so the shared re-auth instance keeps coalescing | `TrawlTests/OnboardingViewModelTests.swift`; the relevant setup/edit UI journey |
| Share input classification and termination | `TrawlTests/ShareExtensionInputTests.swift` |
| Widget refresh policy (including the Seerr Inbox and small-calendar countdown cadences), calendar day-sequencing, calendar scope and failure headlines, unified download-client selection, Seerr widget decoding and display fallbacks, lock-screen accessory formatting and gauge fractions, the Seerr Inbox deep-link target, and the blended qBittorrent + SABnzbd pause state behind the Control Center control; extension registration, installed-widget presence, `trawl://downloads` handoff, and Home Screen cleanup | `TrawlTests/WidgetTimelineAndDataTests.swift`; `TrawlUITests/WidgetInstalledProcessUITests.swift` | The unit suite compiles the exact pure sources the extension uses — `WidgetTimelinePolicy`, `WidgetFetchError`, `WidgetSeerrModels`, `WidgetGlanceFormatter`, `DownloadControlState`, `CalendarScopeOption` — so there is no copied implementation and no altered actor isolation. Every widget refresh interval must be added to `WidgetTimelinePolicy` and asserted here rather than inlined in a provider; each interval was proven load-bearing by perturbing the production value and observing the matching expectation fail. A calendar with zero events is empty only when at least one configured Arr answered; zero answers is unavailable. `WidgetDownloadClientSelection` pins the nil/all, qBittorrent, SABnzbd, and legacy unprefixed-qBittorrent identifier meanings so saved widgets survive the unified picker. `DownloadControlState` is the one place that answers "are downloads running?" across both clients, so a control that silently reverts to qBittorrent-only would fail `soleLiveSAB.isRunning`. Active Downloads also owns the representative rectangular Lock Screen/Smart Stack presentation. The UI journey is the installed-process boundary: SpringBoard discovers the embedded extension, the gallery renders an installable preview, the widget is added to the Home Screen, and tapping it opens the host app. It asserts only on SpringBoard-owned elements: widget content is rendered by `com.apple.chrono.WidgetRenderer` and is unreachable from XCTest, so the installed widget is identified by its icon carrying `value: Widget`, which the app icon does not have. It proves one representative widget kind because all five widgets and the Control Center control ship in one `WidgetBundle`; per-kind data fetches, lock-screen accessory rendering, Control Center toggle behaviour and physical-device refresh scheduling remain release smoke-test work. Async teardown restores the exact pre-test Trawl-widget count and refuses to remove anything if setup failed before that count was captured, preventing repeated runs from accumulating Home Screen state and crash-looping PosterBoard. |
| Arr media-file deletion request/state ownership and single-source user feedback — `SonarrViewModel.deleteEpisodeFile`, `RadarrViewModel.deleteMovieFile` | `TrawlTests/ArrMediaFileDeletionTests.swift` | Drives the real view models against loopback fixture servers and pins the exact authenticated `DELETE /api/v3/episodefile/{id}` and `DELETE /api/v3/moviefile/{id}`. The behavioural assertion is that the view model owns request/state/error while the presenting view owns the one banner: the view models must not announce, or the user sees two. Missing clients are errors too, rather than silent `false` results, but retain the same notification ownership. When changing feedback here, check every caller — `SonarrSeriesDetailView`, `SonarrSeriesSearchViews`, `RadarrMovieDetailView` — all three announce. |

| `InAppNotificationCenter` banner coalescing, and the one tap entry point | `TrawlTests/InAppNotificationActivationTests.swift` ("In-app notification coalescing") | Ten movies finishing an import produced ten banners, each replacing the last, so the user watched a slot machine and could read none of them. A run of the same title and style inside a six-second window is now one banner with a count. Three exclusions are pinned because each is a way the feature could quietly do harm: an **error is never folded into a run of successes** (style is part of the group key - the one failure among ten imports is the one that must not be absorbed); **progress banners are excluded**, being already keyed and replaced in place by `replaceProgressWith…`; and **history keeps every event** individually, because coalescing is a presentation decision and the log is an audit trail. The summary is rebuilt from the run's first message rather than the previous summary, or it compounds into "Us and 2 others and 3 others". Tapping is a single entry point, `activateCurrentBanner()` - the macOS banner used to carry its own inline copy of the same logic, which is exactly how two presentations drift. |
| `LibraryImportItem.importJSON` and the ManualImport command - the one call that moves files on disk | `TrawlTests/ArrAPIClientContractTests.swift` ("Arr manual import command contract") | The view-model suites stop at this boundary: they prove which files were selected, never what was sent. Every branch of `importJSON` exists because of a past silent failure, and all of them fail server-side with no useful message. Sonarr throws `ArgumentNullException` on a null `episodeIds`; the command handler reads the **flat** `seriesId`/`movieId` and not the embedded object; and a re-identified file otherwise carries the previous match's object, so it imports into the wrong title or fails as "Movie with id 0". The suite also pins `importMode` (copy must not relocate a file the user asked to keep), that a batch travels as one command rather than one per file, and that an unidentified file passes through with no invented id. Fast by construction: the stub returns a completed command with no `id`, so `postCommandAndWait` returns without entering its one-second poll loop. |
| `LibraryImportScanViewModel.addToLibraryAndIdentify` - add state and refusal reporting | `TrawlTests/LibraryImportScanViewModelTests.swift` ("Library import add-to-library state") | Two reported symptoms, one cause. `isAddingToLibrary` was a single `Bool` that the identify sheet used both to render "Adding to library..." and to disable its buttons, so one add anywhere blanked **every** open sheet, and because it was cleared on each return path rather than by `defer`, any path that missed one left them disabled permanently - a spinner where the Add button belonged, while multi-select import still worked because `performImport()` never consults it. State is now per-item and released by `defer`. The other half was a five-condition `guard` returning `false` with no message: literally "I hit Add and Import and nothing happens". Each precondition now names itself, and the root folder and quality profile are fetched on demand rather than depending on `loadLibraryIfNeeded()`, which swallows its own errors. |
| `ArrLibraryListView` - the shared library list's selection binding | `TrawlUITests/RadarrJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift`; `TrawlUITests/BazarrJourneyUITests.swift` | The rows are `NavigationLink(value:)`s carrying the item's id and the selection set holds that same type, so handing `List` a selection binding made it treat every row as selection-driven navigation and claim the tap: no library title opened its detail screen. The binding is now present only while editing. **These tests already existed and already covered it** - six of them failed the moment the full plan was run. What let the regression sit was running only the focused suites mapped to the surfaces edited; the change was to a *shared* component, and the suites that exercise it are owned by other surfaces entirely. A change to anything under `Library/` or to shared list chrome needs the full plan, not a focused run. |

## Cross-service configuration

| Production surface | Owning tests | What the tests pin, and why it matters |
| --- | --- | --- |
| `Trawl/Diagnostics/ConfigurationAudit.swift`, `ConfigurationSnapshot` — reconciling what each service has been told about the others | `TrawlTests/ConfigurationAuditTests.swift`; `TrawlUITests/ConfigurationAuditJourneyUITests.swift` | Nothing else in the app checks that Trawl, Sonarr/Radarr, Prowlarr, Bazarr, Seerr and Cleanuparr agree about each other, so a wrong answer here is silent in both directions: a fault nobody is told about, or a warning about a setup that is fine. The fetching is split into `ConfigurationAuditStore` and every rule is a pure function of `ConfigurationSnapshot`, which is what lets the suite build the wiring it wants to describe instead of standing up servers. **Per instance, never unioned or visibility-filtered:** every enabled profile is audited, so a disconnected or filtered-out 4K server cannot hide behind a healthy HD partner. **Unknown is not healthy:** a failed configuration read - including a failed `/health` read - produces an explicit unknown finding and prevents the wizard from showing an all-clear result. **Download-client identity includes host and port:** multiple Trawl endpoints of one kind are compared individually, so two qBittorrent instances on one host do not collapse together. **Finding identity includes the related endpoint/service/path:** two Bazarr links or shared paths on one subject cannot collide and dismiss one another. **Host *and* port for Prowlarr, plus the app type and sync level:** an HD/4K pair is normally one machine on two ports, matching on hostname alone makes Prowlarr's entry for one answer for both, an entry for Radarr is not evidence Sonarr gets indexers, and an entry whose sync level is disabled syncs nothing at all. **Arr's own health is a finding, weighted by source:** `DownloadClientStatusCheck` and its neighbours are things Trawl cannot see from outside and become problems; an update notice from the same server stays a note; an `error` is a problem whoever raised it. **Indexers are counted twice:** having any enabled indexer and having one that RSS or automatic search can use are different facts, and an interactive-only setup never grabs anything on its own. **Categories and remote paths:** two servers sharing one client endpoint *and* one category will import each other's downloads, which is a problem; a client on another host with no path mapping is only a note, because an identical mount is the common case and Arr's own `RemotePathMappingCheck` covers the failing one. **Seerr and Cleanuparr are topology, not decoration:** an uninitialised Seerr, a missing or defaultless DVR entry, or one with no root folder or profile all accept a request and then drop it; Cleanuparr already decides its own readiness and the audit now reads it. Loopback spellings still fold together, and a trailing slash is not a second root folder. The journeys prove findings reach all three user entry points: the Sonarr fixture answers `/downloadclient` with an empty array — a real answer, not a failure — then one test walks More → System → Setup Check, one opens the notifications sheet's live System Attention card, and one reads the Downloads screen's contextual banner. The card is backed by the shared store and must not be inserted into notification history, which can be marked read or cleared. **Contextual banners are hidden on a UI-test launch** (`ConfigurationAttention.isContextuallyVisible`) for the reason the discovery tips are: nearly every suite in the target asserts on a screen one would sit above. `testDownloadsShowsSetupAttentionForADownloadClientFault` opts back in through `TRAWL_UITEST_SHOW_ATTENTION`, and `testAnOrdinaryTestLaunchShowsNoContextualBanner` is the guard that proves an ordinary launch stays silent while the audit has genuinely found something. |

| `DownloadListItem.sortedByDownloadOrder(_:)` - the Downloads list sort | `TrawlTests/DownloadsHistorySortPerformanceTests.swift` | The History section froze the tab. `DownloadsView.items` passed `sortValues` - a *computed* property - straight into `.sorted`, so the key was rebuilt roughly `2 n log n` times rather than `n`; for an `.arrHistory` row that key costs a string interpolation, an event-name formatter lookup and two dictionary reads. Measured at 2,000 rows: **0.18s rebuilt per comparison against 0.034s built once**. Three things stack only on History - it is the largest list (everything ever grabbed, across both services and both instances of each, where Active and Queue hold only what is in flight), its rows are the most expensive to key, and its dates tie constantly (history arrives in bursts, and unparseable dates all collapse to `.distantPast`), so nearly every comparison falls through to the `localizedCaseInsensitiveCompare` tiebreaker. `items` is a computed property on the *view*, so all of it re-ran on every body evaluation while the polling services ticked. The suite pins both halves: the timing, and that the helper produces **byte-identical ordering** to the direct comparator across every criterion - a faster sort that reorders the list is not a fix. Note this is the same mistake twice in one path: `HistoryItem.sortDate` already carries a comment about being parsed once at construction for exactly this reason, one layer down. |

| `ProwlarrIndexerOrigin`, and the Indexers nudge that uses it | `TrawlTests/ConfigurationAuditTests.swift` ("Configuration audit"); `TrawlUITests/ConfigurationAuditJourneyUITests.swift` (`testIndexersScreenOffersToAddAProwlarrItCanSee`) | Prowlarr does not announce itself, and Sonarr and Radarr keep no record that an indexer was synced rather than typed in - so a user whose indexers are managed somewhere Trawl cannot see gets an Indexers screen that lists them with no explanation. The one mark Prowlarr does leave is that it proxies every indexer it manages under its own numeric id, so a synced entry points at `<prowlarr>/<id>/api` while a hand-added Newznab points at the tracker. That distinction is the whole check, and it is what the unit tests pin from both sides: the proxy path is recognised (including behind a reverse-proxy URL base), a tracker URL that merely ends in `/api` is not, and the most-seen address wins so one stray entry cannot outvote a real sync. **The answer has to be stable across orderings** - ties break alphabetically - because the address is the finding's `discriminator`, and an id that moves between audits is a dismissal that stops sticking. It is a **note, never a problem**: nothing is broken, and managing Prowlarr in a browser is a reasonable choice. The journey proves the nudge reaches the wizard *about that finding* - `focusedKind` - rather than dropping the user into an unrelated repair step, which is what it did before the wizard learned to open focused. |
| `ConfigurationWizardView` notes, and `focusedKind` | `TrawlUITests/ConfigurationAuditJourneyUITests.swift` | Notes were rendered as static rows, so a note carrying a fix destination - "review your download clients", "add the Prowlarr that is managing these" - offered a button nothing could reach. They are now links, while still staying out of the numbered repair sequence: a note is something to know, not something to be marched through. `focusedKind` is the other half: a caller that opens the wizard *about* one finding gets that finding, with the rest of the check one tap behind it. |

## Screens that had never been rendered

The full plan's coverage report is the source for this section: every file below sat
at or near 0%, meaning no test had ever opened it. A screen that fails to decode its
payload, or renders blank, is indistinguishable from a working one until someone hits
it in use - which is how three render-only defects reached a user this cycle. Each
journey therefore asserts **content decoded from the fixture's own response**, never
just that a navigation bar appeared: a screen that pushes correctly and then shows
nothing is precisely the failure being guarded against.

| Production surface | Owning tests | What the tests pin, and why it matters |
| --- | --- | --- |
| `Trawl/ArrStack/BazarrLinkedApplicationsView.swift` | `TrawlUITests/BazarrLinkedAppsJourneyUITests.swift` | Rewritten from a scope bar that swapped one server's settings in and out, to one section per Bazarr with both loaded up front - to stop the page hitching, and to close the window in which a save could write one server's host and API key into the other. Neither property is visible from a unit test. The two fixtures are deliberately given **opposite** answers (A has Sonarr at `10.0.0.11`, B has Radarr at `10.0.0.22`), so a section rendering the wrong server's data fails rather than coincidentally agreeing - had both been seeded identically the test would pass whether or not the isolation worked. The second journey taps a row and asserts the editor seeds from *that* section's server, which is the credential-crossing risk itself. Needed new harness: `TRAWL_UITEST_BAZARR_B_BASE_URL` seeds a second Bazarr, and `BazarrUIFixtureServer` now serves per-server `/api/system/settings`. |
| `Trawl/ArrStack/BazarrProvidersView.swift`, `BazarrProviderCatalog` | `TrawlUITests/ArrUncoveredScreensJourneyUITests.swift` | The list is built from `settings.general.enabled_providers` mapped through a hardcoded catalog - **not** from `/api/providers`, which supplies only status. That lookup used to `compactMap`, so a provider Bazarr had enabled that the catalog has no entry for vanished with nothing on screen to explain it. The catalog necessarily lags Bazarr's own provider set, so this was permanent rather than rare. Unknown keys now render through `BazarrProviderCatalog.unknown(key:)` - named from the key, carrying no editable fields (we do not know its settings, and inventing them would be worse than showing none) and still resolving its real status badge. The fixture enables **one catalogued and one uncatalogued** provider and asserts both appear: testing only the unknown one would let a regression that dropped everything pass, and testing only the known one restores the original bug unnoticed. |
| `Trawl/ArrStack/ArrEventsView.swift` | `TrawlUITests/ArrUncoveredScreensJourneyUITests.swift` | Opens the screen against a real Sonarr and asserts the log record the server actually returned, so a decode regression in `ArrLogPage`/`ArrLogRecord` fails here rather than leaving an empty screen that still pushes correctly. `SonarrFixtureServer` gained `logJSON`, defaulting to an empty page - a real answer, since a server with nothing logged is a state the screen has to render. |
| `Trawl/ArrStack/ArrDownloadClientListView.swift` | `TrawlUITests/ArrDownloadClientsJourneyUITests.swift` | The screen the configuration wizard sends people to when the audit finds a server with no download client - routing users into a screen nothing had ever opened is how a fix path becomes a dead end. Asserts the client's name and its `host:port`, the latter read out of Sonarr's `fields` array, where a decode regression leaves the row blank rather than failing loudly. `SonarrFixtureServer` gained `downloadClientsJSON`, defaulting to none. |
| `Trawl/ArrStack/SonarrSeriesSearchViews.swift` - the season and episode drill-down | `TrawlUITests/SonarrSeasonEpisodeJourneyUITests.swift` | The largest gap in the app: 3,616 executable lines at 12.7%, most of it `SonarrSeasonSearchView` and `SonarrEpisodeSearchView`. Never opened with real data because no journey had ever given `SonarrFixtureServer` an episode list - `episodesJSON` existed and every test left it empty. The fixture serves **one episode with a file and one without**, because the season screen renders those states differently and a fixture carrying only the downloaded case exercises half the view. The episode screen is asserted by its navigation title, which is `episodeIdentifier` - *derived* (`String(format: "S%02dE%02d", …)`) rather than served, so a formatting regression there renames every episode screen in the app and nothing else pins it. These are the screens a user reaches while chasing a single missing episode, so a rendering failure here surfaces at the worst possible moment. |
| `Trawl/JellyfinStack/JellyfinUserEditorView.swift`, `policyRow` accessibility | `TrawlUITests/JellyfinUserEditorJourneyUITests.swift` | 2,353 lines at 0% and the most consequential of the never-rendered set, because it displays a Jellyfin user's *permissions*. Deliberately read-only: it proves the editor seeds from the policy the server returned and asserts no `POST …/Policy` was made. A test that flips permissions to prove it can is one that will eventually flip them somewhere it should not, and seeding is where the risk actually lives - a row showing the opposite of the server invites an administrator to "correct" something that was never wrong. Administrator and Disabled are asserted together and must **disagree**, so a view rendering defaults instead of the server fails rather than coincidentally agreeing. Writing this surfaced a real accessibility defect, now fixed: `policyRow` conveyed granted-vs-denied with a green tick alone, so VoiceOver read every permission as just its name and a blind administrator could not tell an enabled permission from a disabled one. It now carries an `accessibilityValue`. The reason the row was untestable and the reason it was inaccessible were the same fact - state encoded only in pixels is invisible to both. |

**`TrawlIconSegmentedPicker` is deliberately uncovered.** It is a self-contained
component with no production call site yet - built to match Apple Weather's inline
conditions picker so it is ready when a card header needs one. A UI journey cannot
reach a view nothing mounts, and a unit test over a pure SwiftUI body would assert
its own construction. Its two `#Preview`s are the check that it renders, in both
appearances. **Whoever adopts it owns its first real test**, and that test belongs to
the screen that adopts it, not to the component.

**Library identity is not lookup identity.** `RadarrMovie`/`SonarrSeries` hash on
`(id, instanceID)`, which is correct for a row that came from a server and meaningless
for a lookup result: Radarr and Sonarr report `id == 0` for everything they have not
added, and a lookup result carries no `instanceID`. Every un-added result was therefore
`==` to every other one, which broke four things at once - `ForEach` rendered a single
row no matter how many results a search returned, the Add sheets highlighted every row
when one was picked, and `NavigationStack`, which keys destinations on value identity,
reused the screen it had already built, so tapping a second trending card opened the
first card's film. Both models now carry a `lookupIdentity` built from the external ids
the result actually carries, and every collection or navigation value that can hold a
lookup result keys on it; `id` still means library identity, unchanged.

`ArrMediaDestinationTests` had **pinned the collision as correct** - `#expect(destinations.count == 1)`
under a comment calling it "occasionally-surprising behavior". A test that documents a
defect precisely enough to describe its consequences, and asserts it anyway, is worse
than no test: it makes the bug look deliberate and stops anyone else reporting it. The
suite now asserts distinctness, and `RadarrSearchAddJourneyUITests` drives the tap
sequence end to end, because the equality is only half the story - what the user
experiences is the second screen, and nothing but a real push proves the stack agrees.
The journey uses two lookup results whose *titles* differ and whose library ids are
both `0`, which is exactly the payload real Radarr returns.

| Production surface | Owning tests | What the tests pin, and why it matters |
| --- | --- | --- |
| `ArrMediaDestination` equality/hash; `RadarrMovie.lookupIdentity`, `SonarrSeries.lookupIdentity` | `TrawlTests/ArrMediaDestinationTests.swift`; `TrawlUITests/RadarrSearchAddJourneyUITests.swift` | The unit suite pins that two un-added results stay distinct while an identical copy still compares equal - both halves matter, since over-distinguishing would break the zoom transition's source/destination match. The journey asserts the *second* result's own detail screen opens and the first is gone. |
| `SearchView.SearchResultEntry`, `RadarrAddMovieSheet`, `SonarrAddSeriesSheet` result lists | `TrawlUITests/RadarrSearchAddJourneyUITests.swift` | The journey asserts **both** lookup results render before it taps either. That assertion is what caught the `ForEach` collapse - the navigation bug was the reported symptom, but the list had been silently showing one result out of every N since the search screen was written. |

**A disappearance is waited for, not sampled.** `SABnzbdUnauthorizedJourneyUITests`
asserted a stale job row was gone the instant the unauthorized error text appeared.
The app was right - `clearActiveConnection()` nils the queue alongside the error, and
`DownloadsView` reads `activeJobs` live - but SwiftUI keeps a row in the accessibility
tree while its removal animates, measured at ~50-60ms. That made the test pass alone
and fail inside the full plan, where the host is busier and the window widens. The
timeout on that wait is deliberately short: it guards a real guarantee, so a row that
never clears must still fail rather than be waited out.

**Navigation in these journeys asserts its destination after every tap.** `tapWhenHittable`
returning true means "I tapped something", not "I arrived somewhere", and every one of
these routes has a same-named entry in More's search index. Three attempts at the Bazarr
routes reported successful taps while landing on the wrong screen, and the failure then
surfaced several assertions later pointing at the wrong cause. Asserting the navigation
bar at each step is what makes a mistargeted tap fail where it happened.

## iPad chrome

`ContentView` builds two different chromes and the split is by
`horizontalSizeClass`, not by device: compact gets the five-tab `TabView`, regular
gets a hand-built `NavigationSplitView` whose sidebar is always visible. A
full-screen iPad is regular; the same iPad in a narrow Split View or Slide Over
becomes compact and gets the phone's tab bar.

`.sidebarAdaptable` is deliberately *not* what produces the iPad sidebar any more.
It offers a toggle that collapses into a floating pill, that choice persists across
launches, and the pill renders only tabs that carry no `defaultVisibility` of their
own — so promoted destinations vanish with it. There is no API to hold it open
(`TabViewStyle` has `.sidebarAdaptable` and `.tabBarOnly`, nothing between).

**A hidden `Tab` is still built, and that is not free.** The first version of this
work declared all twelve destinations as tabs and hid seven from the tab bar with
`defaultVisibility`. On iPhone those seven never appeared — but each one built a
full `MoreView`, with its own `.searchable` list, and their presence changed the
*visible* More list's accessibility: rows that had been one merged `Button`
labelled "Settings" became unlabelled `Cell`s with the text as a child. Nothing
looked wrong on screen; every journey that reaches a More row by name failed
(`NavigationSmokeWalkUITests`, `MoreSettingsBreadthUITests`). If a chrome needs
different destinations per size class, build the two chromes separately rather
than declaring every destination once and hiding what does not belong.

Sidebar rows carry `nav.<case>` accessibility identifiers (`RootTab
.navigationIdentifier`) because label matching is ambiguous there: "Downloads" also
prefixes the Downloads screen's own "Downloads, change view" title menu, and a test
that matched by label tapped the menu instead, opening a popover that swallowed
every subsequent tap.

## Feature-discovery tips (TipKit)

| Production surface | Owning tests | What the tests pin, and why it matters |
| --- | --- | --- |
| `Trawl/Tips/` — the four tips, their stable IDs and shared events | `TrawlTests/TrawlTipsTests.swift` | The IDs are a contract with a datastore that already exists on every device that has run the app: a typo or a stray `.vN` bump re-shows a tip everyone dismissed, with no crash and no warning. Asserted against literal strings rather than round-tripped through the same constant, which would pass whatever the string said. Also pins the two *shared identities* that implement stated behaviour and have no other mechanism behind them — one blended-library tip across Series and Movies (so dismissing it under Series suppresses it under Movies), and one `libraryDetailOpened` event across both media types (so a Radarr-only user is not made to earn a three-opening tip six times). |
| `TrawlApp.init()` → `TrawlTips.configure()`; presentation in `DownloadsView`, `ArrMediaListView`, `ArrCalendarView` | `TrawlUITests/TipsPresentationUITests.swift` | Each tip is asserted on the surface it is anchored to, using the `TRAWL_UITEST_SHOW_TIP` override — which forces one tip past its own rules, so a presentation test does not have to manufacture three detail openings or a second launch. The quick-actions case runs on a **single**-instance library on purpose: that is the case `.firstAvailable` grouping exists for, and an `.ordered` group would leave those users never seeing it. |
| The UI-test hide, in `TrawlTips.applyTestingOverridesIfNeeded()` | `TrawlUITests/TipsPresentationUITests.swift` (`testOrdinaryLaunchesShowNoTips`) | **This one protects the rest of the target.** A popover anchored to a toolbar item swallows the taps aimed at it, and an inline tip pushes the first library row down past where a test expects it — so a new tip that forgets the hide breaks unrelated journeys in a way that reads as *those screens* being broken. The test seeds the richest configuration the tips care about (two download clients, two Sonarr instances), so every state rule is satisfied, and asserts all four titles are absent anyway. |

**A `.popoverTip` in a `.principal` toolbar item never presents.** The queue-switch
tip was anchored to `DownloadsView`'s title menu and simply did not appear - not
because of its rules, and not because of the `Menu` it sat on (an anchor beside the
menu behaves the same). `.principal` replaces the navigation title, and popovers from
there do not show. It is now an inline `TipView` in a top safe-area inset immediately
below the bar. A `.popoverTip` on an ordinary toolbar button is fine, which is what
`ArrCalendarView` still uses and what `testCalendarSubscribeTipAppearsOnTheSubscribeButton`
holds in place.

**Two things made that test unrepeatable, and both are fixed in production.** The tip
datastore outlives the app install, so `TrawlTips.applyTestingOverridesIfNeeded()` now
calls `Tips.resetDatastore()` on a UI-test launch - `-TrawlUITestInMemoryStore` already
means "this launch keeps nothing", and the tips were the last thing that did. And the
queue-switch tip was invalidated from `onChange(of: titleDestination)`, which More's
search also triggers by routing to Torrents: the one hint that would have shown someone
the menu was being spent on a route they took another way. Invalidation now happens
only through the menu's own binding.

Rules themselves are unit-tested, not UI-tested: whether TipKit evaluates a `#Rule`,
whether a popover draws, when the daily budget resets — those are Apple's, they need a
configured datastore, and asserting them in a simulator would be testing the framework
rather than Trawl.

**Events are persistent, `@Parameter`s are transient, and mixing them up is the usual
bug.** Interaction counts that must survive relaunch (`libraryDetailOpened`,
`calendarOpened`) are `Tips.Event`s. Current app state — whether two servers are
configured *right now*, whether this library has rows, whether a bulk selection is in
progress — is a `@Parameter`, because a persisted copy goes stale and puts a tip over a
loading spinner, an empty library, or a selection in progress.

## One suite, two chromes

`TrawlUITests/TrawlChrome.swift` is how every journey suite in this target reaches a
screen. Call `openDestination(_:in:)` and it takes whichever route the running device
provides; call `ensureRootChromeIsReady(in:)` to wait for the app to clear the welcome
gate; call `searchTheAppChrome(for:in:)` to drive whichever field searches the feature
index. **No suite should hard-code `app.tabBars.buttons[...]` again.**

The reason is not tidiness. Before this existed, roughly thirty suites opened with
`app.tabBars.buttons["More"]`, which does not exist on iPad — so on an iPad
destination the first assertion failed and, with `continueAfterFailure = false`, took
the rest of the class with it. Every behaviour those suites cover was unverified on
iPad, and none of them said so: they simply were not run there. Making the navigation
chrome-agnostic was the cheapest way to fix that, because the behaviour under test is
identical on both platforms. Only the route to it differs.

So the same test now runs on an iPhone destination and an iPad one, and a chrome that
breaks on either fails the suite. Three queries need care, and each cost a run to
learn:

- **`contentSearchField(in:)`, not `app.searchFields.firstMatch`.** On iPad the
  sidebar carries a permanent `.searchable` of its own, so any screen with a search
  field has two in the tree. `firstMatch` returns the sidebar's — further up the
  hierarchy and further left — and a test typing into it searches the feature index
  instead of the screen, gets nothing, and blames the screen.
- **One journey is skipped on iPad, and says why.** `SeerrJourneyUITests`'s resolve
  journey is `XCTSkipIf(TrawlChrome.isSidebar)`: the notification accessory is a
  full-width bar across the bottom of the window, and the issue screen's own bottom bar
  lays out underneath it, so the tap opens the notifications sheet instead of resolving
  anything. That is a product defect - a person cannot resolve a Seerr issue on an iPad
  either - deliberately deferred while the issue UI is reworked. It is written up in
  `TRAWL_KNOWN_ISSUES.md`, and the skip is what brings the coverage back the day the
  chrome is fixed. Skipping is the exception here, not a pattern to copy: a skip
  without an entry in that file is a hole, not a decision.
- **`backButton(in:)` on every pushed screen, not `buttons.firstMatch`.** The rule was
  documented but two suites still spelled it by index;
  `RadarrSearchAddJourneyUITests` pressed the sidebar toggle instead of Back and then
  failed on the screen it had never left. The helper itself was also not safe on a bar
  with trailing actions: query order is not screen order, and on the iPad SABnzbd hub
  "first" was the Categories screen's trailing **+**, so popping back opened an Add
  Category sheet. It now prefers UIKit's `BackButton` identifier and otherwise takes
  the leading-most non-toggle button.
- **`waitForExistence(in:)` scrolls both ways.** A pushed screen restores its previous
  offset when it is popped back to, so a row that was above the fold on arrival is
  still above it - and scrolling only downward walks away from it.
- **A label that names a destination is ambiguous.** "Series" is the tab bar button on
  iPhone and the sidebar row on iPad, so a menu option of the same name has to be
  disambiguated by position. `ArrBlendedLibraryJourneyUITests` does this against
  whichever neighbour is actually on screen.
- **The iPhone tab bar minimises itself.** iOS 26 collapses the bar to a single pill
  carrying the selected tab as soon as the content behind it scrolls, and every other
  tab leaves the accessibility tree outright — so a query for one fails exactly as it
  would if the chrome had never appeared. Reaching Settings scrolls More's list far
  enough to trigger it, which is why a journey that edited a server and then went back
  to Series reported that the Series tab did not exist. `expandTabBarIfMinimized(in:)`
  taps the collapsed pill, and `openViaTabBar` calls it before giving up on a tab. It
  is a *compact*-only failure, so an iPad-only run never sees it.
- **`.searchable(placement: .automatic)` in a split-view column produces no field.**
  Running the plan on an iPad destination for the first time found Search with a
  scope bar, a trending grid, and nowhere to type: iPadOS 26 already carries the
  sidebar's own `.searchable`, and given `.automatic` it keeps that one and drops the
  column's. `SearchView.searchFieldPlacement` now names
  `.navigationBarDrawer(displayMode: .always)` on both chromes. Four journeys were
  reporting this as "the lookup returned nothing".
- **A plain-styled button is only tappable where it draws.** The System hub's Setup
  Check row is a `Button(...) { NavigationMenuRow(...) }.buttonStyle(.plain)`. On an
  iPhone the row is narrow enough that its centre is over the text; on an iPad the row
  is over a thousand points wide and its centre is empty space, so tapping it did
  nothing at all - on the one screen whose job is to say something is wrong. The fix
  is `.frame(maxWidth: .infinity, alignment: .leading)` **and** `.contentShape` inside
  the *label*: on the Button it shapes the button rather than the label, and
  `.contentShape` alone has no width to shape. `testSetupCheckSurfacesAServerWithNoDownloadClient`
  taps the row's centre deliberately, and is what says so.
- **The keyboard is a collection view, hosted out of process.** On iPad it is the
  *last* one, so "take the frontmost scroller" swiped the keyboard: four rounds of
  "Wait for com.apple.springboard to idle" while the sheet under test sat still.
  `XCUIApplication.scroller(for:)` excludes it by frame and then narrows to the
  candidate the target control is horizontally inside, which is what tells a form
  sheet's list apart from the sidebar beside it.
- **With a sheet up, `collectionViews.firstMatch` is the list *underneath*.** A setup
  sheet is presented over Settings, so two lists are on screen and the first in the
  hierarchy is the background one. `ServiceSetupEditJourneyUITests` swiped it four
  times while the sheet stayed exactly where it was, then reported that a nonempty
  form would not enable its confirm button - the button was simply below the keyboard
  raised by the field just typed into. Its `tap` helper now swipes the *last*
  candidate, which is the presented one (and on iPad also steps past the sidebar, for
  the same reason `XCUIElement.contentScroller` skips it). `XCUIElement.contentScroller`
  still takes the first non-sidebar match; it has not bitten a suite that presents a
  sheet over a list, and is worth the same treatment when one appears.
- **"Leaving" a hub is not a pop on iPad.** A sidebar destination is the root of its
  own column, not a push onto More's stack, so there is no back button. The equivalent
  gesture is selecting something else — see `assertHubOpensAndCanBeLeft` in
  `NavigationSmokeWalkUITests`, which asks each chrome for its own gesture and then
  asks both the same question: is this screen still reachable?

Run the plan on both destinations before calling a change done:

```
xcodebuild -project Trawl.xcodeproj -scheme Trawl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/trawl-dd test
xcodebuild -project Trawl.xcodeproj -scheme Trawl \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /tmp/trawl-dd test
```

One at a time: concurrent simulator runs fake crashes and leave result bundles
unfinalized.

## The sidebar is the map

The seven hub *screens* are gone from the sidebar chrome. A hub was a screen whose
entire job was to list the screens under it - which is what a sidebar already is, so
on a display wide enough to hold one the hub was a click spent on nothing.
`SidebarSection` now owns six collapsible groups and every screen worth going to is a
row: 32 of them, against the eleven that came before.

**Both chromes still work, and they work differently, which is the point.**
`RootTab.moreRoot` says which screen a row roots its stack at; `MoreView` and its hubs
are untouched, because on iPhone the hub is still how you get there. So the same
screen is one click away on iPad and three taps away on a phone, and neither route is
a special case of the other.

**What that means for this target.** `TrawlDestination` is a *screen*, not a route.
`parentHub` is how a screen says which hub it is filed under on compact, and
`openViaTabBar` walks More → hub → row on its own. A test therefore names the screen -
`openDestination(.indexers, in: app)` - and never the route, which is why the same call
works on both chromes. Asking for a hub itself on the sidebar chrome fails loudly
rather than selecting something arbitrary: there is nothing there to open, and a
harness that reported success for that would send the failure somewhere else entirely.

**Setup Check was the one thing that nearly got lost.** Every other row of the System
hub was promoted, so the hub would have been a screen containing a single item that
nothing linked to. It is a row of its own now, and `SystemHubView` hides the promoted
rows on the sidebar chrome rather than repeating a list that is already beside it.

**One name per screen.** The sidebar row, the More row and the navigation bar now agree
everywhere, because the harness confirms arrival by the bar and a screen that calls
itself something else is indistinguishable from a screen that never opened. Two names
were changed to make that true: `SeerrIssueListView` was "Issue Management" under a row
called Issues, and the Remote Paths row is now "Remote Path Mappings", which is what the
screen and More's own row already called it.

**The connection fallbacks are the ones to watch.** Every service-backed destination has
two or three of them — connected, unreachable, not set up — and only the connected
branch tends to get a title. Indexers had *neither* fallback titled, so with the servers
down it arrived under a blank bar; Libraries, Sessions, Users and Issues shared a
fallback that titled itself after the *service*, so they arrived saying "Jellyfin" or
"Requests". These are invisible when the fixtures are healthy and are exactly what a
run against unreachable servers catches, which is worth doing deliberately: launch with
the `TRAWL_UITEST_*_BASE_URL` variables pointed at `http://127.0.0.1:1/...` and walk the
sidebar.

## Sidebar interaction follow-up

| Production surface | Focused coverage | Contract |
| --- | --- | --- |
| `ArrWantedView`, `ArrWantedDestination`, `WantedItemActionRow` | `IPadSurfaceCaptureUITests.testCalendarAndMissingSelectionsUpdateTheDetailColumn`; `.testMissingCompactRowConfirmsBeforeSearching` | iPad row taps replace detail and send no search command. Compact row taps ask first; Cancel sends nothing and Search reaches the real command endpoint. Subtitle rows use the same interaction component, with Bazarr detail destinations. |
| `SidebarScrollState`, `ContentView.sidebarList` | `IPadSurfaceCaptureUITests.testSidebarPositionSurvivesColumnCountChanges` | Root Folders → Quality Profiles, Library Import → Indexers, and the reverse column-count transition retain the tapped sidebar row's vertical position. |
| Downloads/Series/Movies title menus | `IPadSurfaceCaptureUITests.testTitleMenusLeadTheirIPadColumns` | With menus available, each menu sits at its native column's leading edge. Compact placement is unchanged. |
| `DownloadsView.arrQueueRow` | `IPadSurfaceCaptureUITests.testQueueActionDialogsBelongToTheirRows` | Each unlinked queue row owns its confirmation popover; dismissing it never removes either queue item. Screenshot attachments show the anchors. |

## Native sidebar navigation columns

The sidebar was audited for simulated side-by-side layouts. Indexers, Download Clients, Linked Applications, Quality Profiles, Tasks, Requests, Calendar, and Missing now use the root three-column `NavigationSplitView`. Downloads, Series, Movies, and Search already used native columns; the remaining sidebar destinations use a native two-column stack and have no simulated inner columns.

`TrawlListDetailPanes` now chooses the requested native column and never draws an HStack or an inset title. Outside the sidebar it shows the list as a normal push destination. `sidebarNavigationColumn` is cleared below each column root so nested screens and sheets do not accidentally participate in the sidebar selection. Each column owns its own navigation title and toolbar.

Sidebar selection models live in `ContentView`, alongside the existing per-destination navigation paths, so they survive switching destinations. The Indexers journey verifies switching away and returning to the selected detail. This does not claim complete tab-state restoration: screen-local filters, search text and scroll position still need their own retained state and coverage.

| Production surface | Focused coverage | Contract |
| --- | --- | --- |
| `ContentView`, `RootTab`, `TrawlListDetailPanes`, `TrawlColumnSelection`; Download Clients, Linked Applications, Quality Profiles and Tasks | `IPadSurfaceCaptureUITests.testDetailPaneTitlesSurviveSelection`; `MoreSettingsBreadthUITests.testQualityProfilesShowsOnlyTheNewProfileToolbarAction` | Both navigation bars must exist, with the list bar left of the selected detail bar. No `list-detail-screen-name` content header may substitute for a navigation bar. The quality-profile fixture travels through the production per-server load. |
| `ProwlarrIndexerBrowserState`, `ProwlarrIndexerSelection`, `ProwlarrIndexerListView` | `IPadSurfaceCaptureUITests.testDetailPaneTitlesSurviveSelection`; `ProwlarrJourneyUITests` | Selection and live models are shared across native columns. Proxies, Tags and indexers use one typed selection. Switching sidebar destinations must remove the previous detail and returning must restore its selection. The compact journey navigates through the real More route without tapping an extra row after Indexers has already opened. |
| `ArrCalendarView`, `ArrWantedView` | `IPadSurfaceCaptureUITests.testCalendarAndMissingSelectionsUpdateTheDetailColumn`; `.testCalendarAndMissingOpenBesideAnEmptyPane`; `ArrCalendarConcurrencyTests` | Calendar and Missing open unselected; two successive real fixture-backed selections must populate the native detail while the list keeps its own navigation title. Calendar sheets remain single-column push navigation; compact Missing rows confirm an automatic search. |
| `SeerrRequestBrowserState`, `SeerrDashboardView` | `ServiceUnavailableJourneyUITests.testRequestSelectionKeepsListUsable` | Columns share one live request model. A movie followed by a series must load the corresponding detail and leave the request list usable. |

Navigation tests require native navigation bars through `TrawlChrome.confirmArrival`
and `showsScreen(named:)`; neither accepts a custom content header. A selectable
list row can appear as a `Cell` on iPad and a `Button` on iPhone, so the relevant
journeys use helpers that handle both. Once `openDestination` has completed a
route, do not tap another similarly named row: it can navigate away from the
screen that was just opened.

**Seven of these suites fail on iPhone, and did so before any of this.** Measured
rather than assumed: the same four suites were run against `774a039` in a worktree and
failed on exactly the same seven assertions. They are `ArrDownloadClientsJourney
UITests.testSonarrDownloadClientsRenderTheServersOwnClient`, `ConfigurationAudit
JourneyUITests.testSetupCheckSurfacesAServerWithNoDownloadClient` and
`.testIndexersScreenOffersToAddAProwlarrItCanSee`, both `CleanuparrJourneyUITests`, and
both `BazarrLinkedAppsJourneyUITests`. The shape is the same in each: More's list
carries a connection-issues card and a service-unreachable card at the top - the
fixtures deliberately serve failures - which pushes the hub rows below the fold, and
these tests wait for a row without scrolling to it. Worth fixing; not caused by the
iPad pane work, and not fixed by it either.

**Whether a list has a pane beside it is asked of the chrome, not the size class.** A
`NavigationSplitView`'s content column reports itself `compact` on iPad, so a row that
decides between selecting and pushing on `horizontalSizeClass` gets it wrong.
`TrawlListDetailPanes` publishes `\.hasDetailPane` and the list reads that.

## iPad behaviour

| Production surface | Owning tests | What the tests pin, and why it matters |
| --- | --- | --- |
| `DownloadsView.detailSelection`, and `ContentView.detailColumn(for: .downloads)` | `TrawlUITests/IPadSidebarJourneyUITests.swift` (`testOpeningADownloadDoesNotLeaveItInTheDetailColumnOfTheNextDestination`) | Downloads was the last content-column list still pushing with `NavigationLink(destination:)`. A destination link in a split view's *content* column presents into the *detail* column, and that presentation outlives the sidebar selection that made it - so opening a download and then selecting Series left the download's detail sitting on top of the Series column, two destinations on screen at once. The list now drives the column through a selection and the detail is that column's **root**, which is the pattern `ArrMediaListView` already used and the reason Series and Movies never had the bug. The selection names the *screen* rather than the row, so an Arr queue row and the torrent row behind it resolve to one destination; and a selection whose download has left the list is cleared, but nothing is auto-selected - this list churns, and auto-selecting would take the detail column away from whatever the user was reading every time a download finished. On iPhone `detailSelection` is nil and the row keeps its link, so nothing changes there. |
| `ContentView`'s iPad sidebar; `RootTab.sidebarDestinations`; `MoreView(root:presentation:)` | `TrawlUITests/IPadSidebarJourneyUITests.swift` | The sidebar lists all seven promoted More rows **and does not list More** — both halves are asserted, since checking only that the seven appeared would still pass with More sitting alongside them, which is the arrangement this replaced. Selecting a destination is checked by its *screen* arriving, not by the tap succeeding: an earlier chrome reported taps as successful while the content column never moved. |
| `ArrMediaListView.detailSelection`, `reconcileSelection` | `TrawlUITests/IPadSidebarJourneyUITests.swift` (`testSeriesOpensOnItsFirstTitle`) | A three-column layout that opens on "Select a series" spends half the display saying nothing. The assertion is on the *detail column's* navigation bar carrying the title, not on the row — the row's title is in the list either way, so matching it would pass even with an empty detail pane. |
| `MoreSearchIndex` as the sidebar's search; `RootTab.owningSidebarDestination(forSearchCategory:)` | `TrawlUITests/IPadSidebarJourneyUITests.swift` (`testSidebarSearchReachesAScreenThatIsNotASidebarRow`) | On iPad the sidebar's field is the *only* search — More, which used to own one, is not in this chrome. So it searches the same index More does, and the test deliberately looks for Quality Profiles: two levels down under Library Management and not a sidebar row, so a filter over the eleven destination names could never find it. It also asserts the result lands on the hub that owns it, so there is a way back. |

**The suite skips itself on iPhone** (`XCTSkipUnless … userInterfaceIdiom == .pad`). The
chrome does not exist at compact width by design, so a phone run has nothing to say
about it and a red suite there would be noise. A full-plan run on an iPhone
destination reports these four as skipped, not failed.

Two things about querying this chrome, both of which cost a run to learn:

- **Sidebar rows are matched by their `nav.<case>` identifier, never by label.**
  "Downloads" also prefixes the Downloads screen's own "Downloads, change view" title
  menu; matching by text tapped that instead and opened a popover that swallowed every
  later tap.
- **`.searchable` inside a `List` starts scrolled out of view.** The field is above the
  first row, so it has to be pulled down before it can be found — it is not missing.
  It also does not reliably surface as a `searchField`; it can arrive as a text field
  carrying the prompt as its placeholder.

## Library rows navigate two different ways

`ArrLibraryListView` and `ArrMediaListView` now have two navigation modes, chosen
by whether `detailSelection` is present:

- **`nil` (iPhone, and any `NavigationStack` host):** rows are `NavigationLink`s and
  a tap pushes. Unchanged, and the existing journeys
  (`SonarrConnectedJourneyUITests`, `RadarrJourneyUITests`,
  `ArrBlendedLibraryJourneyUITests`) still cover it.
- **Present (iPad split view):** rows are plain, `List` owns the tap, and the
  selection drives the detail column beside the list.

The two cannot be merged. `ArrLibraryListView`'s existing note explains why a
selection binding breaks links in a stack — the List claims the tap and nothing
pushes. In a split view that is the *desired* behaviour, so the mode is chosen by
host rather than fixed. The edit-mode multi-select `Set` binding is a third,
separate thing and wins over both while editing.

Two consequences worth knowing before touching this:

- **The selection is what makes a default possible.** "Open the library on its
  first title" cannot be done with links, because there is nothing to write to;
  `selectFirstItemIfNeeded` sets the selection only when one is possible and none
  is chosen, so it cannot overwrite the user's.
- **The detail column builds its own view model,** seeded from
  `ArrServiceManager.calendarViewModel`, exactly as `arrMediaNavigationDestinations`
  does for pushed details. A bare view model starts with an empty library and the
  detail renders "Series Not Found" until its own fetch lands — which is what the
  first version of this did.

**UI tests that match library rows as `app.buttons` will not find them on iPad.**
In selection mode a row is a `Cell`, not a `Button`. `IPadSurfaceCaptureUITests`
matches both for that reason.

## Capture harnesses (assert nothing — do not read as coverage)

`TrawlUITests/IPadSurfaceCaptureUITests.swift` drives the app across its primary
surfaces on an iPad and attaches a screenshot of each. It makes **no assertions**, so
it owns no production surface and must never be cited as coverage for one — "does this
look right at 1376pt" is a judgement call, and an `XCTAssert` spelling of it would be
either vacuous or brittle. It is listed here only so a future reader who finds a UI
test touching Downloads, Series, Movies, Search, More, Settings and four More pushes
does not conclude those screens are covered by it; their real owners are in the
sections above.

Two things it exists to remember, both of which cost a capture run to learn:

- The five root destinations are **`Cell`s in a sidebar** under `.sidebarAdaptable` on
  a wide iPad, not `tabBars.buttons`, and the badged one is labelled `Downloads, 2`, so
  an exact-label match on `Downloads` finds nothing.
- Setting `XCUIDevice.shared.orientation` on a *running* app wedged the chrome so no
  destination ever resolved. Orientation is set before `launch()` instead.

It is not skipped in `Trawl.xctestplan`, and must not be: a plan skip beats
`-only-testing`, which reports `Executed 0 tests` and `TEST SUCCEEDED` together.

```sh
xcodebuild test -project Trawl.xcodeproj -scheme Trawl \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:TrawlUITests/IPadSurfaceCaptureUITests \
  -derivedDataPath /tmp/trawl-ipad-dd -resultBundlePath /tmp/trawl-ipad.xcresult
xcrun xcresulttool export attachments --path /tmp/trawl-ipad.xcresult --output-path ./shots
```

Each attachment's name carries the interface orientation observed at capture time
(`02-series-landscape--landscapeLeft`). That suffix is load-bearing:
`XCUIScreen.main.screenshot()` returns the raw device buffer with landscape content
rotated inside it, so the host has to rotate by a recorded fact rather than an
assumption. `sips -r` is not the tool for that rotation — it records the turn as an
orientation tag rather than baking it into pixels, and the tag survives into the JPEG.

## Validation command shape

Use the explicit simulator and serialized execution for focused and full runs:

```sh
xcodebuild -project Trawl.xcodeproj -scheme Trawl -testPlan Trawl \
  -destination 'platform=iOS Simulator,id=DC6AF1B8-F59F-4610-8F75-4D319567E6F5' \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -derivedDataPath /tmp/trawl-<coverage-stack>-dd \
  -resultBundlePath /tmp/trawl-<coverage-stack>.xcresult \
  -only-testing:<SuiteName> test
```

Every result must be accepted by `python3 Scripts/assert-test-results.py <result bundle>`. An exit code without nonzero test execution is not evidence.

## Shared service availability presentation

| Production surface | Focused coverage to read/run | Current boundary |
|---|---|---|
| `ConnectionStatusCard`, `ServiceErrorView`, `ServiceSetupView`; Sonarr connection recovery, Seerr failed requests, mixed qBittorrent/SABnzbd downloads | `TrawlUITests/ServiceUnavailableJourneyUITests.swift`; `SABnzbdUnauthorizedJourneyUITests.swift` | Real loopback paths prove an unavailable Sonarr exposes server editing, a failed Seerr fetch does not claim an empty inbox and Retry reaches the server, and a failed SABnzbd leaves healthy qBittorrent content visible. Screenshots retain the centered and compact presentations. Other migrated service/admin screens share the renderer; their individual retry operations retain existing service suites. Dynamic Type and every per-service layout are manual visual coverage. |

## Request selection in an iPad detail pane

Native split-view columns contain the detail artwork. `SeerrDashboardView` keys the selected detail by request ID so media loaded for a previous selection cannot remain in view. `ServiceUnavailableJourneyUITests/testRequestSelectionKeepsListUsable` uses the opt-in request responses in `SeerrUIFixtureServer` to open a movie, select a series from the still-usable list, and assert the series response appears. Before the identity fix, the series-detail assertion failed. Full-screen attachments provide visual coverage of artwork containment; XCTest accessibility alone does not detect background overdraw.
