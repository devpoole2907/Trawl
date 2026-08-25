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

---

## Usage-efficient reliability work

Reliability coverage must stay meaningful without repeatedly rediscovering the whole repository.

Before editing production behavior, consult `TRAWL_TEST_COVERAGE_MAP.md`. Read and run the focused suites mapped to the touched surface; add or update the map whenever test ownership changes or a new behavior remains intentionally uncovered.

- Work one bounded coverage stack at a time. Define the exact production path, fixture, scenarios, and allowed files before delegating.
- Prefer one small subagent at a time. Give it a narrow file allow-list and require only: changed files, focused result, negative-control evidence, and unresolved risks. Do not request broad repository audits or long narrative reports.
- Reuse existing fixture servers, launch hooks, scrolling helpers, and golden contract-test patterns. Do not create a new server implementation when an existing one can be safely extended.
- Use focused tests while developing. Run a combined tranche once, and run the complete test plan only at the final checkpoint for that tranche.
- After two unsuccessful UI-test correction loops, stop guessing at selectors and inspect the accessibility hierarchy or production navigation directly.
- Reserve full all-target build gates for production/project-file changes and final release checkpoints. Test-only changes still need the directly affected target compiled by their focused test run.
- Prefer lower-level deterministic coverage when it proves the contract. Use XCUITest where the risk lives in navigation, environment injection, accessibility, presentation, persistence wiring, confirmation dialogs, or other view-owned behavior.
- Keep batches reviewable: normally 2–5 meaningful tests or one end-to-end journey per commit. Do not expand into adjacent surfaces merely because they are nearby.
- Do not use `Task.sleep`, timing guesses, skipped tests, method-mock tautologies, or direct installation of final UI state. Exercise production request/state paths with loopback servers, recording `URLProtocol`, manual clocks, or checked-continuation barriers.
- Treat usage as a budget: preserve contingency for debugging and validation, and stop at a clean committed/pushed checkpoint before exhausting the available allowance.
