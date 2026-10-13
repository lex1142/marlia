# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Marlia — a two-pane SwiftUI file manager for macOS (Total Commander-style: two panes, F5/F6
copy/move, tabs, archives, SMB, Workspaces). See README.md for the feature overview and known
limitations.

## Build & run

There is no Xcode project or Package.swift — the app is compiled directly with `swiftc` into a
`.app` bundle by `./build.sh`, which assembles `build/Marlia.app` from scratch (binary from `swiftc`,
`App/Info.plist`, `App/Marlia.icns`, ad-hoc `codesign`). `build/` is gitignored.

```
./build.sh          # compile + assemble build/Marlia.app
./build.sh --run    # ...then quit a running copy and relaunch
./build.sh --dmg    # ...then package build/Marlia-<version>.dmg
```

**`build.sh` holds the one list of source files.** When you add a new `.swift` file, add it to the
`SOURCES` array there, or it will silently not be part of the build. CI calls the same script, so there
is no second list to keep in sync.

**With only Command Line Tools installed, the macOS 27 SDK can't build this app.** In the 27 SDK,
SwiftUI's `@State` is a macro whose implementation (`SwiftUIMacros`) ships only with Xcode, so with the
CLT the build fails with `external macro implementation type 'SwiftUIMacros.StateMacro' could not be
found`. `build.sh` handles this: when `xcode-select -p` points at the CLT and
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` exists, it passes that SDK via `-sdk`
(override with `SDK=/path/to.sdk ./build.sh`). Drop the fallback once the 26.5 SDK goes away. The script
runs under `set -e`, so a failed compile stops it before a stale binary can be copied and relaunched —
which is exactly how a broken build used to go unnoticed when the steps were chained by hand.

**Never overwrite the binary inside the bundle in place.** `cp` onto an existing
`Contents/MacOS/Marlia` keeps the inode, the kernel keeps its cached code signature for it, and the next
launch fails with `Launchd job spawn failed` (POSIX error 162). `build.sh` removes the old binary before
copying; do the same if you ever copy by hand.

**The bundle's `Info.plist` is a copy of `App/Info.plist`** — that's the versioned source of truth
(`build/` isn't in git, so edits made only inside the bundle are lost on the next build). Besides the
usual bundle keys it carries the TCC purpose strings (`NSDesktopFolderUsageDescription` and friends):
the app is unsandboxed and walks into Desktop/Documents/Downloads plus removable/network volumes,
and Apple requires the access prompt to state a reason — without those keys the prompt appears
bare. The version shown in About and used for the DMG name is its `CFBundleShortVersionString`.

The `-target arm64-apple-macosx13.5` is **load-bearing, not just a CI check**: it stamps the binary's
`LC_BUILD_VERSION minos` to 13.5. Drop it and `swiftc` uses the host SDK's default (e.g. `minos 26.0`),
so the app refuses to launch on Ventura ("not suitable for this version") **even though `Info.plist`
says 13.5** — macOS honours the Mach-O `minos`, not just the plist. Verify a release/DMG binary with
`otool -l build/Marlia.app/Contents/MacOS/Marlia | grep -A3 LC_BUILD_VERSION` → expect `minos 13.5`.

CI (`.github/workflows/build.yml`) runs `./build.sh` on push/PR to `main` and checks `minos 13.5` —
compile-check only, since there are no automated tests (see below).

**CI compiles with an older Swift than yours, and a green local build proves nothing about it.**
The runner is `macos-14`, which ships **Swift 5.10**; a current local toolchain is 6.x. The gap that
actually bites is region-based isolation: Swift 6 accepts a concurrent closure that reads a mutable
`var` from the enclosing scope, while 5.10 rejects it outright —
`error: reference to captured var 'x' in concurrently-executing code`. That single difference kept the
Build workflow red from July until it was fixed on 2026-08-29, in code that compiled cleanly on every
developer machine the whole time; the failures were in `FileOperationService` (`transfer`, `trash`,
`duplicate`, `deletePermanently`) and `ArchiveService` (`stderrText`), all of them long-standing.

The fix is always the same and is safe under both compilers: snapshot into a `let` immediately before
the closure, at a point where the value has stopped changing.

```swift
let collectedErrors = errors          // the loop is done, the value no longer changes
Task { @MainActor in completion(collectedErrors) }
```

There is no way to reproduce 5.10 locally (no older toolchain, and no flag makes 6.x behave like it),
so **whenever you add a `Task { … }` or any other concurrent closure inside a `DiskOperationQueue`
operation, check by eye whether it reads a `var` from the surrounding scope** — that is cheaper than
finding out from CI. Note also that the compiler stops after the first batch of errors, so one red run
can hide the next one: the August fix took two rounds for exactly that reason.

### Building the DMG

`./build.sh --dmg` produces `build/Marlia-<version>.dmg` (gitignored, like everything under `build/`)
from a staging folder holding exactly three entries — the app, an `Applications` symlink to drag it
onto, and `Packaging/Read Me.txt`. Releases are published on GitHub (`gh release create v<version>
build/Marlia-<version>.dmg`).

`Packaging/Read Me.txt` is versioned precisely because it is *not* part of the app bundle: it only ever
existed inside previously built images, so a lost image (or a scratch folder cleaned between sessions)
took it with it. Its filename is what users see in the mounted image. It documents the
ad-hoc-signature workarounds (right-click → Open, "Open Anyway" on Sequoia+, `xattr -cr`) — as does the
Install section of README.md — so both need an update if the app ever gets a Developer ID and
notarization.

Verify a freshly built image by mounting it and checking the binary is the one you just built and still
targets Ventura: `hdiutil attach build/Marlia-<version>.dmg` → `cmp "/Volumes/Marlia <version>/Marlia.app/Contents/MacOS/Marlia" build/Marlia.app/Contents/MacOS/Marlia`
(not `build/Marlia`: the bundle is re-signed, which rewrites the signature inside the binary)
and `otool -l … | grep -A3 LC_BUILD_VERSION` → `minos 13.5`.

Target is macOS 13.5+ (Ventura). Context menus are built as plain AppKit `NSMenu`
(`ClosureMenuItem` in `PaneInteractionViews.swift`, assembled by `PaneView.contextNSMenu`),
**not** SwiftUI + `NSHostingMenu` — `NSHostingMenu` requires 14.4 and was the sole thing forcing
that floor; dropping it lowered the deployment target to 13.5. CI enforces the floor with
`swiftc -target arm64-apple-macosx13.5` (the runner is still `macos-14`, using a newer SDK).
(Watch availability against the *deployment* target, not just the host SDK: e.g. the
`URLResourceValues.tagNames` **setter** got re-annotated `@available(macOS 26)` in a newer SDK and
broke the CI build — color tags are now set via the `NSURL.setResourceValue(_:forKey:)`
Obj-C bridge, which has no such restriction. `swiftc -target arm64-apple-macosx13.5 …` surfaces this
class of error locally.) A few call sites use API that's merely deprecated, not unavailable, on macOS
14+ (e.g. one-parameter `onChange`) — the compiler warns but this doesn't block the build and is left
as-is. The app is unsandboxed; first launch may need
Full Disk Access granted in System Settings to see Desktop/Documents/Downloads without extra prompts.
There are no code-signing identities in this environment — the app only ever gets an ad-hoc/linker
signature. That's enough to run locally, but a build transferred to another Mac (AirDrop, cloud
sync) can trip Gatekeeper's harsher "app is damaged" message rather than the milder "unidentified
developer" one; the fix on the receiving machine is `xattr -cr /Applications/Marlia.app`, not
re-signing.

## Testing / verifying changes

There is no test target. Two verification paths are used instead:

- **Logic-only changes** (parsing, symlink resolution, concurrency primitives, path math): write a
  throwaway standalone script and run it with `swift <file>.swift` (use the scratchpad directory,
  not the repo). This has repeatedly caught real bugs before they reached the app — e.g. that
  `FileManager.contentsOfDirectory`/`resourceValues` do **not** follow the final path component when
  it's a symlink (`.resolvingSymlinksInPath()` first), and that `NSTableView` consumes `mouseUp`
  inside its own event-tracking loop so local `NSEvent` monitors never see it for row clicks.
- **App-level changes**: `./build.sh --run`, then confirm the process is still alive
  with `ps aux` a couple seconds later (catches immediate startup crashes). There is no Accessibility/
  Screen Recording permission in this environment, so UI behavior (focus, click targeting, visual
  layout) cannot be verified directly — it needs the user to smoke-test and report back. Don't claim
  a UI fix works without that confirmation.

## Architecture

**Windows/tabs/toolbar are AppKit, not SwiftUI scenes** (`App/main.swift`, `App/WindowControllers.swift`).
The entry point is a plain AppKit `main.swift` (`NSApplication` + `AppDelegate`) — there is **no** SwiftUI
`App`/`WindowGroup`/`Settings` scene. Each window is a `MarliaWindowController` whose
`contentViewController` is a `MarliaSplitViewController` (an `NSSplitViewController`: sidebar item +
content item), and whose content is SwiftUI hosted in `NSHostingController` (`SidebarHostView` and
`PanesRootView`, split out of the old `ContentView`). New tabs are made by `AppWindowManager` with an
explicit `addTabbedWindow` (⌘T / toolbar `+` / native `+`); it also restores the session and owns the
auxiliary windows (`AuxWindowController` for Get Info / Archive Contents / Help / Settings) — replacing
`openWindow`. **This was migrated away from SwiftUI `WindowGroup`/`NavigationSplitView` deliberately**:
the scene lifecycle rewrote `NSApp.mainMenu` on scene changes (killing ⌘T and shortcuts after
minimize/restore), merged tab windows unreliably, reset the selected tab on restore, and
`NavigationSplitView`-in-`NSHostingController` broke the sidebar's width/resize. The toolbar is a plain
`NSToolbar` on the window (system `.toggleSidebar` at the leading edge, app buttons flexible-spaced to
the trailing edge); the window title is set from `activeDirectoryURL` by the controller. Keyboard focus
on window/tab creation is pushed to the active pane (`AppState.focusActivePane`/`paneFocusNonce`), the
sidebar list `refusesFirstResponder`, and sidebar navigation returns focus to the pane — so arrows always
drive the pane, never the sidebar. (One SwiftUI-era safety net remains: `MainMenuController` still
re-installs its menu on `didUpdate` if the `File` submenu goes missing — harmless now, kept defensively.)

**Per-window vs. app-wide state.** Each window/tab gets its own `AppState` (defined in
`App/MarliaApp.swift`, owned by its `MarliaWindowController`),
which owns two `PaneViewModel`s (`leftPane`/`rightPane`, in `ViewModels/PaneViewModel.swift`) plus
undo/redo and pending-dialog state (conflict resolution, archive creation, workspace
creation/rename). `FavoritesStore` and `VolumesStore` are similarly one-per-window. By contrast,
`WorkspaceStore.shared`, `DiskOperationQueue.shared`, `SortPreferencesStore.shared` and
`FileClipboard.shared` are true app-wide singletons — a Workspace, the disk-operation concurrency
limit, a folder's remembered sort, or what's on the clipboard is shared across every open window, not
duplicated per tab.

**The clipboard is app-wide on purpose** (`Models/FileClipboard.swift`). It used to live on `AppState`,
i.e. per window *and per tab*, so only the tab where ⌘X was pressed knew the items were cut: pasting in
any other tab found no cut flag and silently copied instead of moving — the file appeared at the
destination and stayed at the source. The system pasteboard is one per app, so the "cut, not copied"
flag has to be one too. `FileClipboard` also records `NSPasteboard.changeCount` at write time and
treats the cut as void once anything else writes to the pasteboard, so a copy made in Finder can't be
paste-moved by us. `AppState.clipboardMode`/`clipboardURLs`/`isCut(_:)` are now thin forwards; views
that dim cut items observe `FileClipboard.shared` directly (`PaneView.clipboard`) — that also makes the
dimming show up in every window/tab where those files are visible, not just the one that cut them.

**Sort order is remembered per directory** (`Models/SortPreferencesStore.swift`), Finder-style: pick a
sort in a folder and that folder keeps it, across navigation and across restarts (UserDefaults, path →
field + direction, LRU-capped at 500 entries). Two deliberate properties: a folder the user never
sorted stores **nothing** and simply inherits whatever the pane is currently sorted by (the pre-existing
behavior), and the direction is stored separately from the field because a List-view column-header click
can invert it. `PaneViewModel.sortOrder`'s `didSet` records, `navigate(to:)`/`init` apply — with an
`isApplyingStoredSort` guard so restoring doesn't immediately re-record. Keys are
`resolvingSymlinksInPath()` so a Workspace symlink and the real folder share one entry.

**`/Applications` is displayed merged with `/System/Applications`, Finder-style**
(`FileItem.contentURLs`). Since Catalina, Apple's apps live on the read-only system volume in
`/System/Applications` (47 entries here) while third-party ones are in `/Applications` (28) — and
Finder shows the two as *one* list, which is why its sidebar Applications row looks complete. So
`contentURLs` (now the single directory-reading entry point, used both by `PaneViewModel.reload` and by
`FileItem.loadItems` for Columns, so all three view modes agree) appends the system folder when the
directory being read is exactly `/Applications`. Items keep their real URLs, so open/drag/Get Info/copy
work normally and renaming a system app fails on the read-only volume — same as Finder. Name collisions
keep the `/Applications` copy, **except** when that copy is an empty stub directory: the one real
collision on macOS is `Utilities`, where `/Applications/Utilities` holds nothing but `.localized` and
the actual utilities (Terminal, Disk Utility, …) are in `/System/Applications/Utilities`. Note the
merge is keyed on the *resolved* path, and the directory watcher still only watches `currentURL` — the
system folder isn't watched, which is fine for a read-only volume.

**Theming goes through one palette, and `system` must stay a true no-op** (`Models/Theme.swift`).
`ThemeStore.shared` is app-wide (a theme is a property of the app, not of a tab), persisted in
UserDefaults, and offers `system` + `dracula`; View ▸ Theme switches it live. Three deliberate
properties:
- **`ThemePalette.system` paints nothing.** Its background fields are `nil` and the `themedBackground`
  / `themedSidebarBackground` modifiers then return the view untouched, while the AppKit modes fall
  back to the table's own captured default (`coordinator.defaultBackgroundColor`). That's the guarantee
  that picking "System" reproduces the pre-theme app exactly, rather than an approximation built from
  semantic colors.
- **Selection highlight can't be set as a property** — `NSTableView` draws it with the system accent —
  so `ThemedTableRowView` (used by both List and the Columns tables via `rowViewForRow`) draws it
  itself, but *only* when `palette.isCustom`; otherwise it calls `super` so the system theme keeps
  AppKit's vibrancy and emphasized/unemphasized behavior. Icons view has its own
  `FileIconItem.selectionColor` for the same reason.
- **The List header needs both a custom cell and a custom header view.** `NSTableHeaderCell` paints its
  own background with system colors (in dark appearance a grey noticeably lighter than the panes), and
  nothing exposes it as a property — so `ThemedTableHeaderCell` fills it, while `ThemedTableHeaderView`
  covers the strip to the right of the last column that no cell reaches. Two things confirmed by
  rendering the header offscreen (`cacheDisplay` into a bitmap — the environment can't screenshot):
  AppKit still draws the sort indicator, because it calls `drawSortIndicator` separately from `draw`;
  and `drawInterior` needs a 4pt horizontal inset or the titles sit left of the row text below.
- **The three AppKit modes need `themeGeneration` passed in.** Their `updateNSView` reconfigures
  visible cells only when something view-affecting changed (zoom / cut set) — that guard is what keeps
  arrow-key navigation from re-rendering everything — so the theme is threaded through as one more such
  signal (`ThemeStore.generation`, an int, is cheaper to compare than colors). Cell colors are read at
  configure time from `Theme.current`; row views get an explicit `needsDisplay` because reconfiguring a
  cell doesn't repaint the row behind it.

A fixed palette also forces its own lightness via `AppTheme.appKitAppearance` (`.darkAqua` for the dark
ones, `.aqua` for Solarized Light), applied in `applicationDidFinishLaunching` *before* the first window
exists, else it flashes system colors; that's what takes menus/sheets/scrollers/toolbar with it, and the
palette then only tints what's ours.

**Palette values are chosen against contrast, not copied blindly.** The architecture fixes one hard
constraint: text color does **not** depend on whether the row is selected (making it depend on selection
would mean reconfiguring cells on every arrow step — the exact "jelly" this codebase already fought), so
one color must stay readable both on the pane background *and* on the selection fill. Every palette was
checked with a throwaway WCAG-contrast script (scratchpad, per the testing section) and lands ≥4.5:1 for
both name and secondary text; that check is what forced three deviations from the published palettes:
- **Dracula / Nord secondary text** is the foreground at 62% alpha, not the canonical Comment
  (`#6272A4` → 2.4:1, `#4C566A` → 1.9:1). Gruvbox needed no such fix — its `gray #A89984` gives 5.3:1.
