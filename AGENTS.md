# Trawl – Codex Guide

## Project structure

iOS/macOS app built with SwiftUI + Swift 6 strict concurrency. Targets: **Trawl** (main iOS), **TrawlMac** (macOS), **TrawlShare** (share extension), **TrawlWidgets** (widget extension).

The Xcode project lives at `Trawl/Trawl.xcodeproj`. Source lives in `Trawl/Trawl/` (the inner directory).

---

## Building

**Simulator:** `iPhone 17 Pro` / iOS 26.4.

Quick compile-only build (no launch needed to verify correctness):
```
xcodebuild -project Trawl.xcodeproj -scheme Trawl \
  -destination 'generic/platform=iOS Simulator,name=iPhone 17 Pro' \
  build -quiet
```

---

## Adding new Swift files

This project uses **Xcode synchronized folder references** (Xcode 16+). Every file on disk is automatically compiled by every target — unless it appears in that target's `membershipExceptions` list inside `Trawl.xcodeproj/project.pbxproj`.

**Any new Swift file that is not meant for TrawlShare or TrawlWidgets must be added to both exception lists.** Forgetting this causes "cannot find type in scope" errors when building TrawlShare or TrawlWidgets, because those targets compile the file without the rest of its module.

### Which files need exclusion

| New file lives in | Add to exceptions for |
|---|---|
| `JellyfinStack/` | TrawlShare + TrawlWidgets |
| `ArrStack/` (admin/detail views) | TrawlShare + TrawlWidgets (check existing pattern) |
| `SeerrStack/` | TrawlShare + TrawlWidgets (check existing pattern) |

### How to add the exception

In `project.pbxproj` there are two identical-looking blocks of `membershipExceptions`. Search for the Jellyfin block to orient yourself:

- **TrawlShare block** — look for `CCB00000CCB00000CCB00000`
- **TrawlWidgets block** — look for `FFB00000FFB00000FFB00000`

Insert the new path alphabetically alongside the other `JellyfinStack/…` entries in **both** blocks. Example for a new `JellyfinStack/JellyfinFoo.swift`:

```
JellyfinStack/JellyfinAPIError.swift,
JellyfinStack/JellyfinAuthHeader.swift,
JellyfinStack/JellyfinAvailabilityResolver.swift,
JellyfinStack/JellyfinFoo.swift,          ← insert here (alphabetical)
JellyfinStack/JellyfinLibrariesView.swift,
```

---

## SourceKit diagnostics

SourceKit (the LSP) fires "cannot find type in scope" errors in `system-reminder` whenever a file references types defined in other files. These are **indexing noise** — they do not reflect real build errors. Ignore them entirely; use an actual `xcodebuild` run to validate.

---

## Unfamiliar iOS APIs

Whenever the user's instructions or the code you're working with reference an iOS API (SwiftUI, UIKit, Foundation, etc.) that you are not fully confident about, use the `xcrun_DocumentationSearch` tool to look it up before writing or modifying code. If the search results are unclear or multiple interpretations are possible, ask the user for clarification before proceeding.
