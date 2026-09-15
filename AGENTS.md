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

## Configuration editing and shared design patterns

Existing configuration screens **must open read-only on every platform and in every presentation** (push, sheet, split detail). Use **Edit → Save** in the same toolbar position, plus **Cancel** while editing. Where independent editors share a toolbar, contextual labels such as **Edit File Handling → Save File Handling** disambiguate the action without changing this lifecycle. Successful Save returns to read-only; rejected Save retains the draft and Save action. Read-only sheets use **Close**, never Done to imply that an unsaved draft was committed.

Reuse `TrawlEditToolbar` and `trawlEditingGuard(isEditing:isSaving:)` from `Trawl/Views/FormComponents/ServiceSettingsFormStyle.swift`. Do not copy toolbar state branches into a new editor. Examples: `SeerrUserEditorView`, `JellyfinTranscodingSettingsView`, `ArrQualityDefinitionSheet`, and `BazarrProviderEditorView`.

- Keep a server-confirmed baseline and a separate local draft. Entering Edit snapshots the latest baseline; Cancel restores it without a network write. Only enable Save for a valid changed draft.
- Save all related configuration changes in one request where the API allows it. Adopt the server's accepted response as the new baseline; do not substitute the submitted draft when the server can normalize it.
- Disable editable controls and Cancel while saving. Do not dismiss or exit editing on failure. Retain the attempted draft for retry and show the error.
- Apply the shared editing guard to the editor's presentation host. Protect parent row selection, server switching, and refresh too: the modifier protects local back navigation and interactive sheet dismissal, **not external sidebar navigation or parent-owned Close buttons**. Either block those transitions until Save/Cancel or retain drafts in shared, server-keyed session state and ask before discarding. Do not attach an unconditional dismissal button around an editor.
- For native sidebar editors, expose editing state through the existing shared browser/view model and extend `ContentView.isSidebarNavigationBlockedByEditing`. Reuse its sidebar selection/search/banner guard rather than adding another navigation implementation. Quality, Prowlarr, and naming file handling already register there. Programmatic/deep-link navigation needs its own scope/draft check.
- Keep existing configuration read-only in sheets too. Creation forms may open editable: use **Add** for creation and **Save** for existing-item commits. Domain commands such as **Enable**, **Import**, or **Send** retain their specific names.
- Operational commands (pause/resume, speed mode, test, delete/disable) may apply immediately, with clear feedback or confirmation as appropriate. Ordinary configuration toggles, fields, tags and pickers must stage changes until Save. Do not mix draft and immediate configuration in the same editor.
- Preserve server identity through save requests and async responses. A same-ID entity on another server is a different editor.
- Bazarr Anti-Captcha intentionally keeps its existing in-form Edit/Save controls. Do not move those controls into a toolbar merely to enforce this convention. The separate Bazarr provider editor uses the shared toolbar.
- Reuse grouped `Form` styling (`serviceSettingsFormStyle()`), central entity headers and existing sheet/navigation shells. Presentation may adapt to surrounding navigation, but commit semantics must stay consistent.

Update the focused UI journeys and `TRAWL_TEST_COVERAGE_MAP.md` when changing these contracts. Syntax parsing is useful without Xcode, but it does not establish SwiftUI type correctness or replace iOS/macOS builds and fixture-backed runtime tests.

---

## Usage-efficient reliability work

## Search empty-state consistency

When a non-empty text query returns no matches, use `ContentUnavailableView.search(text:)` with the trimmed query. Keep custom `ContentUnavailableView` copy for genuinely empty collections and for non-text filters, because those states should explain the domain condition rather than suggest changing search spelling.

## Initial loading consistency

When a screen has no usable content during its first load, reuse `TrawlInitialLoadingView` from `Views/ServiceErrorView.swift`. Give it a concise localized accessibility label; do not add visible loading text. Keep compact `ProgressView` controls for refreshes, pagination, saves, searches, and row-level actions where existing content remains usable.

## Toolbar action accessibility

Every icon-only toolbar action must carry its localized action name. Prefer `Button("Refresh", systemImage: "arrow.clockwise") { ... }` or a `Label` over a bare `Image`; if the action becomes a `ProgressView`, give the progress control a concise accessibility label such as “Refreshing trackers.”

## Sheet sizing

Informational detail sheets that may contain variable or lengthy content should offer both `.medium` and `.large` detents with a visible drag indicator. Keep short, task-focused forms at `.medium` when their complete content fits comfortably without scrolling.

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
