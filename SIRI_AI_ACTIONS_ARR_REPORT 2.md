# Trawl Siri AI Actions / *arr App Intents Research Report

Audience: James, Codex, Claude Code
Project: `/mnt/ios-projects/Trawl`

## Executive summary

Trawl is already a strong candidate for Siri AI / App Intents integration because it has SwiftUI + SwiftData, App Group storage, existing AppIntents in widgets, and typed clients for Radarr, Sonarr, Prowlarr, Bazarr, Seerr, Jellyfin, and qBittorrent.

The best implementation path is not to expose Hermes MCP directly to Siri. Add native App Intents inside Trawl that call the existing `RadarrAPIClient`, `SonarrAPIClient`, and `ProwlarrAPIClient` using saved Trawl service profiles and Keychain API keys.

First useful Siri AI action set:

1. Search Radarr for a movie.
2. Add a movie to Radarr with safe defaults.
3. Search Sonarr for a TV series.
4. Add a series to Sonarr with safe defaults.
5. Search Prowlarr indexers.
6. Show Radarr/Sonarr queue.
7. Show upcoming Radarr/Sonarr calendar items.
8. Trigger search for an already-added movie / series / episode.
9. Show health/status for configured *arr services.

Avoid destructive/admin Siri v1 actions: delete movie/series/files/queue items, backup restore, naming updates, quality-profile edits, root-folder changes, download-client edits, and indexer edits.

## Apple WWDC26 / iOS 27 Siri AI findings

Apple's WWDC26 docs label the platform guide as "What's new in iOS 27". Siri AI integration is built around App Intents, App Entities, App Enums, App Schemas, Spotlight indexing, donations, and onscreen context.

Primary Apple references checked:

- https://developer.apple.com/wwdc26/guides/ios/
- https://developer.apple.com/wwdc26/guides/apple-intelligence/
- https://developer.apple.com/documentation/appintents
- https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai
- https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence
- https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri
- https://developer.apple.com/documentation/appintents/donating-your-apps-data-and-actions-to-the-system
- https://developer.apple.com/videos/play/wwdc2026/240/
- https://developer.apple.com/videos/play/wwdc2026/343/
- https://developer.apple.com/videos/play/wwdc2026/344/
- https://developer.apple.com/videos/play/wwdc2026/345/

Relevant Apple points:

- App Intents make app actions and data discoverable to Apple Intelligence, Siri, Spotlight, Shortcuts, widgets, controls, Live Activities, Action Button, and related system surfaces.
- Siri AI uses `AppIntent`, `AppEntity`, and `AppEnum` definitions to understand actions and content.
- Entity schemas contribute app content to Spotlight's semantic index so Siri can find content even from vague descriptions.
- Intent schemas let users act naturally without the old brittle phrase-specific Siri model.
- App Schemas are the Siri AI contract layer: they help Apple Intelligence identify, query, and understand actions/content.
- Siri AI readiness steps Apple calls out: index entities for Spotlight, choose transferable types where needed, adopt schemas where available, associate visible views/user activities with app entities for onscreen context, and donate actions/content.
- WWDC26 introduces/expands View Annotations so users can refer to visible content conversationally, e.g. "add this" or "search for this show".
- App Intents Testing validates integrations through real system pathways without UI automation.

Limitation for Trawl:

I did not find a direct first-party *arr / torrent / movie-request management schema. There are media-related schema areas such as Photos and Music, plus domains for files, mail, calendar, messages, etc. Trawl should mostly use custom App Intents and custom App Entities, with Apple schema adoption only if Xcode docs show a genuinely matching schema. Do not force-fit Radarr/Sonarr into Photos/Music schemas.

## Current Trawl state

Repo root: `/mnt/ios-projects/Trawl`

Agent/build docs:

- `/mnt/ios-projects/Trawl/CLAUDE.md`
- `/mnt/ios-projects/Trawl/AGENTS.md`

Important project rules from those docs:

- SwiftUI + Swift 6 strict concurrency.
- Targets: `Trawl`, `TrawlMac`, `TrawlShare`, `TrawlWidgets`.
- Source is in `Trawl/Trawl/`.
- Xcode synchronized folder references are used.
- New Swift files are automatically compiled into targets unless excluded in `project.pbxproj` membership exceptions.
- New main-app-only ArrStack files must be excluded from TrawlShare and TrawlWidgets if they depend on main-app-only types.

Existing App Intents usage:

- `TrawlWidgets/SpeedWidget/SelectServerIntent.swift`
- `TrawlWidgets/CalendarWidget/SelectCalendarScopeIntent.swift`
- `TrawlWidgets/SeerrWidgets/SelectSeerrServerIntent.swift`
- Widgets use `AppIntentTimelineProvider` and `WidgetConfigurationIntent`.

Existing storage:

