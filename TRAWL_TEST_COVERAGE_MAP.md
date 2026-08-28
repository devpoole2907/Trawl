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
| `Trawl/ArrStack/SonarrSeriesDetailView.swift` | `TrawlUITests/SonarrConnectedJourneyUITests.swift`; `TrawlUITests/ArrRepointJourneyUITests.swift`; `TrawlUITests/ArrInstanceSwitchJourneyUITests.swift`; `TrawlUITests/ArrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Library, repoint, instance switch, add-new, automatic search, and interactive release acquisition assembly are covered. |
| `Trawl/ArrStack/RadarrMovieDetailView.swift` | `TrawlUITests/RadarrJourneyUITests.swift`; `TrawlUITests/RadarrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift`; `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift` | Detail rendering, add-new transition, monitored mutation, automatic search, and interactive release acquisition are covered. |
| `Trawl/ArrStack/SonarrViewModel.swift`, `RadarrViewModel.swift`, `ArrLibraryViewModel.swift` | `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlTests/ArrLibraryCacheTests.swift`; `TrawlTests/ArrRepointLibraryReloadTests.swift` | Current-client resolution, cache invalidation and repoint behavior. |
| `Trawl/ArrStack/ArrServiceManager.swift` | `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlTests/ArrRetryDisconnectedTests.swift`; `TrawlTests/ArrWebhookNotificationManagerTests.swift` | Multi-instance lifecycle, reconnect/retry and notification manager routing. |
| `ArrAPIClient.deleteQueueItem` and `ArrLibraryViewModel.removeQueueItem` — queue removal and blocklisting | `TrawlTests/ArrAPIClientContractTests.swift` (Sonarr suite, "Queue deletion"); `TrawlTests/ArrQueueRemovalTests.swift` | The most destructive call in the app: both "delete the download from disk" and "blocklist this release forever" ride on query flags, so the exact `removeFromClient`/`blocklist` pairs are pinned per caller intent. Flipping either default fails these. The view-model half pins that the on-screen queue cannot lie: a rejected removal keeps the row and surfaces the error, and an accepted one drops only that item. Making the removal optimistic fails it. |
| `SonarrAPIClient.deleteSeries` and `QBittorrentAPIClient.deleteTorrents` — the two calls that can erase media from disk | `TrawlTests/ArrAPIClientContractTests.swift` (Sonarr suite, "Series deletion"); `TrawlTests/QBittorrentAPIClientContractTests.swift` ("Torrent deletion") | `deleteFiles` decides whether files on disk go, and is always sent explicitly. Sonarr expresses `addImportListExclusion: false` by *omitting* it. qBittorrent joins hashes with a pipe — a comma sends one unrecognised hash, so nothing is deleted and the app still reports success. |
| `Trawl/ArrStack/ArrSetupSheet.swift`, `ArrSetupViewModel.swift` | `TrawlTests/ArrSetupViewModelTests.swift`; `TrawlUITests/ArrSetupEditJourneyUITests.swift`; `TrawlUITests/ArrAddInstanceJourneyUITests.swift`; `TrawlUITests/ArrRepointJourneyUITests.swift` | A rejected API key shows the exact production error, keeps the editor open and repoints nothing; the corrected retry persists and reconnects. One Sonarr journey covers the family — every Arr service presents this same editor and takes the same `validateAndSave` path. The **add** path is unit-covered separately, because it is different code from editing: it inserts rather than mutates, unwinds via `modelContext.rollback()` plus a Keychain delete rather than field restore, and adopts the existing profile for Prowlarr instead of inserting a second. Changing `unauthorizedStatusCodes`, the Prowlarr branch, or the add branch's `modelContext.insert` fails these tests by design. The sheet's service-type picker is unreachable from the app (N-06) and is deliberately uncovered. A cancelled attempt must report no error (N-05); `TrawlTests/UnansweringServer.swift` is the shared loopback server that keeps a request in flight while the task is cancelled. |
| `Trawl/ArrStack/ArrCalendarView.swift` | `TrawlTests/ArrCalendarConcurrencyTests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift` | Overlap/profile ordering plus basic assembly. |
| `Trawl/ArrStack/AddImportLocationAndScanViewModel.swift` and import views | `TrawlTests/LibraryImportScanViewModelTests.swift`; `TrawlUITests/LibraryImportScanJourneyUITests.swift` | Scan/group/identify flow and no-premature-import boundary. |

## Download clients and transport

| Production surface | Focused coverage to read/run |
|---|---|
| `Trawl/Services/HTTP/HTTPTransport.swift` | `TrawlTests/HTTPTransportContractTests.swift` |
| `Trawl/Services/QBittorrentAPIClient.swift`, `AuthService.swift` | `TrawlTests/QBittorrentAPIClientContractTests.swift`; `TrawlTests/QBittorrentReauthContractTests.swift` |
| `Trawl/Services/SyncService.swift` | `TrawlTests/SyncServiceConcurrencyTests.swift` |
| qBittorrent setup/edit and download actions | `TrawlUITests/ServiceSetupEditJourneyUITests.swift`; `TrawlUITests/DownloadsJourneyUITests.swift` |
| `Trawl/SABnzbdStack/SABnzbdAPIClient.swift` | `TrawlTests/SABnzbdAPIClientContractTests.swift` |
| `Trawl/SABnzbdStack/SABnzbdServiceManager.swift` | `TrawlTests/SABnzbdServiceManagerConcurrencyTests.swift`; `TrawlTests/SABnzbdProfileSwitchTests.swift` |
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
| `Trawl/SeerrStack/SeerrAPIClient.swift` and Seerr view models | `TrawlTests/SeerrContractTests.swift`; the matching `TrawlTests/Seerr*ViewModelTests.swift` suites |
| `Trawl/ArrStack/BazarrViewModel.swift` | `TrawlTests/BazarrViewModelTests.swift` |
| `BazarrAPIClient.saveEnabledProviders` — the enabled subtitle-provider set | `TrawlTests/BazarrProviderSaveTests.swift` |
| `BazarrAPIClient.saveLanguageProfiles` and `saveEnabledLanguages` — whole-collection replaces | `TrawlTests/BazarrLanguageProfileSaveTests.swift` |
| Prowlarr management/search state | `TrawlTests/Prowlarr*StateTests.swift`; `TrawlTests/ArrIndexerManagementViewModelTests.swift` |

## App assembly, settings and notifications

| Production surface | Focused coverage to read/run |
|---|---|
| `Trawl/Views/ContentView.swift`, root environment injection and tab navigation | `TrawlUITests/NavigationSmokeWalkUITests.swift`; `TrawlUITests/TrawlUITests.swift`; `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| `Trawl/Utilities/NavigationDismissalGestures.swift` and notification-sheet presentation | `TrawlUITests/RecentNotificationsJourneyUITests.swift` | The notification sheet's real content/presentation is covered. A dedicated gesture-conflict regression should accompany future changes to the runtime recognizer matching. |
| More/Settings destinations and service removal | `TrawlUITests/MoreSettingsBreadthUITests.swift`; `TrawlUITests/ServiceRemovalJourneyUITests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift` |
| Arr notification webhook management | `TrawlTests/ArrWebhookNotificationManagerTests.swift`; `TrawlUITests/NotificationSettingsJourneyUITests.swift` |
| Recent notification history and clearing | `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| Onboarding persistence and validation, including cancellation (N-05): a cancelled attempt must return promptly and report nothing, and `AuthService.propagatesCancellation` stays opt-in so the shared re-auth instance keeps coalescing | `TrawlTests/OnboardingViewModelTests.swift`; the relevant setup/edit UI journey |
| Share input classification and termination | `TrawlTests/ShareExtensionInputTests.swift` |
| Widget refresh policy (including the Seerr Inbox and small-calendar countdown cadences), calendar day-sequencing, calendar scope and failure headlines, Seerr widget decoding and display fallbacks, lock-screen accessory formatting and gauge fractions, the Seerr Inbox deep-link target, and the blended qBittorrent + SABnzbd pause state behind the Control Center control; extension registration, installed-widget presence, `trawl://downloads` handoff, and Home Screen cleanup | `TrawlTests/WidgetTimelineAndDataTests.swift`; `TrawlUITests/WidgetInstalledProcessUITests.swift` | The unit suite compiles the exact pure sources the extension uses — `WidgetTimelinePolicy`, `WidgetFetchError`, `WidgetSeerrModels`, `WidgetGlanceFormatter`, `DownloadControlState`, `CalendarScopeOption` — so there is no copied implementation and no altered actor isolation. Every widget refresh interval must be added to `WidgetTimelinePolicy` and asserted here rather than inlined in a provider; each interval was proven load-bearing by perturbing the production value and observing the matching expectation fail. `DownloadControlState` is the one place that answers "are downloads running?" across both clients, so a control that silently reverts to qBittorrent-only would fail `soleLiveSAB.isRunning`. The UI journey is the installed-process boundary: SpringBoard discovers the embedded extension, the gallery renders an installable preview, the widget is added to the Home Screen, and tapping it opens the host app. It asserts only on SpringBoard-owned elements: widget content is rendered by `com.apple.chrono.WidgetRenderer` and is unreachable from XCTest, so the installed widget is identified by its icon carrying `value: Widget`, which the app icon does not have. It proves one representative widget kind because all five widgets and the Control Center control ship in one `WidgetBundle`; per-kind data fetches, lock-screen accessory rendering, Control Center toggle behaviour and physical-device refresh scheduling remain release smoke-test work. Async teardown restores the exact pre-test Trawl-widget count and refuses to remove anything if setup failed before that count was captured, preventing repeated runs from accumulating Home Screen state and crash-looping PosterBoard. |
| Arr media-file deletion request/state ownership and single-source user feedback — `SonarrViewModel.deleteEpisodeFile`, `RadarrViewModel.deleteMovieFile` | `TrawlTests/ArrMediaFileDeletionTests.swift` | Drives the real view models against loopback fixture servers and pins the exact authenticated `DELETE /api/v3/episodefile/{id}` and `DELETE /api/v3/moviefile/{id}`. The behavioural assertion is that the view model owns request/state/error while the presenting view owns the one banner: the view models must not announce, or the user sees two. When changing feedback here, check every caller — `SonarrSeriesDetailView`, `SonarrSeriesSearchViews`, `RadarrMovieDetailView` — all three announce. |

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