- **Solarized uses base2/base02 for names and base1/base01 for secondary**, not the spec's body-text
  base0/base00: Solarized is deliberately low-contrast, and base0 fell to 3.6:1 on the selection fill.
- **Solarized selection is its blue at 35–40% alpha**, because the canonical base02/base2 highlight is
  nearly indistinguishable from the pane (fine for a current-line marker in an editor, not for "this
  file is selected").
- **Nord is the one palette whose chrome is lighter than its pane** (`nord1` over `nord0`): nord0 is the
  darkest colour it has, and Nord's own editor themes paint the sidebar that way.

**The system accent colour leaks into SwiftUI controls and has to be handled in two ways.**
Toggles, checkboxes, `ProgressView` and the sidebar's selected row are painted with the *user's*
macOS accent (pink, green, whatever they picked) regardless of our palette; `.themedTint(palette)`
on `PanesRootView` and `SidebarView` overrides it for those. The segmented **view-mode picker is the
exception**: it exposes no colour property and ignores `.tint`, so for custom palettes `PaneView`
draws it itself (`themedViewModePicker` — three plain buttons, accent fill under the selected one,
icon colour picked automatically from the accent's luminance via `ThemePalette.onAccent`). The System
theme keeps the native `Picker`, same invariant as everywhere else.

Note for anyone re-checking this: **accent colours cannot be verified by offscreen rendering.**
`cacheDisplay` into a bitmap draws every control unemphasized — a default push button, which is always
accent-filled on screen, comes out grey in the capture. Verified by rendering one as a control group;
so the mode-picker fix was deliberately built to be correct *by construction* (we paint the fill
ourselves) rather than by trusting AppKit's accent behavior, and our own drawing *does* render
correctly offscreen.

**`Solarized (Auto)` is the only theme whose palette isn't a constant** — it reads
`NSApp.effectiveAppearance` at access time and returns the light or dark pair. Since those palettes are
static colours (unlike system semantic ones, which re-resolve when the appearance changes), the store
subscribes to `NSApp.effectiveAppearance` via KVO and bumps `generation` so everything repaints;
verified with a scratchpad script that the observer fires on every appearance change.

**Disk operations funnel through one place.** `FileOperationService` and `ArchiveService` don't run
their own queues; every copy/move/duplicate/trash/rename and every archive create/extract/list is
submitted to `DiskOperationQueue.shared`, an `OperationQueue` capped at `maxConcurrentOperationCount
= 3` app-wide. Pause/cancel for a single operation goes through `OperationControl` (a plain
thread-safe token, not tied to the queue): for in-process loops (copy/move) it's a blocking wait
checked between items; for archive operations (external `zip`/`unzip`/`tar` processes) it's
`SIGSTOP`/`SIGCONT`/`terminate()` — note cancel-while-paused must `SIGCONT` before `terminate()`, or
the signal just queues against a stopped process and nothing happens.

**Workspaces are real directories full of symlinks**, not an abstract list. `WorkspaceStore` manages
folders under `~/Library/Application Support/Marlia/Workspaces/`; "adding" a file creates a symlink
inside a workspace folder pointing at the original (never copies/moves it), so opening a workspace is
just normal directory navigation and virtually every existing pane feature (sort, context menu, trash,
rename, Get Info) works on it for free — deleting an item from a workspace only ever removes the
symlink because `FileManager` operations act on the link itself, not its target. Copy/move/drag *into*
a workspace folder is intercepted in `AppState.transfer` (via `WorkspaceStore.isWorkspaceFolder`) and
redirected to `WorkspaceStore.add` — it creates symlinks, never real copies, same as "Add to
Workspace". Note when verifying: Marlia deliberately displays a symlink's *resolved* size/thumbnail
(plus an arrow badge, `SymlinkBadge`), so a linked file looks like a full copy in the UI — check with
`ls -la` on the workspace folder, not by eye.

**The "final symlink component is not followed" gotcha applies to more APIs than FileManager.** All
confirmed empirically in this codebase: `resourceValues(forKeys:)`/`contentsOfDirectory` (handled in
`FileItem.init` — resolves for type/size but keeps the link as `url` so rename/trash act on the link),
`navigate(to:)` callers (must `.resolvingSymlinksInPath()` first or `reload()` throws `ENOTDIR`),
`NSWorkspace.icon(forFile:)` (returns a blank generic icon for a link — handled in `IconCache`), and
`QLThumbnailGenerator` (fails outright with "file doesn't exist" — handled in `ThumbnailCache`). When
adding any new call that takes a file path/URL, assume it has this problem until proven otherwise.

**List view is a hand-rolled AppKit `NSTableView`, not SwiftUI's `Table`.** SwiftUI's `Table` was the
original implementation, but it swallows mouse/gesture handling for anything attached to its row
content — `.onTapGesture`, `.simultaneousGesture`, `.highPriorityGesture`, and even `.onDrag` on
row/cell content all broke native click-to-select at some point, confirmed on every column (not just
one) as of 2026-07-16. Since dragging a file/folder from *any* point in an already-selected row (not
just a narrow icon hot-zone) is core file-manager functionality, List view was rewritten in
`Views/FileTableView.swift` as an `NSViewRepresentable`-wrapped `NSTableView` subclass
(`FileNSTableView`) that implements `NSTableViewDataSource`'s drag-source methods
(`tableView(_:pasteboardWriterForRow:)`) directly — AppKit's own mouseDown-to-drag-threshold tracking
loop handles the drag natively, so there's no SwiftUI gesture layered on top to compete with selection.
This also gave proper multi-file drag (drag any selected row, the whole selection goes) for free, which
the old per-row `.onDrag` never had (it only ever dragged the single item the closure was attached to).
Click-to-rename, sorting (header click → `NSSortDescriptor`), context menu (native `NSMenu` from
`PaneView.contextNSMenu(for:)`), and Enter/Delete key handling are all reimplemented by hand in
that file — see its doc comments before changing selection/rename/drag behavior there. If you're
tempted to go back to SwiftUI's `Table` for List view, don't — full-row drag has already failed there
multiple times in exactly this codebase, on every column.

**Icons view is a hand-rolled AppKit `NSCollectionView`** (`Views/FileIconsView.swift`), for a
performance reason on top of the drag one: the old SwiftUI `LazyVGrid` re-evaluated *every* cell on
each selection change — measured ~200 cell/overlay rebuilds per arrow step — so keyboard navigation
felt laggy. `NSCollectionView` does selection, arrow navigation, autoscroll and rubber-band natively
(no SwiftUI re-render), so a step costs ~nothing. Double-click/click-to-rename/multi-file-drag/
drop-on-folder/context-menu are hand-implemented exactly like `FileNSTableView`. Two gotchas that bit
during the rewrite: (1) `NSCollectionViewItem`'s built-in `textField`/`imageView` outlets are nil
unless you assign them — the name hit-test for click-to-rename reads `item.textField`, so it must
point at the real label; (2) the item height must fit two text lines or the selection highlight
clips the second line, and the label needs `truncatesLastVisibleLine` for the "…". That two-line cap is for *display* only: while a name is
being renamed the label grows to fit the whole thing and spills outside the cell, since editing a
long name blind was the alternative. Three things make that work and should not be undone — the
cell is raised above its neighbours (later rows are added to the hierarchy afterwards and would
paint over it) and this happens *before* first responder is taken (re-inserting the view into the
hierarchy drops focus and editing never starts); the container sets `clipsToBounds = false` on
macOS 14+, where `NSView` gained that property and the old "NSView doesn't clip" assumption no
longer holds; and the height is recomputed on every text change, not just on entry, so a long name
typed by hand isn't cut off either. The cell's own frame never changes, so the grid doesn't jump.

**`AppState.activate(_:)` dedups the active-pane switch.** `activeSide` is `@Published`; assigning it
unconditionally on every click (even in the already-active pane) fired `objectWillChange` and
re-rendered the whole window. Click handlers call `appState.activate(side)`, which assigns only on a
real change. Same class of fix as the `ContentView` narrowing (it observes three derived `@Published`
values on `AppState`, not the panes, so a selection step doesn't invalidate the window).

**Columns view is a per-column AppKit `NSTableView`** (`ColumnTableView.swift`), moved off SwiftUI
2026-07-21 for the same performance reason as Icons (SwiftUI re-evaluated every row of every column on
each selection step, so arrow nav "jellied"). The SwiftUI layer (`fileColumns` in
`PaneView+Columns.swift`) only lays the columns out horizontally in a `ScrollView(.horizontal)`; each
column is one `ColumnTableView` (a single-column `NSTableView`: icon + name + folder chevron). Preview,
resize, and horizontal auto-scroll stay on SwiftUI because they operate on *column* frames, not rows.

A column's **role** is `isActive` (`isActive == (column.id == currentURL)`, i.e. the last/current
column). The active column is selectable — native selection, `↑↓`, inline rename, keyboard; a
`tableViewSelectionDidChange` pushes native selection into `model.selection`, and `updateNSView`
pushes model → native (guarded by `isSyncingSelection`). Parent/preview columns are **not** selectable
(`selectionHighlightStyle = .none`, `deselectAll`); a click on their row goes to `onRowClick` →
`handleColumnClick`, which `navigate`s into that column (collapsing everything to its right). Keyboard
for the active column is `ColumnNSTableView.keyDown` → `onKeyCommand` → `handleActiveColumnKey`
(→/←/Return/Delete/Tab), while `↑↓` fall through to the table's native row navigation. The shared
lesson still holds (List/Icons/Columns): pick exactly one owner — SwiftUI gestures or AppKit events —
per interaction surface.

Gotchas confirmed during the Columns rewrite (all still load-bearing):
- **Empty-space clicks must reach the table.** `ColumnNSTableView.layout()` stretches the table to
  fill the clip view's height so a click *below* the last row registers (`row(at:) == -1`) instead of
  falling through — that's what makes deselect-on-empty-click work at all.
- **Deselect-on-empty-click is explicit.** `super.mouseDown` on empty table space did *not* reliably
  propagate the native deselect to the model, so `onEmptyClick` clears `model.selection` itself (active
  column) or `navigate`s into the column (parent).
- **Empty/parent clicks clear the stale `previewColumn`.** `updatePreviewColumn` early-returns for a
  file/empty selection (it never collapses a preview to avoid keyboard-nav jitter), so an empty click
  or a parent-row click sets `previewColumn = nil` directly, otherwise the right column wouldn't
  collapse.
- **Drop into a column force-reloads the preview.** `acceptColumnsDrop` sets `previewColumn = nil`
  before `updatePreviewColumn`, because that function's "same folder → don't re-read" guard would
  otherwise leave a dropped-into preview column showing stale contents.
- **Horizontal over-scroll is killed on the backing `NSScrollView`.** `ColumnsScrollAnchor.FlippedView`
  sets `enclosingScrollView?.horizontalScrollElasticity = .none` in `viewDidMoveToWindow` — SwiftUI's
  `.scrollBounceBehavior` would do this but needs macOS 14; without it the columns rubber-band sideways
  even when they fit.

**Columns navigation is Finder-style select-vs-enter, not click-to-enter.** A single click on a folder
*selects* it (focus stays on the folder); it does **not** navigate in. The folder's contents appear to
the right as a **preview column** (`previewColumn`, held separately from `columnChain` so the
`isLastColumn == currentURL` invariant is preserved, and spliced in only for rendering via
`displayedColumns`). `updatePreviewColumn` rebuilds it on selection change: deciding *what* to preview is
synchronous and cheap, but the folder read is **debounced ~150ms and run off-main** (`previewLoadTask` +
`loadPreviewItems` via `Task.detached`), so holding ↑/↓ across folders doesn't stat the disk on every
step; a newer selection cancels the in-flight load, and the result is re-checked against the current
selection before it's applied. It deliberately does **not** collapse the preview when selection moves to
a file (only replaces it for another folder, clears it on `currentURL` change) — collapsing on every file
click made the UI jitter. Entering a folder (making it `currentURL`) happens only via double-click,
Return, or → (`enterSelectedFolder`, which also selects the first child so keyboard focus is visible);
← (`goToParentColumn`) goes up and re-selects the folder you came from. After either, `keyFocusTrigger`
is bumped so the newly-active `ColumnTableView` re-grabs first responder (via its `focusRequestTrigger`
→ `makeFirstResponder`) and `↑↓` continue in the column you land in — otherwise the new column has the
selection but no keyboard focus.

**Column auto-scroll uses AppKit `scrollToVisible`, never `ScrollViewReader`.** The requirement is
minimal-intervention (scroll only enough to reveal the rightmost column, nothing if already visible) —
`ScrollViewProxy.scrollTo(anchor:)` can't do that (it always aligns to an anchor, which caused spurious
scrolling when clicking an already-visible column). Instead `ColumnsScrollAnchor` is an inert flipped
`NSView` placed as `.background` of the columns `HStack` (inside the SwiftUI `ScrollView`); calling
`scrollToVisible(columnFrame)` on it scrolls the enclosing `NSScrollView` minimally. Column frames come
from `ColumnFramesKey` (columns are an eager `HStack`, so their frames are reliable).
A just-appeared column isn't measured yet → `scrollToActiveColumn` stashes `pendingColumnScroll` and the
`ColumnFramesKey` `onPreferenceChange` finishes the scroll; the actual `ensureVisible` is wrapped in
`DispatchQueue.main.async` so layout settles first (otherwise it scrolls one step behind). Scrolling
fires only when the rightmost column changes (nav or preview), never on plain selection.

**Renaming a folder that is the pane's `currentURL` (or an ancestor of it) is possible in Columns**
— clicking the name of a sole-selected folder renames it (same as files), and entering + renaming an
ancestor is reachable. `AppState.rename`'s completion therefore can't blindly `pane.reload()` (the old
path is gone); it detects when the renamed folder's path is a prefix of `pane.currentURL` and
`navigate`s to the rewritten path instead. Every other caller (List, Icons, renaming a sibling in the
current dir) still hits the plain `reload()` branch.

**The main menu is hand-built AppKit `NSMenu`, not SwiftUI `.commands`** (`App/MainMenu.swift`,
`MainMenuController`). SwiftUI's `.keyboardShortcut` takes a static `KeyEquivalent`, can't express
function keys (that's why F5/F6 were dead for so long — AppKit warns and ignores `.function`), and
gives no guarantee the menu rebuilds when a shortcut changes. `NSMenuItem.keyEquivalent` is a plain
property, so `refreshShortcuts()` re-applies bindings live. Menu items and the panes' key handling
share one source of truth: `ShortcutStore` in `Models/KeyboardShortcuts.swift`. A `Shortcut` stores
**both** a `keyCode` (used to match `NSEvent` in the panes — layout-independent) and a `character`
(used for `NSMenuItem.keyEquivalent`, which AppKit matches by character); storing both avoids a
layout-dependent `UCKeyTranslate` conversion, since a shortcut recorder gets both from one `NSEvent`.
Modifier normalisation deliberately drops `.function`/`.numericPad` — AppKit always sets them on
arrows/Enter, so without stripping them a bare arrow would never match. Because the menu is AppKit,
commands reach the focused window's `AppState` through `AppStateRegistry.activeState` (keyed off
`NSApp.keyWindow`), not SwiftUI's `@FocusedValue`.

**Sidebar rows must stay gesture-free.** Favorites reordering uses `List(selection:)` + `.tag(url)`
+ `.onMove`; a `Button` or `.onTapGesture` on row content silently disables `List`'s reorder-drag
recognition (confirmed with an isolated test app — plain rows reorder, Button rows don't).
Navigation therefore happens through the selection binding, and the row highlight is *derived* from
the active pane's `currentURL` (a computed `Binding` in `SidebarView`), not stored click state — it
clears itself when the user navigates away by any means.

**Tab switches panes via per-view keyDown handlers** (`FileNSTableView.keyDown` for List,
`CollectionView` keyDown for Icons, `ColumnNSTableView.keyDown` → `handleActiveColumnKey` for Columns),
deliberately *not* a global `.keyboardShortcut(.tab)` menu shortcut — that would swallow Tab
everywhere, including field-to-field tabbing in rename/search/path editors. No-op when the second pane
is hidden.

**Rename is true inline editing everywhere, not a popup.** An earlier version used a single shared
`.alert("Rename", ...) { TextField(...) }` across all three view modes; it was replaced because
SwiftUI wouldn't reliably refresh the `TextField`'s displayed value when re-invoking rename for the
*same* item twice in a row (e.g. Cancel, then click rename again) — the bound `@State` technically
didn't change, so the alert's field kept showing stale/blank text. There is no general workaround for
that class of bug living in `.alert()`'s TextField support, so rename was moved to real inline editing
instead, matching Finder. Now that all three modes are AppKit, each drives its own native cell editor:
List via `NSTableView.editColumn(_:row:with:select:)` (`FileNSTableView.beginEditingName`), Columns
via the same on its single-column table (`ColumnNSTableView.beginEditingName`), Icons via the
`NSCollectionViewItem`'s `textField` — all with `NSTextFieldDelegate` methods for
Enter-to-commit/Escape-to-cancel. `PaneView.beginRename(_:)` is the single entry point; it branches on
`model.viewMode` and pokes the right mode's edit-request (`listEditRequestID` / `iconEditRequestID` /
`columnEditRequestID`), which the corresponding `NSViewRepresentable` picks up in `updateNSView`.

**View keyboard focus** is maintained per mode by the mode's own `NSViewRepresentable`, which grabs
first responder only on an edge — the pane becoming active, or an explicit focus-trigger counter bumped
after every item click (`keyFocusTrigger` for Icons/Columns, `tableFocusTrigger` for List, both bumped
in `PaneView.onChange(of: isActive)` and by click handlers). Each representable re-grabs in
`updateNSView` only when its trigger changed (`focusRequestTrigger` in `FileIconsView`/`ColumnTableView`
/`FileTableView`); grabbing unconditionally on every render would steal focus from other active text
fields (inline rename, search, path editor). (An earlier shared `KeyCommandView` NSView did this job
while Icons/Columns were still SwiftUI; it was removed once both moved to their own AppKit views.)

**SwiftUI `@FocusState` does not work for the search/filter bars — their fields are AppKit**
(`FocusableTextField` in `PaneInteractionViews.swift`). Both bars are opened by a main-menu command,
and AppKit's menu lives outside SwiftUI: at the moment the bar appears, first responder is still the
mode's table (`FileNSTableView` / `IconCollectionView` / `ColumnNSTableView`), and setting `@FocusState`
in `.onAppear` does **not** take it away from that AppKit sibling — the field showed up unfocused and
had to be clicked (reported from live use, then reproduced in an isolated harness: a window whose first
responder is an `NSTableView`, then a SwiftUI bar inserted above it). Deferring the assignment by one
runloop turn was tried first and is not what fixed it. The working approach is the same one the three
view modes already use on themselves: a plain `NSTextField` plus an explicit
`window.makeFirstResponder(field)` in `updateNSView`, driven by a trigger counter bumped in `.onAppear`
(`searchFocusTrigger` / `filterFocusTrigger`). Esc and Return are handled by the field's
`NSTextFieldDelegate` rather than `.onExitCommand`/`.onSubmit`, for the reason this codebase repeats
everywhere: one owner per interaction surface, not two competing ones.

Esc must also close the bars when focus stayed in the list, so the three view classes override
`cancelOperation(_:)` and call `PaneView.handleEscape()` through an `onEscape` closure. It has to be
`cancelOperation` rather than a keyCode check in `keyDown`: their `keyDown` forwards unrecognised keys
to `super`, and AppKit turns Esc into `cancelOperation` from there. Inline rename is unaffected — while
a name is being edited the cell's text field holds first responder and gets the Esc itself.

**Menu key equivalents fire from items that are hidden *and* from items that are disabled.**
The nine ⌥1…⌥9 favourite slots are built eagerly in `goMenu()` rather than in `menuNeedsUpdate`,
because a shortcut is matched against items that already exist — an eagerly built item works before
the menu has ever been opened (measured by calling `performKeyEquivalent` on a never-opened menu).
The natural next assumption — that hiding the unused slots also disables their shortcuts — is **false**:
in the same harness, hidden items fired, and so did disabled ones. Hiding is therefore cosmetic only,
and the bounds check in `AppState.goToFavorite(at:)` is what actually makes ⌥7 harmless when there are
three favourites. Don't rely on `isHidden`/`isEnabled` to suppress a key equivalent.

**A menu-only command's default shortcut must contain ⌘, or the panes eat it.** The favourite slots
were first bound to bare ⌥1…⌥9 and did nothing at all. The menu was built correctly — a direct
`performKeyEquivalent(⌥1)` on the real menu did fire the item — but the same event pushed through
`NSApp.sendEvent` never reached the menu: the focused view's `keyDown` sees it first, `ShortcutStore`
matches it to `goToFavorite1`, the mode's `switch` has no case for it and falls into
`default: super.keyDown(with:)`, which consumes the key. Adding ⌘ fixed it — verified by the same
in-app probe, where `NSApp.sendEvent` then did reach the handler. So: any command that only ever lives
in the menu needs ⌘ in its binding, otherwise the three view modes silently swallow it.

Favourites are addressed by **position**, not by remembered path, so ⌥⌘1 follows whatever the user
dragged to the top of the sidebar — the same behaviour as Places in Dolphin. ⌘1…⌘3 were unavailable
(view modes, following Finder) and ⌃1…⌃9 collide with the system's Spaces switching. All nine key codes
were verified against the live keyboard layout via `UCKeyTranslate` (the digit row is not contiguous:
5, 6, 7, 8, 9 are 23, 22, 26, 28, 25), and the whole registry was swept for duplicate bindings.

**The info panel is a third `NSSplitViewItem` with its own hosting controller, and that placement
is the whole point** (`Views/InspectorView.swift`, wired in `MarliaSplitViewController`). It has to
observe the active pane's selection to show anything useful — but `PanesRootView` deliberately does
**not** observe the panes (see its own comment: it reads three derived values off `AppState` precisely
so that an arrow-key step doesn't invalidate the whole window). Putting the inspector inside that tree
would have reintroduced exactly the re-render storm that design exists to prevent. A separate
`NSHostingController` keeps its redraws to itself. Inside it the split is two levels: `InspectorHostView`
observes `AppState` (to follow which side is active) and hands the current `PaneViewModel` to an inner
view that observes it — so switching panes rebuilds the inner view against the other model.

Selection changes are **debounced ~150ms** before anything is read, the same treatment the Columns
preview column gets and for the same reason: a held arrow key walks across dozens of items, each of
which would otherwise mean reading metadata and, for a folder, walking its subtree for a size.

`ItemDetailsView` (in `GetInfoView.swift`) is shared by the Get Info window and the panel, and it loads
through `.task(id: url)` rather than `.onAppear`. The Get Info window gets a fresh instance per file so
`onAppear` was enough there, but the panel feeds new URLs into **one** reused instance. The first attempt
at a fix — adding `.id(url)` — silently didn't work because of modifier order: `.id(url)` came *before*
`.onAppear`, so only the inner subtree got a new identity while the `onAppear` modifier sat outside that
boundary and never fired again. Measured in an isolated harness: `.id` before `.onAppear` fires once,
`.id` after it fires on every change, and `.task(id:)` fires on every change regardless of order. Prefer
`.task(id:)` for reload-on-input — it does not depend on where the modifier sits in the chain. Visibility is per-window state on `AppState` (`showInspector`),
persisted in `WindowState` with `decodeIfPresent` like `showSecondPane` before it, and applied by the
window controller through a Combine subscription — verified round-trip: a session saved by an older
build (no such key) still restores, and a session saved now carries it.

**Undo is a stack whose entries are validated against the disk before each step**
(`Models/UndoHistory.swift`). It used to be a single `lastAction` plus an `undone` flag, so a second
⌘Z did nothing. The part that makes this more than "turn the field into an array": entries hold
*paths*, and paths change behind the app's back — a file renamed by hand in Finder, deleted, a volume
unmounted. Every `FileManager` call on the undo path goes through `try?`, so an inapplicable entry
would fail silently while the stack advanced — ⌘Z would *appear* to work and change nothing. So
`UndoHistory.pruned(_:undoing:)` filters each entry against what actually exists and returns nil when
nothing is left; `undo()` then walks down to the first applicable entry, which also makes the stack
self-cleaning. Pruning is per-pair rather than all-or-nothing: if one of ten copied files was deleted
by hand, undoing the other nine is still the right answer.

`canUndo` is deliberately the cheap `!undoStack.isEmpty` and does **not** verify applicability — doing
that on every menu open would stat every path in every entry, and a single entry can hold thousands of
pairs. The menu can therefore be enabled when the top entries turn out stale; the first ⌘Z discards
them, and once nothing is left the item disables itself.

Two details worth keeping: redo of a trash action rewrites its pairs, because the Trash assigns a new
name inside itself each time and the next undo would otherwise look at a stale path; and the Edit menu
needs `autoenablesItems = false` for the disabling to take at all — AppKit re-enables items that have a
target, and every item here is a `ClosureMenuItem` that targets itself (the same trap already
documented for the View menu's column submenu). The type is kept free of UI dependencies so a
scratchpad harness can compile and exercise it against a real directory — multi-step undo/redo, redo
being cut off by a new operation, stale and partially-stale entries, a name reoccupied by an unrelated
file, and the depth limit.

**Batch rename runs in two phases, and that is a data-safety requirement, not caution**
(`FileOperationService.performBatchRename`). A batch may contain files swapping names with each other
(`a→b`, `b→a`) or shifting along a chain (`1→2`, `2→3`), so renaming them one by one in a single pass
would overwrite a file the loop has not reached yet — silently destroying data. Every item therefore
first moves to a unique temporary name in the same directory, and only then to its target, by which
point no original name is still occupied. A phase-1 failure leaves that file untouched and is simply
skipped; a phase-2 failure moves the file **back to its original name**, because leaving it under the
temporary name would make it vanish from the pane (the name starts with a dot). Verified against a real
directory in a scratchpad harness that compiles the actual service file: swap, three-way cycle,
target-name-taken, invalid name, and "no `.marlia-rename-` leftovers".

The function is static and synchronous because it has two callers — the queued operation and undo
(`AppState.undoLast`), which works with `FileManager` directly. Undo of a batch rename is the same
call with the pairs reversed, for the same reason: an undo of a cycle *is* a cycle.

**The name rules live in `Models/BatchRenamePlan.swift`, which deliberately has no dependencies
beyond Foundation** — that is what lets a scratchpad script compile and exercise the real code instead
of a restatement of it (`FileOperationService.isValidItemName` is a thin forward into it, so there is
one source of truth about what a legal file name is). Keep it that way: an earlier revision put
`PendingBatchRename` in that file, which dragged in `PaneViewModel` and broke standalone compilation;
the type now lives next to the other `Pending*` types in `MarliaApp.swift`.

**`PaneViewModel.items` is the *filtered* list, not the raw listing.** The filter bar (⌥⌘F) narrows
what is on screen without touching the disk, so the full listing lives in a private `allItems` and
`items` is the visible slice; `setLoaded(_:)` is the single door through which a read directory enters
the pane, and it is where the FSEvents de-dup now happens (comparing what is actually displayed —
comparing the raw list would fire pointless re-renders whenever a filtered-out file changed). All three
view modes render `items`, which is why filtering works in all of them without any of them knowing it
exists. Two deliberate properties: the selection is **not** pruned when the filter hides items (so
clearing the filter brings a selection back intact, while operations stay safe because `selectedItems`
is computed from the visible list), and navigating to another folder clears the filter text but leaves
the bar open — a filter carried into a new folder would show a near-empty list for no visible reason.

## Known limitations (not bugs to "fix" reflexively)

- List view drag-selecting rows over empty space highlights rows but draws no rubber-band rectangle —
  that's stock `NSTableView` behavior and Finder's own List view does the same (verified against both
  a minimal `NSTableView` repro and Finder). The drawn rectangle exists only in Icons view.
- Pause on copy/move/duplicate stops *between* files, not mid-file — `FileManager.copyItem` copies a
  single file atomically with no progress hook to interrupt.
- SMB connections don't save the password to Keychain (re-prompts every connect); an unreachable
  server times out after ~60s, matching Finder's own behavior.