- `Trawl/TrawlApp.swift` creates a SwiftData `ModelContainer` with App Group configuration using `AppGroup.identifier`.
- `Trawl/Models/TrawlModelSchema.swift` includes `ServerProfile`, `CachedTorrentState`, `RecentSavePath`, `ArrServiceProfile`, `SeerrServiceProfile`, and `JellyfinServiceProfile`.
- `ArrServiceProfile` stores *arr profile metadata in SwiftData and API keys in Keychain.
- `KeychainHelper` uses service `com.poole.james.Trawl` and an access group based on `AppIdentifierPrefix + com.poole.james.Trawl.shared`.

Existing *arr service model:

- `ArrServiceProfile` supports `sonarr`, `radarr`, `prowlarr`, and `bazarr`.
- Fields include display name, host URL, service type, enabled flag, API version, import folders, and Keychain key for API key.
- `ArrServiceManager` coordinates multi-instance Sonarr/Radarr/Bazarr and single active Prowlarr.

## Existing Trawl API coverage

Radarr client: `Trawl/Trawl/ArrStack/RadarrAPIClient.swift`

- Get all movies, get movie by id, lookup by term/TMDb/IMDb, add movie, update movie, delete movie, movie files, calendar, iCal/webcal, releases, grab release, wanted/missing, refresh movie, search movie, rename files, search all missing, RSS sync, install update.

Sonarr client: `Trawl/Trawl/ArrStack/SonarrAPIClient.swift`

- Get all series, get series by id, lookup by term/TVDB, add series, update series, delete series, episodes, episode monitor, episode files, calendar, iCal/webcal, releases, grab release, wanted/missing, refresh series, search episodes/season/series, rename files, search all missing, RSS sync, install update.

Prowlarr client: `Trawl/Trawl/ArrStack/ProwlarrAPIClient.swift`

- Test all indexers, sync applications, search indexers, indexer stats/statuses, applications CRUD/test, indexer proxies CRUD/test, app profiles, tags.

Shared *arr client: `Trawl/Trawl/ArrStack/ArrAPIClient.swift`

- System status, health, quality profiles CRUD, root folders CRUD, filesystem browser, tags, notifications CRUD/test, queue, history, logs, disk space, backups, updates, download clients, remote path mappings, blocklist, import list exclusions, manual import, naming config, indexers, quality definitions, scheduled tasks, command queue, post command and wait.

## MCP-arr comparison

Local MCP-arr service status observed:

- Sonarr configured and connected, version `4.0.17.2952`.
- Radarr configured and connected, version `6.1.1.10360`.
- Prowlarr configured and connected, version `2.3.5.5327`.
- Lidarr not configured.

Radarr setup observed through MCP:

- Root folder: `/data/Movies`.
- Quality profiles: `Any` id 1, `HD-720p` id 3, `HD-1080p` id 4, `Ultra-HD` id 5, `HD - 720p/1080p` id 6.
- Download client: qBittorrent torrent client enabled.
- Indexers from Prowlarr: 1337x, Knaben, The Pirate Bay.
- Health warning: update available.

Sonarr setup observed through MCP:

- Root folder: `/data/TV Shows`.
- Quality profiles: `Any` id 1, `SD` id 2, `HD-720p` id 3, `HD-1080p` id 4, `Ultra-HD` id 5, `HD - 720p/1080p` id 6.
- Download client: qBittorrent torrent client enabled.
- Indexers from Prowlarr: 1337x, EZTV, Knaben, LimeTorrents, The Pirate Bay.
- Health warning: update available.

MCP-arr tools worth mirroring in Siri v1:

Read/search:

- `arr_status`
- `arr_search_all`
- `radarr_search`
- `sonarr_search`
- `prowlarr_search`
- `radarr_get_movies`
- `sonarr_get_series`
- `sonarr_get_episodes`
- `radarr_get_calendar`
- `sonarr_get_calendar`
- `radarr_get_queue`
- `sonarr_get_queue`
- `radarr_get_health`
- `sonarr_get_health`
- `prowlarr_get_indexers`
- `prowlarr_get_stats`

Mutating but useful:

- `radarr_add_movie`
- `sonarr_add_series`
- `radarr_search_movie`
- `sonarr_search_episode`
- `sonarr_search_missing`
- `sonarr_refresh_series`
- `radarr_refresh_movie`

Do not mirror in Siri v1:

- Backup restore.
- Delete movie/series/files/queue/blocklist/root folders/indexers/download clients.
- Quality profile or naming updates.
- Infrastructure/configuration actions.

## Recommended Siri/App Intents architecture

Add a folder:

- `Trawl/Trawl/ArrStack/AppIntents/`

Suggested files:

