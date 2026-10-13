import Foundation

/// An undoable file operation. Stores only paths — nothing heavy, so the stack depth is
/// limited not by memory but by how far back a person still remembers what they did.
enum UndoableAction {
    case transfer(mode: TransferMode, pairs: [(src: URL, dst: URL)])
    case trash(pairs: [(original: URL, trashed: URL)])
    case rename(from: URL, to: URL)
    case batchRename(pairs: [(from: URL, to: URL)])
    case createItem(url: URL, isDirectory: Bool)

    /// For the menu item title: "Undo Rename" instead of just "Undo". With fifty
    /// steps of depth this is the only way to know what exactly is about to be
    /// undone.
    var label: String {
        switch self {
        case .transfer(let mode, let pairs):
            let verb = mode == .copy ? "Copy" : "Move"
            return pairs.count == 1 ? verb : "\(verb) of \(pairs.count) Items"
        case .trash(let pairs):
            return pairs.count == 1 ? "Move to Trash" : "Move of \(pairs.count) Items to Trash"
        case .rename:
            return "Rename"
        case .batchRename(let pairs):
            return "Rename of \(pairs.count) Items"
        case .createItem(_, let isDirectory):
            return isDirectory ? "New Folder" : "New File"
        }
    }
}

/// The undo and redo stack of file operations.
///
/// The app used to remember exactly one last action, and a second ⌘Z did nothing. This is
/// a real stack — with one twist that plain text undo doesn't have: entries refer to
/// paths, and paths live a life of their own. A file may have been renamed by hand in
/// Finder, deleted, a volume unmounted. So before every step an entry is trimmed to what
/// actually exists on disk, and a completely stale one is skipped.
///
/// Without this check ⌘Z would pretend to work: every FileManager call here goes through
/// `try?`, i.e. a failure silently changes nothing — the stack would advance while nothing
/// changed on disk.
///
/// The type deliberately has no UI dependencies: that way it can be compiled with a
/// scratchpad script and exercised against a real disk (see the verification section in
/// CLAUDE.md).
struct UndoHistory {

    /// The depth cap. The limit isn't about memory (entries hold only paths) but
    /// about sense: rewinding further than a person remembers is dangerous anyway.
    static let depthLimit = 50

    private(set) var undoStack: [UndoableAction] = []
    private(set) var redoStack: [UndoableAction] = []

    /// Deliberately cheap: a non-empty stack doesn't guarantee an undo will do anything —
    /// the top entries may have gone stale. Checking that on every menu open would mean
    /// walking the file system for every pair, and one entry can hold thousands of them.
    /// Instead stale entries are discarded on the actual attempt, and the stack cleans
    /// itself up: if there's nothing applicable, it empties and the menu item disables
    /// itself.
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    mutating func record(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > Self.depthLimit { undoStack.removeFirst() }
        // A new operation cuts off the redo branch — as in any undo/redo.
        redoStack.removeAll()
    }

    mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Undoes the nearest applicable action. Returns what was actually undone, or nil
    /// if there was nothing applicable (the whole stack turned out to be stale).
    @discardableResult
    mutating func undo() -> UndoableAction? {
        while let action = undoStack.popLast() {
            guard let applicable = Self.pruned(action, undoing: true) else { continue }
            Self.applyUndo(applicable)
            redoStack.append(applicable)
            return applicable
        }
        return nil
    }

    @discardableResult
    mutating func redo() -> UndoableAction? {
        while let action = redoStack.popLast() {
            guard let applicable = Self.pruned(action, undoing: false) else { continue }
            let performed = Self.applyRedo(applicable)
            undoStack.append(performed)
            return performed
        }
        return nil
    }

    // MARK: Applicability checks

