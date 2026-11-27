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
struct UndoHistory: Codable {

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
                case .move: try? PlainCopy.moveItem(pair.dst, to: pair.src)
                case .copy: trashOrRemove(pair.dst)
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
            trashOrRemove(url)
        }
    }

    /// Undoing a copy or a creation removes something — to the Trash, as Finder does, not
    /// for good. The history now outlives the app (see UndoHistoryStore), so days later the
    /// name may hold an unrelated file; going through the Trash keeps even that case
    /// recoverable. Volumes without a Trash (network shares, some flash drives) fall back to
    /// a plain delete.
    private static func trashOrRemove(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
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
                case .move: try? PlainCopy.moveItem(pair.src, to: pair.dst)
                case .copy: try? PlainCopy.copyItem(pair.src, to: pair.dst)
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

// MARK: - Persistence


/// Paths are stored as plain strings: the entries are re-validated against the disk before
/// every step anyway (see `pruned`), so nothing more than the path is needed.
extension UndoableAction: Codable {
    private enum Kind: String, Codable { case transfer, trash, rename, batchRename, createItem }
    private struct Pair: Codable { let a: String; let b: String }
    private enum CodingKeys: String, CodingKey { case kind, mode, pairs, isDirectory }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pairs = try c.decode([Pair].self, forKey: .pairs)
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        switch try c.decode(Kind.self, forKey: .kind) {
        case .transfer:
            self = .transfer(mode: try c.decode(TransferMode.self, forKey: .mode),
                             pairs: pairs.map { (src: url($0.a), dst: url($0.b)) })
        case .trash:
            self = .trash(pairs: pairs.map { (original: url($0.a), trashed: url($0.b)) })
        case .rename:
            guard let pair = pairs.first else { throw DecodingError.dataCorruptedError(forKey: .pairs, in: c, debugDescription: "empty rename") }
            self = .rename(from: url(pair.a), to: url(pair.b))
        case .batchRename:
            self = .batchRename(pairs: pairs.map { (from: url($0.a), to: url($0.b)) })
        case .createItem:
            guard let pair = pairs.first else { throw DecodingError.dataCorruptedError(forKey: .pairs, in: c, debugDescription: "empty create") }
            self = .createItem(url: url(pair.a), isDirectory: try c.decode(Bool.self, forKey: .isDirectory))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transfer(let mode, let pairs):
            try c.encode(Kind.transfer, forKey: .kind)
            try c.encode(mode, forKey: .mode)
            try c.encode(pairs.map { Pair(a: $0.src.path, b: $0.dst.path) }, forKey: .pairs)
        case .trash(let pairs):
            try c.encode(Kind.trash, forKey: .kind)
            try c.encode(pairs.map { Pair(a: $0.original.path, b: $0.trashed.path) }, forKey: .pairs)
        case .rename(let from, let to):
            try c.encode(Kind.rename, forKey: .kind)
            try c.encode([Pair(a: from.path, b: to.path)], forKey: .pairs)
        case .batchRename(let pairs):
            try c.encode(Kind.batchRename, forKey: .kind)
            try c.encode(pairs.map { Pair(a: $0.from.path, b: $0.to.path) }, forKey: .pairs)
        case .createItem(let url, let isDirectory):
            try c.encode(Kind.createItem, forKey: .kind)
            try c.encode([Pair(a: url.path, b: "")], forKey: .pairs)
            try c.encode(isDirectory, forKey: .isDirectory)
        }
    }
}

/// The app-wide undo history, saved to disk after every change so ⌘Z still works after a
/// relaunch. One history for all windows and tabs (it used to be one per tab, which made
/// "undo" depend on which tab happened to be in front — Finder's undo is app-wide too).
/// An unreadable or missing file simply means an empty history.
final class UndoHistoryStore {
    static let shared = UndoHistoryStore()

    var history: UndoHistory { didSet { save() } }
    private let fileURL: URL

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Marlia/UndoHistory.json")
    }

    init(fileURL: URL = UndoHistoryStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(UndoHistory.self, from: data) {
            history = decoded
        } else {
            history = UndoHistory()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
