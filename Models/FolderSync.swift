import Foundation

/// Synchronize Folders — Path Finder's Folder Sync, Total Commander's "Synchronize
/// directories": compare two folder trees, show what differs, and on request make them
/// match. The recursive big brother of Compare Folders (⇧F2), which looks at one level and
/// only selects.
///
/// Comparing (`scan`):
/// - Recursive. A folder present on both sides is walked into; a folder present on one side
///   only is ONE item (copying it copies its whole tree).
/// - Names match like Compare Folders: case-insensitively, with Unicode normalization.
/// - Files compare by modification date (2-second tolerance — FAT/exFAT keep 2 s precision)
///   and, at equal dates, by size. Equal date, different size is a *conflict*: no telling
///   which copy is right, so it is skipped unless the user picks a direction.
/// - Symlinks are compared and copied as links, never followed. `.DS_Store` and `._`
///   AppleDouble files are ignored — they are Finder's bookkeeping, not the user's data.
///
/// Carrying it out (`execute`), designed so that no step can lose data:
/// - A replaced file goes to the Trash, and only after the new copy is completely written
///   (it is copied under a temporary name next to the target first). A failed copy leaves
///   the old file untouched.
/// - "Delete" means the Trash too.
/// - Copies go through PlainCopy, so a FAT/exFAT stick gets no `._` twins.
///
/// Foundation only: a scratchpad harness runs it against real directories.
enum FolderSync {

    struct Side: Equatable {
        let size: Int64
        let modified: Date
        let isFolder: Bool
        let isSymlink: Bool
    }

    enum Status: Equatable {
        case onlyLeft, onlyRight, leftNewer, rightNewer
        /// Same date (within tolerance), different size.
        case conflict
        /// A file on one side, a folder of the same name on the other.
        case kindMismatch
        case same
    }

    enum Action: String, CaseIterable, Identifiable {
        case toRight, toLeft, skip, deleteLeft, deleteRight
        var id: String { rawValue }
    }

    enum Direction: String, CaseIterable, Identifiable {
        case both, leftToRight, rightToLeft
        var id: String { rawValue }
    }

    struct Item: Identifiable, Equatable {
        /// Relative path as spelled on each side ("Photos/IMG_1.jpg"); nil where missing.
        let leftPath: String?
        let rightPath: String?
        let left: Side?
        let right: Side?
        let status: Status
        var action: Action
        var id: String { (leftPath ?? rightPath ?? "").lowercased() }
        var displayPath: String { leftPath ?? rightPath ?? "" }
        var isFolder: Bool { (left ?? right)?.isFolder == true }
    }

    static let dateTolerance: TimeInterval = 2

    // MARK: Compare

    /// Every difference between the trees (identical files included, with status .same, so
    /// the window can show them on request). nil when cancelled.
    static func scan(left: URL, right: URL, direction: Direction = .both, deleteExtras: Bool = false,
                     isCancelled: () -> Bool = { false }) -> [Item]? {
        var items: [Item] = []
        var cancelled = false
        func walk(_ leftDir: URL, _ rightDir: URL, prefixLeft: String, prefixRight: String) {
            if cancelled || isCancelled() { cancelled = true; return }
            let l = entries(in: leftDir), r = entries(in: rightDir)
            let keys = Set(l.keys).union(r.keys).sorted()
            for key in keys {
                let le = l[key], re = r[key]
                let lp = le.map { prefixLeft + $0.name }
                let rp = re.map { prefixRight + $0.name }
                if let le, let re, le.side.isFolder, re.side.isFolder, !le.side.isSymlink, !re.side.isSymlink {
                    walk(leftDir.appendingPathComponent(le.name), rightDir.appendingPathComponent(re.name),
                         prefixLeft: lp! + "/", prefixRight: rp! + "/")
                    if cancelled { return }
                    continue
                }
                let status = compare(le?.side, re?.side)
                items.append(Item(leftPath: lp, rightPath: rp, left: le?.side, right: re?.side, status: status,
                                  action: defaultAction(status, direction: direction, deleteExtras: deleteExtras)))
            }
        }
        walk(left.resolvingSymlinksInPath(), right.resolvingSymlinksInPath(), prefixLeft: "", prefixRight: "")
        return cancelled ? nil : items
    }

    static func compare(_ l: Side?, _ r: Side?) -> Status {
        switch (l, r) {
        case (nil, nil): return .same
        case (_?, nil): return .onlyLeft
        case (nil, _?): return .onlyRight
        case let (l?, r?):
            if l.isFolder != r.isFolder { return .kindMismatch }
            let delta = l.modified.timeIntervalSince(r.modified)
            if delta > dateTolerance { return .leftNewer }
            if delta < -dateTolerance { return .rightNewer }
            return l.size == r.size ? .same : .conflict
        }
    }

