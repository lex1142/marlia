import Foundation

/// The size of a folder's contents, for Calculate Folder Sizes (⌥⌘S).
///
/// Logical size (the same `fileSize` the Size column shows for files), summed over every
/// regular file inside, hidden ones included. Symlinks are not followed — a link to a huge
/// folder elsewhere costs nothing here — and package contents (.app, .photoslibrary) count,
/// because that data really is inside. Unreadable subfolders are skipped rather than
/// aborting the walk, so the result is a lower bound when permissions get in the way.
///
/// Foundation only, so a scratchpad script can check it against `du`.
enum FolderSize {

    /// nil when cancelled (checked every few hundred entries) or when the folder can't be
    /// opened at all.
    static func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> Int64? {
        // The enumerator doesn't follow a symlink as the starting point either (see the
        // "final symlink component" note in CLAUDE.md), so a Workspace link is resolved first.
        let root = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        var visited = 0
        for case let file as URL in enumerator {
            visited += 1
            if visited % 512 == 0, isCancelled() { return nil }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return isCancelled() ? nil : total
    }
}
