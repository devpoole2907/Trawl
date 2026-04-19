# Trawl — Arr Stack Integration Guide (for Claude Code / Sonnet)

> **Context**: Trawl is an existing, functioning iOS 26 qBittorrent remote client.
> These files add Sonarr and Radarr integration. Your job is to place these files
> into the correct locations, register the new SwiftData model, wire up navigation,
> and inject the ArrServiceManager into the environment.

NOTE:

Some of this document may be incorrect. The application was planned and created by Opus, then Sonnet in Claude Code implemented. Then Opus built this new plan upon its initial plan. Sonnet and myself may have made changes to the codebase that dont necessarily align with the document here. Your job is to integrate it cleanly and smoothly with the existing codebase, naturally.

---

## Hard Constraints (unchanged from the existing codebase)

1. **iOS 26 only.** No `#available` checks.
2. **`@Observable` only.** No ObservableObject, @Published, @StateObject, @ObservedObject.
3. **No Combine.** Zero `import Combine`.
4. **No DispatchQueue.** All concurrency via async/await, Actor, Task.
5. **SwiftData for persistence.** The new `ArrServiceProfile` model must be registered.
6. **Keychain for secrets.** API keys stored via the existing `KeychainHelper`.
7. **No UIKit** in views. THIS IS NOT ESSENTIAL BUT SWIFTUI IS PREFERRED. IF UIKIT IS NEEDED, CONSULT THE USER.

---

## New Files to Integrate

All files are in the `ArrStack/` directory. Place them into the Xcode project
maintaining this structure:

```
Trawl/
├── (existing files unchanged)
├── ArrStack/
│   ├── Models/
│   │   ├── Shared/
│   │   │   ├── ArrServiceProfile.swift      ← SwiftData @Model + ArrServiceType enum
│   │   │   └── ArrSharedModels.swift         ← Shared Codable types + ArrError
│   │   ├── Sonarr/
│   │   │   └── SonarrModels.swift            ← Series, Episode, Season models
│   │   └── Radarr/
│   │       └── RadarrModels.swift            ← Movie, Collection models
│   ├── Services/
│   │   ├── ArrAPIClient.swift                ← Base actor: HTTP + shared endpoints
│   │   ├── SonarrAPIClient.swift             ← Sonarr-specific actor
│   │   ├── RadarrAPIClient.swift             ← Radarr-specific actor
│   │   └── ArrServiceManager.swift           ← @Observable service coordinator
│   ├── ViewModels/
│   │   ├── SonarrViewModel.swift             ← Series library + episodes + search
│   │   ├── RadarrViewModel.swift             ← Movie library + search
│   │   └── ArrSetupViewModel.swift           ← Add/edit service connections
│   └── Views/
│       ├── Shared/
│       │   ├── ArrSetupSheet.swift           ← Add Sonarr/Radarr modal
│       │   ├── ArrActivityView.swift         ← Unified download queue
│       │   └── ArrServicesSettingsView.swift  ← Manage service connections
│       ├── Sonarr/
│       │   ├── SonarrSeriesListView.swift    ← Main series list
│       │   ├── SonarrSeriesDetailView.swift  ← Series detail + episodes
│       │   └── SonarrAddSeriesSheet.swift    ← Search + add series
│       └── Radarr/
│           ├── RadarrMovieListView.swift      ← Main movie list
│           ├── RadarrMovieDetailView.swift    ← Movie detail
│           └── RadarrAddMovieSheet.swift      ← Search + add movies
```

---

## Integration Steps

### 1. Register ArrServiceProfile in SwiftData

In `TrawlApp.swift`, add `ArrServiceProfile.self` to the schema:

```swift
let schema = Schema([
    ServerProfile.self,
    CachedTorrentState.self,
    RecentSavePath.self,
    ArrServiceProfile.self          // ← ADD THIS
])
```

### 2. Create and Inject ArrServiceManager

In `TrawlApp.swift` or `ContentView.swift`, create the `ArrServiceManager` and
inject it into the environment. It needs to be initialized early and connected
to any saved `ArrServiceProfile` entries.

**Option A — In TrawlApp (recommended):**

```swift
@main
struct TrawlApp: App {
    let modelContainer: ModelContainer
    @State private var arrServiceManager = ArrServiceManager()

    // ... existing init ...

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(arrServiceManager)
        }
        .modelContainer(modelContainer)
    }
}
```

Then in `ContentView.swift`, add a `.task` that loads and connects Arr services:

```swift
@Environment(ArrServiceManager.self) private var arrServiceManager
@Query private var arrProfiles: [ArrServiceProfile]

// In .task or .onAppear:
await arrServiceManager.initialize(from: arrProfiles)
```

### 3. Add Tab-Based Navigation
Note the app already has tab nav, this is out of date info but still helpful context
The app currently shows `TorrentListView` as the root. Convert to a `TabView`:

```swift
TabView {
    // Existing torrent list (wrap in NavigationStack if not already)
    TorrentListView()
        .environment(services.syncService)
        .environment(services.torrentService)
        .tabItem {
            Label("Downloads", systemImage: "arrow.down.circle")
        }

    // Sonarr tab
    SonarrSeriesListView()
        .environment(arrServiceManager)
        .tabItem {
            Label("Series", systemImage: "tv")
        }

    // Radarr tab
    RadarrMovieListView()
        .environment(arrServiceManager)
        .tabItem {
            Label("Movies", systemImage: "film")
        }

    // Activity tab (unified queue)
    ArrActivityView()
        .environment(arrServiceManager)
        .tabItem {
            Label("Activity", systemImage: "arrow.down.doc")
        }
}
```