- `ArrIntentSupport.swift`
- `ArrIntentErrors.swift`
- `ArrServiceEntity.swift`
- `ArrMovieEntity.swift`
- `ArrSeriesEntity.swift`
- `ArrEpisodeEntity.swift`
- `ArrReleaseEntity.swift`
- `ArrQueueItemEntity.swift`
- `SearchRadarrMoviesIntent.swift`
- `AddRadarrMovieIntent.swift`
- `SearchSonarrSeriesIntent.swift`
- `AddSonarrSeriesIntent.swift`
- `SearchProwlarrIntent.swift`
- `ShowArrQueueIntent.swift`
- `ShowArrCalendarIntent.swift`
- `SearchExistingArrItemIntent.swift`
- `ArrShortcutsProvider.swift`

Key design points:

- Keep intents independent of `ArrServiceManager` initially. It is `@MainActor` and UI-oriented. Siri intents should use a small resolver that reads `ArrServiceProfile` from SwiftData and API keys from Keychain, then constructs clients directly.
- Prefer read/add/search actions first.
- For add actions, use safe defaults from selected/first active profile:
  - Radarr: root folder from API root folders, default quality profile preferably `HD-1080p`, `monitored = true`, `minimumAvailability = released` unless James prefers otherwise.
  - Sonarr: root folder from API root folders, default quality profile preferably `HD-1080p`, `monitored = true`, `seasonFolder = true`, series type `standard` unless specified.
- Do not hardcode `/data/Movies` or `/data/TV Shows`; use live root folder endpoints. MCP values are examples only.
- Use `@Parameter` with human-friendly names for queries, service selection, quality, root folder, and monitor options.
- Return clear dialogs, e.g. "Added Dune: Part Two to Radarr using HD-1080p in /data/Movies and started a search.".
- Where ambiguity exists, return candidates rather than guessing.
- Donate successful add/search actions so Siri learns relevance.
- Add App Shortcuts for explicit phrases even though Siri AI should understand schemas better than fixed phrases.

Potential AppEntity strategy:

- `ArrServiceEntity`: configured Sonarr/Radarr/Prowlarr instance. Identifier: profile UUID.
- `ArrMovieEntity`: Radarr movie or lookup result. Identifier: service UUID + Radarr id or TMDb fallback.
- `ArrSeriesEntity`: Sonarr series or lookup result. Identifier: service UUID + Sonarr id or TVDB/TVMaze fallback.
- `ArrEpisodeEntity`: Sonarr episode id + series title/season/episode.
- `ArrReleaseEntity`: release guid/indexer id for short-lived interactive grabbing only; do not Spotlight-index release results.

Spotlight indexing:

- Good candidates: existing library movies, existing library series, configured services.
- Maybe candidates: calendar items and wanted items, but donate rather than permanently index because they are time-sensitive.
- Bad candidates: raw Prowlarr release results, queue items, logs.

View annotations:

- Phase 2/4: annotate movie rows, series rows, detail pages, wanted rows, and calendar rows so users can say "search for this", "refresh this", or "add this" while looking at Trawl.

## Concrete v1 intent map

### SearchRadarrMoviesIntent

Examples:

- "Ask Trawl to search Radarr for Dune Part Two."
- "Find the movie The Matrix in Trawl."

Implementation:

- Input: search term, optional Radarr service.
- Resolve service profile and API key.
- Call `RadarrAPIClient.lookupMovie(term:)`.
- Return top candidates.

### AddRadarrMovieIntent

Examples:

- "Ask Trawl to add Dune Part Two to Radarr."
- "Add Oppenheimer in Trawl and search for it."

Implementation:

- Input: movie entity/title, optional service, optional quality profile, optional root folder, optional `startSearch`.
- If title-only, lookup and choose only if one confident candidate; otherwise return candidates.
- Build `RadarrAddMovieBody` using existing models.
- Call `addMovie`.
- If requested, call `searchMovie(movieIds:)`.

### SearchSonarrSeriesIntent

Examples:

- "Ask Trawl to search Sonarr for Severance."
- "Find the TV show Slow Horses in Trawl."

Implementation:

- Input: search term, optional Sonarr service.
- Call `SonarrAPIClient.lookupSeries(term:)`.
- Return top candidates.

### AddSonarrSeriesIntent

Examples:

- "Ask Trawl to add Severance to Sonarr."
- "Add The Bear to Sonarr and search missing episodes."

Implementation:

- Input: series entity/title, optional service, optional quality profile, optional root folder, optional season folder, optional monitor/search flag.
- Call `addSeries`.
- Optionally `searchSeries(seriesId:)`.

### SearchProwlarrIntent

Examples:

- "Ask Trawl to search Prowlarr for Ubuntu."
- "Search indexers for Blade Runner 2049."

Implementation:

- Input: query, optional categories, optional limit.
- Call `ProwlarrAPIClient.search(query:limit:)`.
- Return top results with indexer/title/size/seeders if available.

### ShowArrQueueIntent

Examples:

- "What's downloading in Trawl?"
- "Show my Radarr queue."

Implementation:

- Input: service type Radarr/Sonarr/all.
- Call shared `getQueue` on active clients.
- Return concise queue summary.

### ShowArrCalendarIntent

Examples:

- "What's coming up in Sonarr?"
- "What movies are releasing soon in Trawl?"

Implementation:

- Input: service type and day range.
- Call Radarr/Sonarr calendar endpoints.
- Return next items.

### SearchExistingArrItemIntent

Examples:

- "Search for this movie in Radarr."
- "Search missing episodes for this series."

Implementation:

- Input: movie/series/episode entity.
- Movie: `searchMovie(movieIds:)`.
- Series: `searchSeries(seriesId:)` or `searchSeason` if season provided.
- Episode: `searchEpisodes(episodeIds:)`.

## Build/target warnings for Codex and Claude

New files in `Trawl/Trawl/ArrStack/AppIntents/` will probably be picked up by the main app, TrawlShare, and TrawlWidgets unless explicitly excluded.

Because these App Intents will likely use SwiftData, Keychain, and main-app service types, exclude them from `TrawlShare` and probably `TrawlWidgets` at first.

Update `Trawl.xcodeproj/project.pbxproj` membership exceptions:

- Add new AppIntents Swift files to the TrawlShare exception list (`CCB00000CCB00000CCB00000`) unless intentionally supported by the share extension.
- Add new AppIntents Swift files to the TrawlWidgets exception list (`FFB00000FFB00000FFB00000`) unless intentionally supported by the widget extension.

For v1, simplest target shape is main app only.

## Testing recommendations

Minimum tests:

- Unit test service resolver with fake SwiftData profiles / fake Keychain lookup if feasible.
- Unit test intent input validation and default selection logic.
- Use Apple's App Intents Testing framework for real intent execution paths once available in the local Xcode toolchain.
- Verify from Shortcuts first, then Siri.
- Verify on device because Keychain access groups and Siri behavior are device-sensitive.

Manual test script:

1. Build Trawl main app.
2. Confirm existing Radarr/Sonarr/Prowlarr profiles are configured in Trawl.
3. Open Shortcuts and verify Trawl actions appear.
4. Run search-only actions.
5. Run add action with a harmless test item only if James approves.
6. Confirm result in Trawl UI and service web UI.
7. Trigger Siri voice phrases after Shortcuts works.

## Suggested implementation phases

Phase 0: Xcode documentation check

- Use Xcode documentation search for iOS 27 App Intents APIs before coding exact syntax.
- Confirm names and availability for App Schemas, View Annotations, App Intents Testing, `IndexedEntity`, donation APIs, and media schemas.

Phase 1: Native App Intents foundation

- Add `ArrIntentSupport.swift` with service profile loading and API client construction.
- Add `ArrIntentErrors.swift`.
- Add `ArrServiceEntity` and service entity query.
- Add `SearchRadarrMoviesIntent` and `SearchSonarrSeriesIntent` only.
- Build and verify Shortcuts discovery.

Phase 2: Add actions

- Add `AddRadarrMovieIntent`.
- Add `AddSonarrSeriesIntent`.
- Keep defaults simple and safe.
- Add optional `startSearch` parameter.
- Build and test with non-destructive search first, then one approved add.

Phase 3: Status/read tools

- Add queue, calendar, health/status, and Prowlarr search intents.
- Return concise summaries, not huge lists.

Phase 4: Entity indexing and onscreen context

- Index existing Radarr movies and Sonarr series in Spotlight.
- Add view annotations to relevant SwiftUI rows/detail views if the API supports SwiftUI directly or via collection/table data-source bridging.
- Donate successful actions.

Phase 5: Advanced MCP parity

- Add refresh/search-missing commands.
- Consider manual release grabbing only if the UI/voice confirmation flow is excellent.
- Avoid destructive admin/config actions unless explicitly requested.

## Open questions before coding

1. Does James want Siri to directly add media without confirmation, or should add actions always present/require confirmation first?
2. Should default Radarr minimum availability be `released`, `inCinemas`, or `announced`?
3. Should default quality be `HD-1080p` or `HD - 720p/1080p`?
4. Should Siri actions target only the active Trawl service profile, or allow selecting among all profiles?
5. Should Prowlarr search be exposed as a general indexer search, or only as a behind-the-scenes fallback for Radarr/Sonarr actions?

## Bottom line

The right build is a native App Intents layer inside Trawl, backed by existing Trawl API clients and stored service profiles. Start with search/add/status actions and avoid destructive admin/config operations. Treat Apple's App Schemas as the Siri AI discovery layer, but do not force schema adoption unless a matching schema exists in Xcode docs. Codex/Claude should begin by adding a small AppIntents folder, a service resolver, service/movie/series entities, and two search intents, then build before expanding to add actions.