    /// Trims from an entry what can no longer be performed, and returns nil if
    /// nothing is left. Trimming rather than all-or-nothing: if one of ten copied
    /// files was deleted by hand, undoing the other nine is still the right thing.
    static func pruned(_ action: UndoableAction, undoing: Bool) -> UndoableAction? {
        let manager = FileManager.default
        func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

        switch action {
        case .transfer(let mode, let pairs):
            let kept = pairs.filter { pair in
                // Undoing a copy deletes the copy — only it is needed. Undoing a move
                // puts the file back, so the original location must be free.
                let source = undoing ? pair.dst : pair.src
                let target = undoing ? pair.src : pair.dst
                guard exists(source) else { return false }
                return mode == .copy ? true : !exists(target)
            }
            return kept.isEmpty ? nil : .transfer(mode: mode, pairs: kept)

        case .trash(let pairs):
            let kept = pairs.filter { exists(undoing ? $0.trashed : $0.original) }
            return kept.isEmpty ? nil : .trash(pairs: kept)

        case .rename(let from, let to):
            let source = undoing ? to : from
            let target = undoing ? from : to
            return exists(source) && !exists(target) ? action : nil

        case .batchRename(let pairs):
            // A taken target name isn't an obstacle if it's taken by a file that itself
            // takes part in the same pass: swaps and cycles are sorted out by the
            // two-phase execution.
            let sources = Set(pairs.map { (undoing ? $0.to : $0.from).standardizedFileURL })
            let kept = pairs.filter { pair in
                let source = undoing ? pair.to : pair.from
                let target = undoing ? pair.from : pair.to
                guard exists(source) else { return false }
                return !exists(target) || sources.contains(target.standardizedFileURL)
            }
            return kept.isEmpty ? nil : .batchRename(pairs: kept)

        case .createItem(let url, _):
            // Undoing a creation deletes the object (so it must exist); redoing
            // creates it again (so it must not).
            return exists(url) == undoing ? action : nil
        }
    }

    // MARK: Execution

    private static func applyUndo(_ action: UndoableAction) {
        let manager = FileManager.default
        switch action {
        case .transfer(let mode, let pairs):
            for pair in pairs {
                switch mode {
                case .move: try? manager.moveItem(at: pair.dst, to: pair.src)
                case .copy: try? manager.removeItem(at: pair.dst)
                }
            }
        case .trash(let pairs):
            for pair in pairs { try? manager.moveItem(at: pair.trashed, to: pair.original) }
        case .rename(let from, let to):
            try? manager.moveItem(at: to, to: from)
        case .batchRename(let pairs):
            // Through the two-phase rename: undoing a batch rename contains exactly the
            // same name swaps as the rename itself, and a naive one-by-one pass would
            // overwrite files in exactly the same way.
            FileOperationService.performBatchRename(
                pairs.map { (url: $0.to, newName: $0.from.lastPathComponent) }
            )
        case .createItem(let url, _):
            try? manager.removeItem(at: url)
        }
    }

    /// Returns the action in the form it should be pushed back onto the undo
    /// stack: for the Trash, redo changes the paths inside it.
    private static func applyRedo(_ action: UndoableAction) -> UndoableAction {
        let manager = FileManager.default
        switch action {
        case .transfer(let mode, let pairs):
            for pair in pairs {
                switch mode {
                case .move: try? manager.moveItem(at: pair.src, to: pair.dst)
                case .copy: try? manager.copyItem(at: pair.src, to: pair.dst)
                }
            }
        case .trash(var pairs):
            for index in pairs.indices {
                var resultingURL: NSURL?
                try? manager.trashItem(at: pairs[index].original, resultingItemURL: &resultingURL)
                if let trashed = resultingURL as URL? { pairs[index].trashed = trashed }
            }
            // The Trash hands out a new name inside itself each time; without
            // updating the pairs, the next undo would look for the file at a
            // stale path.
            return .trash(pairs: pairs)
        case .rename(let from, let to):
            try? manager.moveItem(at: from, to: to)
        case .batchRename(let pairs):
            FileOperationService.performBatchRename(
                pairs.map { (url: $0.from, newName: $0.to.lastPathComponent) }
            )
        case .createItem(let url, let isDirectory):
            if isDirectory {
                try? manager.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                manager.createFile(atPath: url.path, contents: nil)
            }
        }
        return action
    }
}
