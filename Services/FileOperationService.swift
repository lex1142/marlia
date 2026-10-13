import Foundation
import AppKit

enum TransferMode { case copy, move }

/// What to do when the destination already has an item with the same name.
enum ConflictAction { case replace, skip, keepBoth }

/// Performs copy/move/delete in the background — on the app-wide DiskOperationQueue
/// (see its comment), so concurrent operations from different windows/tabs don't
/// flood the disk with unbounded simultaneous tasks. transfer/duplicate take an
/// OperationControl for pause/cancel between items (see its comment) — the
/// granularity is "between files", not mid-file: FileManager.copyItem copies a file
/// atomically, with no access to progress within a single file.
final class FileOperationService {

    /// Copies/moves items into destination. `resolutions` holds the decisions for
    /// conflicting names (replace/skip/keepBoth), collected beforehand through the dialog;
    /// items without a conflict or without an entry in resolutions have no conflict —
    /// they're transferred as is. completion receives (from, to) pairs for the items
    /// actually transferred — the caller needs them to be able to undo the operation.
    func transfer(
        items: [FileItem],
        to destination: URL,
        mode: TransferMode,
        resolutions: [FileItem.ID: ConflictAction],
        control: OperationControl = OperationControl(),
        onProgress: @escaping @MainActor (Int) -> Void = { _ in },
        completion: @escaping @MainActor ([(src: URL, dst: URL)]) -> Void
    ) {
        DiskOperationQueue.shared.addOperation {
            var errors: [String] = []
            var performed: [(src: URL, dst: URL)] = []
            for (index, item) in items.enumerated() {
                control.waitWhilePaused()
                if control.isCancelled { break }
                defer {
                    let done = index + 1
                    Task { @MainActor in onProgress(done) }
                }
                let dst = destination.appendingPathComponent(item.name)
                // The target is the item itself — i.e. copying/moving it to where it
                // already is. For a move there's nothing to do, but copying into its own
                // folder is a meaningful "make a copy next to it" (file 2.txt), like ⌘D
                // and like Finder; previously such a paste simply didn't happen, the file
                // was silently skipped. The name is chosen below (uniqueURL); no conflict
                // dialog is needed here: there's nothing to overwrite the original with
                // but itself.
                let isCopyBesideItself = dst == item.url && mode == .copy
                if dst == item.url, !isCopyBesideItself { continue }

                // Copying a folder into itself/its own subfolder with a plain copyItem
                // would recurse forever (the fresh copy ends up inside the source and gets
                // copied again…). The copy is made via staging outside the source (below).
                // Moving into itself makes no sense — that's reported as an error.
                let withinSource = Self.destinationIsWithinSource(destination, source: item.url)
                if withinSource, mode == .move {
                    errors.append("\(item.name): a folder can’t be moved into itself")
                    continue
                }

                var finalDst = dst
                if isCopyBesideItself {
                    finalDst = Self.uniqueURL(for: dst)
                } else if FileManager.default.fileExists(atPath: dst.path) {
                    switch resolutions[item.id] ?? .keepBoth {
                    case .skip:
                        continue
                    case .replace:
                        // To the Trash rather than removeItem: what's being replaced is the
                        // user's existing data, and ⌘Z after a copy only deletes the copy
                        // itself, so after a permanent delete the original could never be
                        // recovered. On volumes without a Trash (network shares, some flash
                        // drives) trashItem throws — then a plain delete, otherwise the
                        // copy would fail with "file already exists".
                        var trashed: NSURL?
                        do {
                            try FileManager.default.trashItem(at: dst, resultingItemURL: &trashed)
                        } catch {
                            try? FileManager.default.removeItem(at: dst)
                        }
                    case .keepBoth:
                        finalDst = Self.uniqueURL(for: dst)
                    }
                }
                do {
                    if withinSource {
                        // A single copy: snapshot the source into a temporary folder OUTSIDE
                        // its subtree, then move the snapshot into place — no recursion (see
                        // copyIntoSelf).
                        try Self.copyIntoSelf(source: item.url, to: finalDst)
                    } else {
                        switch mode {
                        case .copy: try FileManager.default.copyItem(at: item.url, to: finalDst)
                        case .move: try FileManager.default.moveItem(at: item.url, to: finalDst)
                        }
                    }
                    performed.append((item.url, finalDst))
                } catch {
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            }
            // Snapshot into a let before handing off to a concurrent closure. Swift
            // 5.10 (which CI builds with, on the macos-14 runner) treats capturing a
            // mutable var as an error: "reference to captured var in
            // concurrently-executing code". Swift 6 accepts it thanks to region-based
            // isolation — which is why local builds were green while CI failed. The
            // copy is correct for both: the loop has finished by this point and the
            // value no longer changes.
            let collectedErrors = errors
            let collectedPairs = performed
            Task { @MainActor in
                if !collectedErrors.isEmpty { Self.showErrors(collectedErrors) }
                completion(collectedPairs)
            }
        }
    }

    /// Batch rename. Returns (old, new) pairs — the caller needs them for undo.
    func batchRename(_ plan: [(url: URL, newName: String)],
                     completion: @escaping @MainActor ([(from: URL, to: URL)]) -> Void) {
        DiskOperationQueue.shared.addOperation {
            let result = Self.performBatchRename(plan)
            Task { @MainActor in
                if !result.errors.isEmpty { Self.showErrors(result.errors) }
                completion(result.performed)
            }
        }
    }

    /// The rename runs IN TWO PHASES, and that's not excess caution.
    ///
    /// Selected files may swap names with each other (a→b, b→a) or shift along a chain
    /// (1→2, 2→3). Renaming them one by one in a single pass would overwrite a file the
    /// loop hasn't reached yet — i.e. silently destroy data. So first ALL of them move
    /// to unique temporary names in the same folder, and only then to their targets: by
    /// the second phase no original name is occupied anymore.
    ///
    /// Synchronous and static because it has two callers: the background operation
    /// above and undo (⌘Z), which in this app works with FileManager directly.
    static func performBatchRename(_ plan: [(url: URL, newName: String)])
        -> (performed: [(from: URL, to: URL)], errors: [String]) {
        let manager = FileManager.default
        var staged: [(temp: URL, final: URL, original: URL)] = []
        var performed: [(from: URL, to: URL)] = []
        var errors: [String] = []

        // Phase 1: to temporary names. A failure here leaves the file untouched, so no
        // rollback is needed — just skip it and carry on with the rest.
        for entry in plan {
            guard isValidItemName(entry.newName) else {
                errors.append("\(entry.url.lastPathComponent): \(invalidNameMessage)")
                continue
            }
            let directory = entry.url.deletingLastPathComponent()
            let temporary = directory.appendingPathComponent(".marlia-rename-\(UUID().uuidString)")
            do {
                try manager.moveItem(at: entry.url, to: temporary)
                staged.append((temporary, directory.appendingPathComponent(entry.newName), entry.url))
            } catch {
                errors.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Phase 2: to target names.
        for entry in staged {
            do {
                try manager.moveItem(at: entry.temp, to: entry.final)
                performed.append((entry.original, entry.final))
            } catch {
                // Leaving the file under its temporary name is not an option under any
                // circumstances — it would simply vanish from the pane (the name starts with
                // a dot). Put it back as it was.
                try? manager.moveItem(at: entry.temp, to: entry.original)
                errors.append("\(entry.original.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (performed, errors)
    }

    func trash(items: [FileItem], completion: @escaping @MainActor ([(original: URL, trashed: URL)]) -> Void) {
        DiskOperationQueue.shared.addOperation {
            var performed: [(original: URL, trashed: URL)] = []
            for item in items {
                var resultingURL: NSURL?
                if (try? FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)) != nil,
                   let trashed = resultingURL as URL? {
                    performed.append((item.url, trashed))
                }
            }
            let collectedPairs = performed
            Task { @MainActor in completion(collectedPairs) }
        }
    }

    /// A name that can safely be appended to a folder path: no path separator and not
    /// "."/"..". Otherwise appendingPathComponent builds a path OUTSIDE the current
    /// folder — verified: renaming to "../escaped.txt" moved the file one level up, and
    /// it simply disappeared from view. Finder doesn't accept such names either. One
    /// check for rename, creating a folder/file, archive names and workspace names.
    /// The rules live in BatchRenamePlan: it has no dependencies and is exercised by a
    /// real harness, and keeping a second copy of the same conditions here would mean
    /// them drifting apart.
    static func isValidItemName(_ name: String) -> Bool {
        BatchRenamePlan.isValidName(name)
    }

    /// Error text for the UI when a name fails isValidItemName.
    static let invalidNameMessage = "A name can’t be empty or contain “/”."

    func rename(item: FileItem, to newName: String, completion: @escaping @MainActor () -> Void) {
        // The last line of defense: the caller has already checked the name
        // (AppState.rename), but every rename goes through this one path — the check
        // is repeated here so a new caller can't bypass it by oversight.
        guard Self.isValidItemName(newName) else {
            Task { @MainActor in completion() }
            return
        }
        DiskOperationQueue.shared.addOperation {
            let dst = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            try? FileManager.default.moveItem(at: item.url, to: dst)
            Task { @MainActor in completion() }
        }
    }

    /// A copy next to the original ("file.txt" -> "file 2.txt").
    func duplicate(
        items: [FileItem],
        control: OperationControl = OperationControl(),
        onProgress: @escaping @MainActor (Int) -> Void = { _ in },
        completion: @escaping @MainActor ([(src: URL, dst: URL)]) -> Void
    ) {
        DiskOperationQueue.shared.addOperation {
            var errors: [String] = []
            var performed: [(src: URL, dst: URL)] = []
            for (index, item) in items.enumerated() {
                control.waitWhilePaused()
                if control.isCancelled { break }
                defer {
                    let done = index + 1
                    Task { @MainActor in onProgress(done) }
                }
                let dst = Self.uniqueURL(for: item.url)
                do {
                    try FileManager.default.copyItem(at: item.url, to: dst)
                    performed.append((item.url, dst))
                } catch {
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            }
            // Snapshot into a let before handing off to a concurrent closure. Swift
            // 5.10 (which CI builds with, on the macos-14 runner) treats capturing a
            // mutable var as an error: "reference to captured var in
            // concurrently-executing code". Swift 6 accepts it thanks to region-based
            // isolation — which is why local builds were green while CI failed. The
            // copy is correct for both: the loop has finished by this point and the
            // value no longer changes.
            let collectedErrors = errors
            let collectedPairs = performed
            Task { @MainActor in
                if !collectedErrors.isEmpty { Self.showErrors(collectedErrors) }
                completion(collectedPairs)
            }
        }
    }

    /// Delete bypassing the Trash.
    func deletePermanently(items: [FileItem], completion: @escaping @MainActor () -> Void) {
        DiskOperationQueue.shared.addOperation {
            var errors: [String] = []
            for item in items {
                do {
                    try FileManager.default.removeItem(at: item.url)
                } catch {
                    // Common causes of "…you don't have permission…": a locked
                    // (immutable/uchg — Finder's "Locked") item or a subfolder without
                    // write permission. The user has already confirmed the permanent
                    // delete — like Finder, clear the locks/add write across the whole
                    // subtree and try again; an error is reported only if that fails
                    // too.
                    Self.makeDeletable(item.url)
                    do {
                        try FileManager.default.removeItem(at: item.url)
                    } catch {
                        errors.append("\(item.name): \(error.localizedDescription)")
                    }
                }
            }
            let collectedErrors = errors
            Task { @MainActor in
                if !collectedErrors.isEmpty { Self.showErrors(collectedErrors) }
                completion()
            }
        }
    }

    /// Removes obstacles to deletion across the whole subtree: user-immutable/append-only
    /// flags and missing owner write permission (directories also need +x, otherwise they
    /// can't be entered to delete their contents). Symlinks are skipped — the link itself
    /// is deleted and its target must not be touched (important for Workspaces). Called
    /// only after removeItem has failed once, so ordinary deletes aren't affected.
    private static func makeDeletable(_ url: URL) {
        let fm = FileManager.default
        func unlock(_ fileURL: URL, isDir: Bool) {
            try? fm.setAttributes([
                .immutable: false,
                .appendOnly: false,
                .posixPermissions: NSNumber(value: isDir ? 0o700 : 0o600),
            ], ofItemAtPath: fileURL.path)
        }
        let rootValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isSymbolicLink != true else { return }
        unlock(url, isDir: rootValues?.isDirectory ?? false)
        guard rootValues?.isDirectory == true,
              let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            unlock(child, isDir: values?.isDirectory ?? false)
        }
    }

    /// true if `destination` is `source` itself or a subfolder of it (component-wise path
    /// comparison with symlinks resolved — to catch real nesting through a link too). Used
    /// to prevent copying/moving a folder into itself (which would recurse). Always false
    /// for a file source (nothing is nested in a file).
    static func destinationIsWithinSource(_ destination: URL, source: URL) -> Bool {
        let srcComponents = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let dstComponents = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        // Compare by components (not by URL) — a trailing slash/representation doesn't
        // get in the way.
        if srcComponents == dstComponents { return true }
        guard dstComponents.count > srcComponents.count else { return false }
        return Array(dstComponents.prefix(srcComponents.count)) == srcComponents
    }

    /// Makes ONE copy of `source` at `finalDst` when `finalDst` lies INSIDE `source`
    /// (copying a folder into itself). A plain copyItem would loop here, so first the
    /// source's contents are snapshotted into a temporary folder on the same volume but
    /// OUTSIDE its subtree (`.itemReplacementDirectory` — the system temp, not inside
    /// source), and then the snapshot is moved into place. A move within a volume is a
    /// rename, so there's exactly one copy and it doesn't contain itself. The temporary
    /// folder is always cleaned up.
    static func copyIntoSelf(source: URL, to finalDst: URL) throws {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: finalDst.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: staging) }
        let snapshot = staging.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: snapshot)   // snapshot outside the source — no recursion
        try fm.moveItem(at: snapshot, to: finalDst)  // move into place (same volume → rename)
    }

    /// "file.txt" -> "file 2.txt" if the name is taken.
    static func uniqueURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var i = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(i)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    @MainActor
    private static func showErrors(_ errors: [String]) {
        let alert = NSAlert()
        alert.messageText = "Some Operations Failed"
        alert.informativeText = errors.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.runModal()
    }
}