    /// What happens to an item unless the user changes it. One-way modes never write to
    /// the source side; extras on the target side are deleted only when asked.
    static func defaultAction(_ status: Status, direction: Direction, deleteExtras: Bool) -> Action {
        switch (direction, status) {
        case (_, .same), (_, .conflict), (_, .kindMismatch): return .skip
        case (.both, .onlyLeft), (.both, .leftNewer): return .toRight
        case (.both, .onlyRight), (.both, .rightNewer): return .toLeft
        case (.leftToRight, .onlyLeft), (.leftToRight, .leftNewer): return .toRight
        case (.leftToRight, .onlyRight): return deleteExtras ? .deleteRight : .skip
        case (.leftToRight, .rightNewer): return .skip
        case (.rightToLeft, .onlyRight), (.rightToLeft, .rightNewer): return .toLeft
        case (.rightToLeft, .onlyLeft): return deleteExtras ? .deleteLeft : .skip
        case (.rightToLeft, .leftNewer): return .skip
        }
    }

    /// The actions that make sense for an item (the per-row menu).
    static func possibleActions(for item: Item) -> [Action] {
        var actions: [Action] = []
        if item.left != nil { actions.append(.toRight) }
        if item.right != nil { actions.append(.toLeft) }
        actions.append(.skip)
        if item.left != nil { actions.append(.deleteLeft) }
        if item.right != nil { actions.append(.deleteRight) }
        return actions
    }

    private struct Entry { let name: String; let side: Side }

    private static func entries(in directory: URL) -> [String: Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else { return [:] }
        var result: [String: Entry] = [:]
        for url in urls {
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // contentsOfDirectory's values describe the link itself, not its target, so a
            // symlink to a folder reads as a non-folder here — exactly what we want.
            let side = Side(size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast,
                            isFolder: v.isDirectory == true, isSymlink: v.isSymbolicLink == true)
            result[key(name)] = Entry(name: name, side: side)
        }
        return result
    }

    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Carry out

    struct Failure: Equatable {
        let path: String
        let message: String
    }

    /// Performs every item whose action isn't .skip. `waitIfPaused` is called between
    /// items (it may block), `isCancelled` stops before the next one; `progress` gets the
    /// number done. Returns the failures — one item failing doesn't stop the rest.
    static func execute(_ items: [Item], left: URL, right: URL,
                        isCancelled: () -> Bool = { false },
                        waitIfPaused: () -> Void = {},
                        progress: (Int) -> Void = { _ in }) -> [Failure] {
        let leftRoot = left.resolvingSymlinksInPath(), rightRoot = right.resolvingSymlinksInPath()
        var failures: [Failure] = []
        var done = 0
        for item in items where item.action != .skip {
            waitIfPaused()
            if isCancelled() { break }
            do {
                switch item.action {
                case .toRight:
                    guard let lp = item.leftPath else { continue }
                    try place(leftRoot.appendingPathComponent(lp),
                              at: rightRoot.appendingPathComponent(item.rightPath ?? lp))
                case .toLeft:
                    guard let rp = item.rightPath else { continue }
                    try place(rightRoot.appendingPathComponent(rp),
                              at: leftRoot.appendingPathComponent(item.leftPath ?? rp))
                case .deleteLeft:
                    guard let lp = item.leftPath else { continue }
                    try FileManager.default.trashItem(at: leftRoot.appendingPathComponent(lp), resultingItemURL: nil)
                case .deleteRight:
                    guard let rp = item.rightPath else { continue }
                    try FileManager.default.trashItem(at: rightRoot.appendingPathComponent(rp), resultingItemURL: nil)
                case .skip:
                    continue
                }
            } catch {
                failures.append(Failure(path: item.displayPath, message: error.localizedDescription))
            }
            done += 1
            progress(done)
        }
        return failures
    }

    /// Puts a copy of `source` at `destination`. If something is already there it is
    /// replaced safely: the copy is written under a temporary name first, the old item goes
    /// to the Trash only then, and the copy takes its name. A failed copy leaves the old
    /// item exactly as it was.
    static func place(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: destination.path)
            || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil
        guard exists else {
            try PlainCopy.copyItem(source, to: destination)
            return
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".marlia-sync-\(UUID().uuidString)")
        try PlainCopy.copyItem(source, to: temporary)
        do {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        do {
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            // The old copy is in the Trash and the new one couldn't take its name: keep
            // the new one under a visible name rather than leaving a hidden temporary file.
            let fallback = destination.deletingLastPathComponent()
                .appendingPathComponent(destination.lastPathComponent + " (synced)")
            try? fm.moveItem(at: temporary, to: fallback)
            throw error
        }
    }
}
