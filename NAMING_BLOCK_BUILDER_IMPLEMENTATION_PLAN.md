# Naming block builder — implementation plan

Status: proposed implementation; no production changes made by this plan.

## Outcome

Replace the default naming-format text editor with a visual builder. People arrange understandable pieces of a filename, see the result immediately, and save deliberately. Raw Sonarr/Radarr syntax remains available for advanced formats without becoming a prerequisite for ordinary use.

Approved visual order:

1. Native navigation title and server context.
2. Live “Your file will look like this” preview.
3. Filename blocks, with Undo.
4. Separator choice.
5. Available block tray, below on iPhone or alongside when space permits.

Do not put the preview above the navigation title. Avoid adding a second large heading that repeats the navigation title. The preview remains close to the builder and visible during editing where space permits; test keyboard, Dynamic Type and compact-height behavior before introducing sticky content.

Design reference: `naming-blocks.html` in this task’s visualization directory. The HTML demonstrates interactions, not a complete parser or production persistence implementation.

## Scope and platform behavior

### Shared experience

- Naming list shows familiar format names and short rendered examples. Keep the specific server instance visible; HD and 4K naming rules are separate configurations.
- Select a format to open its builder. All supported Sonarr episode/folder and Radarr movie/folder fields remain reachable.
- Start from the actual server format. “Start simple” is an explicit, undoable replacement, never an automatic conversion of an existing rule.
- Use the same block labels, examples, ordering, customization choices and save semantics on every platform.
- Separate file-handling controls from the building task. Preserve their existing behavior during this tranche; avoid redesigning unrelated settings.
- No rename-existing-files action, new endpoint, or bulk server operation.

### iPhone

- Push the builder from the naming list using the existing compact navigation infrastructure.
- Preview below the native title; wrapping block arrangement below it; tray below the builder.
- Tapping a block opens a focused options sheet with concrete examples, Remove, Move earlier and Move later.
- Use a sufficiently large presentation for choices. Do not carry the full builder in a medium-height sheet.
- Preserve Back navigation and guard a dirty draft before leaving.

### iPad

- Reuse the app’s native NavigationSplitView and TrawlListDetailPanes integration: content list and selected builder remain adjacent when space allows.
- Respect the existing unselected detail placeholder; do not auto-select the first format.
- Block options use an anchored popover, adapting to a sheet at compact size.
- Place the tray alongside only when the builder retains useful width; otherwise place it below. Compact windows collapse to the same list → builder path as iPhone.

### macOS

- Reuse the root split-view hierarchy rather than nesting another independent navigation container.
- Format list in the content column, builder in detail; tray beside the builder when space permits.
- Support pointer dragging, keyboard focus, Undo/Redo and a save shortcut consistent with the application’s command handling.
- Popover for block choices; no mobile sheet chrome embedded in the detail column.

## Block interactions

### Build and rearrange

- Each block has a stable instance ID, a plain-language label, a concrete sample and a subtle drag affordance. Color supplements labels; it never carries meaning alone.
- Drag a tray item into the arrangement to insert it. Drag an existing block to reorder it.
- Show a clear insertion placeholder and animate neighboring blocks into their prospective positions. Handle wrapped rows and drops at the start/end, between rows, and into an empty arrangement.
- The filename preview reflects the proposed drop position. Cancelled or out-of-bounds drops restore the original state and create no undo entry.
- A completed drag is one undoable action, regardless of how many intermediate positions were visited.
- Tap a tray block to append it. Tap a placed block to customize or remove it. Expose equivalent accessibility actions for insert, move and remove.
- Avoid immediate deletion by dragging outside the board; use explicit Remove.
- Preserve valid repeated tokens loaded from a server. Do not turn the demo’s “one of each” tray limitation into a parser restriction.

### Customize

- Options show actual filename output rather than raw token syntax: for example `S01E02` and `1x02` under Episode number.
- Map every offered choice to verified, field-supported Sonarr/Radarr syntax. Do not assume every example in the HTML is supported by the server.
- Typical initial blocks: show/movie name, episode number, episode title, date, year, quality, video information and release group. Folder fields get a smaller, appropriate catalog.
- Reveal less common choices progressively. Reuse the existing token catalog and sample values wherever correct rather than maintaining a conflicting second catalog.

### Separators

- Offer Dashes, Spaces and Dots for simple arrangements. These join blocks; distinguish that from punctuation inside a title or token.
- Group compound elements such as `S{season:00}E{episode:00}` into one Episode number block. Never inject separators inside it.
- Preserve existing mixed punctuation, brackets, prefixes, optional-group separators and folder paths exactly.
- For mixed existing separators, display a “Custom” state. Choosing a uniform separator must be an explicit, undoable replacement of join boundaries, not a silent normalization of literals.

