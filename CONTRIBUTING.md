# Contributing to Marlia

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/lex1142/marlia/issues/new/choose) using the bug report template. Please include:

- your macOS version;
- the view mode you were in (List, Icons or Columns);
- what happened and what you expected instead.

## Building

```sh
./build.sh --run
```

`build.sh` holds the one list of source files. **When you add a new `.swift` file, add it there too.**
Otherwise it silently won't be part of the build. CI runs the same script.

## Verifying changes

There is no automated test suite, so please describe in your pull request how you checked the change:

- **Logic changes** (parsing, path handling, undo, renaming rules): a small standalone `swift script.swift`
  that exercises the real code against a temporary directory is the preferred check.
  `Models/BatchRenamePlan.swift` and `Models/UndoHistory.swift` deliberately depend on Foundation only,
  so they can be compiled this way.
- **UI changes:** build, launch and try the behavior in all three view modes when it's relevant.
  Screenshots or a short recording help a lot.

## Things to keep in mind

- **CI compiles with Swift 5.10** (the `macos-14` runner), which is stricter than Swift 6 in one way:
  a concurrent closure (`Task { … }`, a `DiskOperationQueue` operation) must not capture a mutable `var`
  from the surrounding scope. Copy it into a `let` first. A green local build doesn't prove CI will pass.
- **The deployment target is macOS 13.5.** Check API availability against 13.5, not against your SDK.
  `./build.sh` passes `-target arm64-apple-macosx13.5`, so such errors show up locally.
- **List, Icons and Columns are AppKit views** (`NSTableView` / `NSCollectionView`) wrapped for SwiftUI.
  That's deliberate: SwiftUI's `Table` and `LazyVGrid` broke drag-from-any-point and were slow on
  keyboard navigation. Each interaction surface has exactly one owner, either SwiftUI or AppKit.
- `CLAUDE.md` has detailed architecture notes and the reasons behind many non-obvious decisions.
  Read the relevant section before reworking a subsystem.

## Pull requests

- Keep each pull request focused on one change.
- Match the surrounding code style, including the comments: they explain *why*, not *what*.
- By contributing, you agree that your contributions are licensed under the GPL-3.0.
