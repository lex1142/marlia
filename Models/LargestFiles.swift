import Foundation

/// The biggest items anywhere under a folder — Path Finder's size browser, as a list:
/// where did the space go, and what is worth deleting.
///
/// Files count individually; a package (.app, .photoslibrary, .bundle) counts as ONE item
/// with its whole size, because to a user it is one thing — deleting a file from inside an
/// app or a photo library is never the answer. Symlinks are not followed (a link to a huge
/// folder elsewhere takes no space here), hidden files are included (caches are a classic
/// answer to "where did my disk go"), unreadable folders are skipped.
///
/// Foundation only, so a scratchpad script can check it against `find`/`du`.
enum LargestFiles {
    struct Entry: Equatable, Identifiable {
        let url: URL
        let size: Int64
        let isPackage: Bool
        var id: URL { url }
    }

    struct Result: Equatable {
        /// Largest first, at most `limit`.
        var entries: [Entry]
        /// How many files and packages were looked at.
        var scanned: Int
        /// The whole tree's size, for "these N items take X of Y".
        var total: Int64
    }

    /// nil when cancelled. `progress` is called every few thousand items with the count so
    /// far (from the calling thread — the caller hops to the main actor itself).
    static func scan(_ root: URL, limit: Int = 200,
                     isCancelled: () -> Bool = { false },
                     progress: (Int) -> Void = { _ in }) -> Result? {
        // The enumerator doesn't follow a symlink as the starting point (see CLAUDE.md).
        let start = root.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: start, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return nil }

        var top: [Entry] = []       // kept sorted, largest first, at most `limit`
        var scanned = 0
        var total: Int64 = 0

        func offer(_ entry: Entry) {
            total += entry.size
            scanned += 1
            guard top.count < limit || entry.size > top[top.count - 1].size else { return }
            // Binary search for the insertion point (largest first).
            var low = 0, high = top.count
            while low < high {
                let mid = (low + high) / 2
                if top[mid].size >= entry.size { low = mid + 1 } else { high = mid }
            }
            top.insert(entry, at: low)
            if top.count > limit { top.removeLast() }
        }

        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited % 2000 == 0 {
                if isCancelled() { return nil }
                progress(scanned)
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if values.isPackage == true {
                    enumerator.skipDescendants()
                    if let size = FolderSize.measure(url, isCancelled: isCancelled) {
                        offer(Entry(url: url, size: size, isPackage: true))
                    }
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            offer(Entry(url: url, size: Int64(values.fileSize ?? 0), isPackage: false))
        }
        if isCancelled() { return nil }
        return Result(entries: top, scanned: scanned, total: total)
    }
}
