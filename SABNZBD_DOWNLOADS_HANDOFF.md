# Downloads + SABnzbd implementation handoff

## Objective

Replace the root **Torrents** concept with a stable, client-neutral **Downloads** surface while retaining full manual qBittorrent management and adding **SABnzbd as the only supported Usenet client**.

The intended navigation is:

```text
Downloads
├── Active
├── Queue
├── Seeding
├── History
├── Issues
└── Client Management
    ├── qBittorrent → existing TorrentListView unchanged
    └── SABnzbd → SAB-specific manager
```

The Downloads segment bar must retain the existing integrated expanding search. The unified surface should use existing row components (`TorrentRowView`, `ArrInfoRowView`, and the existing Arr history row), not newly designed replacement rows.

## Important worktree context

This worktree already contained unrelated user-requested changes before this feature began. Do not discard or overwrite them:

- Search result persistence fixes
- Recently Added Arr sorting
- Interactive-search retry fixes
- Log sharing toolbars

There are also unrelated untracked `.claude/` and `* 2.md` files. Preserve them.

No commit has been created. The current tree is partial and is **not expected to compile yet**.

## Work already drafted

### Downloads UI

New files under `Trawl/DownloadsStack/`:

- `DownloadSection.swift`
- `DownloadListItem.swift`
- `DownloadsViewModel.swift`
- `DownloadsView.swift`
- `DownloadClientManagementView.swift`

The draft currently:

- Provides stable `Active`, `Queue`, `Seeding`, `History`, and `Issues` filters.
- Uses `TrawlSegmentBar` with its existing integrated search.
- Loads Sonarr/Radarr queue and history.
- Reads qBittorrent jobs from `SyncService`.
- Deduplicates Arr queue entries against qBittorrent hashes.
- Excludes Bazarr scheduled tasks and Prowlarr history.
- Reuses `TorrentRowView`, `ArrInfoRowView`, and `HistoryRow`.
- Pushes the existing `TorrentListView` as the qBittorrent workshop.

`ArrHistoryView.swift` was adjusted to expose its existing history item/row for reuse. Review the access-level change rather than creating another history row.

### SABnzbd integration drafts

New files under `Trawl/SABnzbdStack/`:

- `SABnzbdServiceProfile.swift`
- `SABnzbdAPIError.swift`
- `SABnzbdModels.swift`
- `SABnzbdAPIClient.swift`
- `SABnzbdSetupViewModel.swift`
- `SABnzbdSetupSheet.swift`
- `SABnzbdSettingsView.swift`
- `SABnzbdManagerView.swift`

Supporting integration was partially added to:

- `TrawlModelSchema.swift`
- `TrawlApp.swift`
- `KeychainHelper.swift`
- `ServiceIdentity.swift`
- `PreviewSupport.swift`
- `WelcomeFlowView.swift`
- `ContentView.swift`
- `SettingsView.swift`
- `MoreView.swift`
- `HTTPTransport.swift`
- `project.pbxproj`

The API key must remain in Keychain using the profile key; never persist it in SwiftData or source.

## Critical missing work

### 1. Implement `SABnzbdServiceManager.swift`

This file does not exist yet and current integration references it, so the project cannot compile.

Follow the Seerr/Jellyfin manager paradigm:

```swift
@MainActor
@Observable
final class SABnzbdServiceManager
```

Expected responsibilities:

- Select the enabled/first `SABnzbdServiceProfile`.
- Read its full API key from Keychain.
- Create `SABnzbdAPIClient` with untrusted-TLS policy.
- Validate using authenticated queue/history, not version alone.
- Expose connection/refresh state and errors.
- Poll queue and history while active.
- Merge SAB queue jobs with nonterminal post-processing jobs returned by history.
- Expose raw queue/history for `SABnzbdManagerView`.
- Expose pause/resume/delete/retry/add actions used by the views.
- Disconnect and cancel polling cleanly.

Because the project uses Swift 6.2 and MainActor default isolation, API models crossing the actor boundary must remain `nonisolated`, `Codable`, and `Sendable`.

### 2. Finish and reconcile `SABnzbdAPIClient`

Audit the interrupted client implementation against the official API contract below. Confirm all method names match the setup/settings/manager views.

Required minimum:

- Version and full-key auth validation
- Queue and history
- Global pause/resume
- Individual queue pause/resume/delete
- Retry failed history item
- Archive/permanently delete history item
- Add NZB URL
- Multipart NZB upload

Defensively handle string-encoded numbers and JSON operation errors. Never log full request URLs because the API key is a query parameter.

### 3. Add SAB jobs to unified Downloads

Extend `DownloadListItem` and `DownloadsViewModel` with SAB queue/history cases.

Important SAB behavior:

- Downloading and queued jobs come from `queue.slots`.
- Repairing, verifying, extracting/unpacking, moving, and other post-processing jobs appear in `history.slots` with nonterminal statuses.
- Terminal history statuses are `Completed` and `Failed`.
- Deduplicate Arr queue items against SAB `nzo_id`; the Arr-linked row should win.
- Unmatched/manual SAB jobs must remain visible.
- Render SAB entries using the generic existing `ArrInfoRowView` initializer, not a new SAB row type.