## Compatibility model: implement before the UI

Introduce a pure, testable format representation with two layers:

- A lossless syntax layer containing exact token spellings and literal segments.
- A presentation layer grouping supported syntax into friendly blocks without changing the stored expression.

The editor session records server instance ID, format target, original server expression/configuration, draft, undo history and save state. Scope identity is `(instanceID, formatTarget)`, not just service type.

Required properties:

- Parsing and serializing an untouched format returns the exact input, including whitespace and case.
- Friendly compound blocks retain their original spelling until explicitly edited.
- Unknown tokens, unsupported modifiers and arbitrary literals never disappear.
- For partially representable formats, retain opaque/custom pieces visibly, or open the exact expression in Advanced. Never silently rebuild the format from only recognized tokens.
- Advanced text editing and block editing share one draft. Reparse on an explicit return to the builder; retain Advanced when conversion cannot be represented safely.
- Preserve field-specific token validity. Do not expose episode-only tokens in folder/movie builders.
- Preview uses the same serialized draft that Save sends. Missing sample metadata or unsupported preview syntax must be identifiable, not presented as a verified server result.
- `.mkv` in a file preview is illustrative; do not append it to the saved naming format. Folder previews have no file extension.

## Draft, navigation and persistence

- Edits affect a local draft only. Enable Save when the draft differs from the loaded value and passes available validation.
- The proposed builder opens directly for local editing on all platforms. This intentionally replaces the current detail-pane Edit gate and compact editor sheet; update tests that pin those behaviors explicitly.
- Back, selection changes and server switches with unsaved edits offer Save and continue, Discard, or Keep editing. Resolve this before changing the active target. A cancelled choice leaves selection and draft intact.
- Preserve current save confirmation in the initial implementation, with the specific server named. Do not silently remove the existing confirmation contract as part of a visual rewrite.
- Await server acceptance before dismissing a compact editor or treating the draft as saved. On failure retain the full draft and allow retry.
- Capture server identity and target before starting async work. A response for an old scope must not replace a newly selected server’s list or detail.
- Update only the intended format field within its owning configuration; preserve all other naming fields and file-handling settings.
- Reconcile with the server-accepted response after success. Update both the list example and builder baseline; do not assume the submitted value equals the accepted value.
- Prevent duplicate submissions while saving. Retain existing connection/loading/error handling.
- Drafts are session-local in this tranche; cross-launch draft restoration is not required.

## Existing implementation and test contracts

Read these files before implementation:

- `Trawl/ArrStack/ArrNamingConfigView.swift`: per-instance loading/saving, list/detail routing, scope changes.
- `Trawl/ArrStack/ArrNamingFormatEditorSheet.swift`: editor, format targets, token catalog, presets, preview and insertion helpers.
- `Trawl/ArrStack/ArrNamingBrowserState.swift`: shared selection/configuration state.
- `TRAWL_TEST_COVERAGE_MAP.md`: naming, sidebar selection, save propagation, failure and scope boundaries.
- `TrawlTests/ArrNamingFormatTests.swift`.
- `TrawlUITests/IPadSidebarJourneyUITests.swift`.
- `TrawlUITests/MoreSettingsBreadthUITests.swift`.

At plan creation, the workspace already has staged changes in the naming editor/config view, quality definitions, coverage map and iPad journey tests. Preserve and build on those changes. In particular, current naming save callbacks return async acceptance, and detail panes have an Edit gate; older conversation snippets predate that behavior.

## Implementation sequence

### 1. Lossless model and serialization

Allowed scope: new naming model/parser files, focused unit tests, coverage-map entry, necessary project membership exclusions.

- Define syntax pieces, block grouping, stable IDs, supported variant mappings and separator policy.
- Prove round-trip preservation against existing presets and deliberately difficult custom expressions.
- Add pure mutations for insert, move, remove, customize and undo/redo.
- Reuse the catalog and preview helpers; extract them only when needed, preserving existing contracts.

Exit: unchanged expressions round-trip exactly and editing one block preserves unrelated syntax.

### 2. Shared native builder

Allowed scope: new naming builder/block/options/tray views and their model integration.

- Implement preview-first content under the navigation title.
- Implement drag insertion/reordering with native SwiftUI drag/drop APIs suitable for the deployment target; verify unfamiliar APIs using `xcrun_DocumentationSearch` before coding.
- Use a typed local drag payload identifying the editor session and block identity/type. Reject foreign, stale or unsupported payloads.
- Prefer platform-native drag previews and feedback; do not reproduce the HTML pointer-event implementation.
- Add tap/keyboard/accessibility alternatives, options, separator selection and Undo/Redo.
- Provide previews for narrow widths, dark mode, large text, empty and custom formats.