### 4. Add Arr Services to Settings

In the existing `SettingsView.swift`, add a NavigationLink to the Arr services
management view:

```swift
Section("Arr Services") {
    NavigationLink {
        ArrServicesSettingsView()
            .environment(arrServiceManager)
    } label: {
        Label("Sonarr & Radarr", systemImage: "server.rack")
    }
}
```

### 5. Ensure Environment Propagation

Every Arr view reads `@Environment(ArrServiceManager.self)`. Make sure the
`.environment(arrServiceManager)` modifier is applied high enough in the view
hierarchy that all Arr views can access it. The TabView level is ideal.

The Arr views do NOT depend on `SyncService` or `TorrentService` — they are
fully independent. The only shared dependency is `KeychainHelper` (which is
already a global actor singleton) and `ByteFormatter` (a pure utility enum).

---

## Architecture Notes

### Auth Model
- **qBittorrent** (existing): Cookie-based SID auth, managed by `AuthService` actor
- **Sonarr/Radarr** (new): API key auth via `X-Api-Key` header, much simpler
- API keys stored in Keychain using `KeychainHelper.shared` with key pattern
  `arr_{uuid}_apikey`

### Service Graph
```
ArrServiceManager (@Observable, injected via .environment)
├── SonarrAPIClient (actor)
│   └── ArrAPIClient (actor, base HTTP)
└── RadarrAPIClient (actor)
    └── ArrAPIClient (actor, base HTTP)
```

ViewModels hold a reference to `ArrServiceManager` and access the typed clients
through it. Views create their ViewModels with `@State` and pass `serviceManager`.

### API Patterns
Both Sonarr and Radarr use `/api/v3/` prefix. Auth is via:
- Query parameter: `?apikey=KEY`
- Header: `X-Api-Key: KEY`

The `ArrAPIClient` sends both for maximum compatibility.

### Model Relationships
- `ArrServiceProfile` is a SwiftData `@Model` stored locally
- All API response types (`SonarrSeries`, `RadarrMovie`, etc.) are plain
  `Codable` structs — they are NOT persisted in SwiftData
- The only persisted Arr data is the service connection profiles

---

## Cross-References to Existing Code

These Arr files reference existing Trawl utilities:

| File | References |
|------|-----------|
| `ArrServiceManager.swift` | `KeychainHelper` (from `Utilities/KeychainHelper.swift`) |
| `ArrSetupViewModel.swift` | `KeychainHelper` |
| `ArrSetupSheet.swift` | `KeychainHelper` (indirectly via ViewModel) |
| `SonarrSeriesDetailView.swift` | `ByteFormatter` (from `Utilities/ByteFormatter.swift`) |
| `RadarrMovieListView.swift` | `ByteFormatter` |
| `RadarrMovieDetailView.swift` | `ByteFormatter` |
| `ArrActivityView.swift` | `ByteFormatter` |

No modifications to existing files are required beyond:
1. Adding `ArrServiceProfile.self` to the SwiftData schema
2. Creating `ArrServiceManager` and injecting it
3. Converting the root view to TabView navigation
4. Adding the Arr services section to SettingsView

---

## Likely Issues & Fixes

### Swift 6 Concurrency
- `ArrServiceManager` is `@Observable` (implicitly `@MainActor` when observed).
  If Sendable warnings appear on the ViewModels, add `@MainActor` to them.
- The API clients are actors — all calls are `await`-ed, which is correct.

### AsyncImage Posters
- Sonarr/Radarr return image URLs that may be relative to the server (e.g.
  `/sonarr/MediaCoverProxy/...`). The `posterURL` computed properties prefer
  `remoteUrl` (absolute) over `url` (relative). If posters don't load, check
  whether the URL needs the base URL prepended.
- A fix would be to add the base URL from the API client to the model, or
  to build full URLs in the ViewModel.

### ArrQueueItem CodingKey
- The `protocol` field is a Swift keyword, so it's mapped as `protocol_` with
  `CodingKeys` mapping to `"protocol"`.

### Empty Responses
- Some endpoints return `[]` or `{}` for empty states. The models use optional
  arrays to handle this gracefully.

### Quality Profile Selection
- The add series/movie sheets currently auto-select the first quality profile
  and root folder. For a more complete UX, add Picker controls to let the user
  choose. The data is available via `viewModel.qualityProfiles` and
  `viewModel.rootFolders`.

---

## Test Priority

1. **Service setup**: Add a Sonarr instance, verify connection test and Keychain storage
2. **Series list**: Load library, verify poster images and statistics render
3. **Series detail**: Tap a series, verify seasons/episodes load
4. **Add series**: Search, verify lookup results, add one
5. **Movie list**: Same flow for Radarr
6. **Activity view**: Verify queue items from both services appear
7. **Settings**: Verify service management (add, view status, delete)

---

## Future Enhancements (not in scope now)

- Episode calendar view (Sonarr)
- Movie calendar view (Radarr)
- History view
- Disk space dashboard
- Health check warnings in Settings
- Push notifications for grabs/imports
- Deep linking between Arr queue items and Trawl torrent detail
  (match via download client ID / category tag)