Suggested unified mapping:

```text
Active  = downloading + SAB repair/unpack/move + Arr importing
Queue   = waiting/queued/paused jobs
Seeding = qBittorrent only
History = completed acquisition/import lifecycle
Issues  = client failures + Arr import failures
```

Replace any use of `localizedCaseInsensitiveContains` in the new search path with `localizedStandardContains`.

### 4. Replace the root tab

`RootTab.swift` has not been migrated yet.

- Rename `.torrents` to `.downloads`.
- Display name becomes `Downloads`.
- Migrate the persisted startup value `"Torrents"` to `"Downloads"`.
- Replace the root `TorrentListView` tab in `ContentView` with `DownloadsView`.
- Use a neutral downloads icon rather than qBittorrent identity.
- Badge should represent unique active unified jobs, not only qBittorrent jobs.
- Preserve `trawl://torrents` as a compatibility alias and add `trawl://downloads`.
- Ensure SAB-only users get a functional Downloads tab when qBittorrent is absent.
- Inject `SABnzbdServiceManager` into Downloads and client-management destinations.

### 5. Finish More ownership changes

Queue and History should no longer live as a visible `More → Activity` hub.

- Remove the visible Activity root row from More.
- Remove or redirect Activity/Queue/History search entries.
- Legacy navigation should select the Downloads tab and the matching segment.
- Keep raw service logs under Logs.
- Keep persistent Blocked & Excluded management in More.
- Move qBittorrent operational tools such as transfer stats/categories/RSS behind the qBittorrent client workshop where practical; connection setup remains in Settings.

Do not confuse Downloads History with raw server logs:

```text
Downloads History = what happened to the media lifecycle
Logs               = what individual servers reported
```

### 6. Complete onboarding/settings lifecycle

Review the partial patches and ensure SAB follows existing paradigms end to end:

- Welcome service selection and SAB-only completion
- Setup/edit sheet
- Connection testing and rollback on failed edits
- Settings service row and route
- More connection status/edit/retry handling
- Foreground retry and profile-change initialization in `ContentView`
- `TrawlApp` environment injection
- SwiftData migration probe/copy
- Preview environment/profile fixtures

The profile should support one enabled SAB instance initially, matching Seerr/Jellyfin.

### 7. Target membership audit

This project uses synchronized folder references.

- `SABnzbdServiceProfile.swift` must compile in Share and Widgets because `TrawlModelSchema` references it.
- Every other new `SABnzbdStack/*` file must be in both membership exception lists.
- Every `DownloadsStack/*` file must be in both membership exception lists.
- Audit both blocks in `Trawl.xcodeproj/project.pbxproj`:
  - Share: `CCB00000CCB00000CCB00000`
  - Widgets: `FFB00000FFB00000FFB00000`
- Remove duplicate exception entries introduced by concurrent edits.

## Official SABnzbd API notes

Primary sources:

- https://sabnzbd.org/wiki/configuration/5.1/api
- https://github.com/sabnzbd/sabnzbd/blob/master/sabnzbd/api.py
- https://github.com/sabnzbd/sabnzbd/blob/master/sabnzbd/interface.py

Base endpoint is the configured SAB URL plus `/api`, preserving any URL-base path. Send `output=json` and the **full** `apikey` on management calls. The restricted NZB key cannot read/manage queue and history.

Key calls:

```text
mode=queue&start=0&limit=N
mode=history&start=0&limit=N
mode=pause / mode=resume
mode=queue&name=pause|resume|delete&value=NZO_ID
mode=retry&value=NZO_ID
mode=history&name=delete&value=NZO_ID
mode=addurl&name=URL
POST multipart: mode=addfile, file field=nzbfile
```

History polling can return `{ "history": false }` when `last_history_update` is unchanged. Omitting that parameter always requests an object.

Some SAB actions report `status: true` unreliably. When affected IDs are returned, verify the requested ID appears and refresh afterward.

## Validation required before handoff

1. Add focused Swift Testing coverage for:
   - Queue/history response decoding
   - String and numeric scalar variants
   - Post-processing status normalization
   - `{ "history": false }`
   - API error decoding
   - Query construction/auth redaction
2. Run the real simulator build:

```bash
xcodebuild -project Trawl.xcodeproj -scheme Trawl \
  -destination 'generic/platform=iOS Simulator,name=iPhone 17 Pro' \
  build -quiet
```

3. Fix strict-concurrency and target-membership errors rather than relying on SourceKit diagnostics.
4. Exercise these configurations:
   - qBittorrent only
   - SABnzbd only
   - Both clients
   - Arr services without either client
   - No configured services during onboarding
5. Verify the existing qBittorrent manager behavior remains unchanged.

## Recommended finish order

1. Finish `SABnzbdServiceManager` and reconcile client APIs.
2. Compile once to expose integration naming mismatches.
3. Add SAB cases to unified Downloads.
4. Replace the root tab and deep links.
5. Remove/redirect More Activity ownership.
6. Audit onboarding/settings/retry behavior.
7. Audit membership exceptions.
8. Add tests, build, and manually verify all service combinations.

