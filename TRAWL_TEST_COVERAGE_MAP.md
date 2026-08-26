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
| `Trawl/ArrStack/ArrReleaseActionContent.swift` | `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Request/response, stale-client routing, release rendering, selection, grab payload, success feedback, and dismissal are covered for Sonarr and Radarr. |
| `Trawl/ArrStack/SonarrSeriesSearchViews.swift` | `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlUITests/ArrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | New-series add plus existing-series Automatic Search and Interactive Search → Download Release are covered end to end. |
| `Trawl/ArrStack/RadarrMovieSearchViews.swift` | `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlUITests/RadarrJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Detail rendering and existing-movie Automatic/Interactive acquisition are covered. Add-new movie remains open. |
| `Trawl/ArrStack/SonarrSeriesDetailView.swift` | `TrawlUITests/SonarrConnectedJourneyUITests.swift`; `TrawlUITests/ArrRepointJourneyUITests.swift`; `TrawlUITests/ArrInstanceSwitchJourneyUITests.swift`; `TrawlUITests/ArrSearchAddJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift` | Library, repoint, instance switch, add-new, automatic search, and interactive release acquisition assembly are covered. |
| `Trawl/ArrStack/RadarrMovieDetailView.swift` | `TrawlUITests/RadarrJourneyUITests.swift`; `TrawlUITests/ArrReleaseAcquisitionJourneyUITests.swift`; `TrawlTests/ArrAPIClientContractTests.swift`; `TrawlTests/ArrClientLifecycleTests.swift` | Detail rendering, monitored mutation, automatic search, and interactive release acquisition are covered. |
| `Trawl/ArrStack/SonarrViewModel.swift`, `RadarrViewModel.swift`, `ArrLibraryViewModel.swift` | `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlTests/ArrLibraryCacheTests.swift`; `TrawlTests/ArrRepointLibraryReloadTests.swift` | Current-client resolution, cache invalidation and repoint behavior. |
| `Trawl/ArrStack/ArrServiceManager.swift` | `TrawlTests/ArrClientLifecycleTests.swift`; `TrawlTests/ArrRetryDisconnectedTests.swift`; `TrawlTests/ArrWebhookNotificationManagerTests.swift` | Multi-instance lifecycle, reconnect/retry and notification manager routing. |
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
| Jellyfin library administration | `TrawlUITests/JellyfinLibrariesJourneyUITests.swift`; `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| `Trawl/SeerrStack/SeerrAPIClient.swift` and Seerr view models | `TrawlTests/SeerrContractTests.swift`; the matching `TrawlTests/Seerr*ViewModelTests.swift` suites |
| `Trawl/ArrStack/BazarrViewModel.swift` | `TrawlTests/BazarrViewModelTests.swift` |
| Prowlarr management/search state | `TrawlTests/Prowlarr*StateTests.swift`; `TrawlTests/ArrIndexerManagementViewModelTests.swift` |

## App assembly, settings and notifications

| Production surface | Focused coverage to read/run |
|---|---|
| `Trawl/Views/ContentView.swift`, root environment injection and tab navigation | `TrawlUITests/NavigationSmokeWalkUITests.swift`; `TrawlUITests/TrawlUITests.swift`; `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| `Trawl/Utilities/NavigationDismissalGestures.swift` and notification-sheet presentation | `TrawlUITests/RecentNotificationsJourneyUITests.swift` | The notification sheet's real content/presentation is covered. A dedicated gesture-conflict regression should accompany future changes to the runtime recognizer matching. |
| More/Settings destinations and service removal | `TrawlUITests/MoreSettingsBreadthUITests.swift`; `TrawlUITests/ServiceRemovalJourneyUITests.swift`; `TrawlUITests/NavigationSmokeWalkUITests.swift` |
| Arr notification webhook management | `TrawlTests/ArrWebhookNotificationManagerTests.swift`; `TrawlUITests/NotificationSettingsJourneyUITests.swift` |
| Recent notification history and clearing | `TrawlUITests/RecentNotificationsJourneyUITests.swift` |
| Onboarding persistence and validation | `TrawlTests/OnboardingViewModelTests.swift`; the relevant setup/edit UI journey |
| Share input classification and termination | `TrawlTests/ShareExtensionInputTests.swift` |

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