Exit: the builder works with deterministic local draft state and cancelled drops are harmless.

### 3. Navigation and server integration

Allowed scope: naming config/editor/browser state, root routing only where required for the compact push, focused existing fixture and journey files.

- Replace compact sheet presentation with the push route; reuse native split-view detail on larger platforms.
- Retain the existing empty-detail state and selection restoration.
- Add dirty-draft navigation handling, acceptance-aware saving, retry and response reconciliation.
- Keep editor drafts and requests tied to the captured server instance.
- Bring all existing format targets into the builder or its lossless Advanced fallback.

Exit: save success/failure and server switching satisfy the contracts above using production request paths.

### 4. Focused validation and polish

- Update existing UI expectations for the intentional compact-route and Edit-gate changes; keep unrelated quality-definition tests intact.
- Verify actual drag gestures on iPhone/iPad and perform a Mac interaction check.
- Update the coverage map with test ownership and remaining manual boundaries.
- Run final production/project build gates and the complete test plan once at the final checkpoint.

Keep implementation batches reviewable. Do not expand into quality definitions or other adjacent editors.

## Verification matrix

| Surface | Evidence required |
|---|---|
| Syntax | Exact round trip for standard/daily/anime/movie/folder presets, mixed separators, optional release-group punctuation, repeated tokens, unknown tokens, paths and empty expressions. |
| Mutations | Insert/reorder/remove/customize yield the expected serialized expression; cancel is a no-op; one drag gives one undo step; redo restores it. |
| Preview | Output reflects the actual serialized draft; compound episode numbering and field-specific token restrictions remain correct; extensions remain preview-only. |
| iPhone flow | Open through production navigation, add/reorder/customize, leave and keep/discard a draft, save successfully, and retry a rejected save without losing edits. |
| iPad flow | Selection restoration, unselected placeholder, draft handling, accepted response in both columns and staying in the native detail pane. |
| Server isolation | Reuse the existing alternate Sonarr fixture with colliding format targets; assert the correct server receives the PUT, untouched fields survive, and the other server receives no write. |
| Accessibility | VoiceOver labels and move actions; tap-only construction; keyboard ordering/removal; Dynamic Type, contrast, Reduce Motion and focus restoration after options close. |
| Drag layout | Wrapped rows, empty board, first/last positions, drop cancellation, touch vs pointer and compact window resizing. |

Extend existing `SonarrFixtureServer` and journey helpers rather than introducing another server. Use production load/save paths and recorded request bodies. Add a focused Radarr contract path using the existing Radarr fixture where needed. Do not use sleeps, guessed timing, skipped tests or direct installation of final UI state. After two failed UI selector corrections, inspect the accessibility hierarchy.

For parser/mutation regressions, demonstrate a meaningful negative control, such as stripping unknown literals or routing by service instead of instance causing the focused test to fail. Keep each test batch to a few meaningful scenarios rather than mirroring every implementation method.

## Project/build requirements

New app-only Swift files must be excluded from both TrawlShare and TrawlWidgets synchronized-folder membership lists in `Trawl.xcodeproj/project.pbxproj`, following the existing ArrStack pattern. Confirm intended TrawlMac membership as well. Swift 6 strict concurrency applies.

Run the focused mapped suites during development. For compile verification from this workspace:

```sh
xcodebuild -project Trawl.xcodeproj -scheme Trawl \
  -destination 'generic/platform=iOS Simulator,name=iPhone 17 Pro' \
  build -quiet
```

Use concrete installed simulator destinations for test runs. Validate relevant app/extension/macOS build targets after production/project changes. Ignore cross-file SourceKit indexing noise; actual builds are authoritative.

## Acceptance checklist

- [ ] A person can assemble and save a normal filename without seeing braces, token syntax or a text field.
- [ ] The native title precedes the live preview; the preview precedes the blocks.
- [ ] Drag insertion and reordering work, with visible placement feedback and cancellation.
- [ ] Every drag action has a tap/keyboard/accessibility equivalent.
- [ ] Custom server expressions survive untouched; no unrecognized content is silently discarded.
- [ ] The same builder and terminology work across iPhone, iPad and Mac.
- [ ] Save failures preserve edits; accepted responses update both columns; writes stay on the owning server.
- [ ] Focused tests, coverage-map updates and final build/test gates pass.
