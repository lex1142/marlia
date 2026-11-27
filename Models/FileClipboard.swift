import AppKit

enum ClipboardMode { case copy, cut }

/// The app's file clipboard: what was put on it (⌘C / ⌘X) and how.
///
/// One singleton for the app — like WorkspaceStore and SortPreferencesStore. This state
/// used to live in AppState, which is created for EVERY window and EVERY tab, so only
/// the tab where ⌘X was pressed knew the items were cut: pasting in another tab found
/// no cut flag and copied instead — the file appeared at the new location but didn't
/// disappear from the old one. The system pasteboard is one per app, so the "cut, not
/// copied" flag has to be one too.
///
/// A side benefit: cut items are now dimmed in every window and tab where they're
/// visible, not just the one where ⌘X was pressed.
@MainActor
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()

    @Published private(set) var mode: ClipboardMode?
    @Published private(set) var urls: Set<URL> = []
    /// Items gathered with Add to Clipboard / Add to Cut (Path Finder's Drop Stack): the
    /// panes show a "N collected" badge while this is on. Ends with a paste or a new
    /// plain copy/cut.
    @Published private(set) var isCollecting = false
    /// In the order they were added, for the pasteboard (a Set loses it).
    private var ordered: [URL] = []

    /// The pasteboard's changeCount at the time of our write. Needed to tell "the
    /// pasteboard still holds our data" from "someone put their own on top" — after a
    /// copy in Finder or another app our cut flag must stop applying, otherwise a paste
    /// would drag along files the user cut long ago.
    private var changeCount = -1

    private init() {}

    func set(_ urls: [URL], mode: ClipboardMode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        changeCount = pasteboard.changeCount
        self.urls = Set(urls)
        self.ordered = urls
        self.mode = mode
        isCollecting = false
    }

    /// Whether the pasteboard still holds what we put there (nobody copied anything since).
    var isOurs: Bool { mode != nil && NSPasteboard.general.changeCount == changeCount }

    /// Adds to what's already on the clipboard instead of replacing it, so files from
    /// several folders can be gathered and pasted in one go. Copy plus cut makes the
    /// whole set a copy: a paste must never move files that were only copied.
    func add(_ new: [URL], mode newMode: ClipboardMode) {
        guard isOurs, let current = mode else {
            set(new, mode: newMode)
            isCollecting = true
            return
        }
        let combined = ordered + new.filter { !urls.contains($0) }
        set(combined, mode: current == .cut && newMode == .cut ? .cut : .copy)
        isCollecting = true
    }

    /// A paste "drops the stack": the badge goes, the items stay on the clipboard.
    func endCollecting() { isCollecting = false }

    /// Whether a paste is currently pending as a move: it was a cut that went on the
    /// pasteboard, and nobody has overwritten the pasteboard since.
    var isCutPending: Bool {
        mode == .cut && NSPasteboard.general.changeCount == changeCount
    }

    /// Whether to dim an item in the list (Finder shows cut items this way until
    /// they're pasted).
    func isCut(_ url: URL) -> Bool { isCutPending && urls.contains(url) }

    /// After a completed move: the pasteboard contents are no longer relevant.
    func clear() {
        mode = nil
        urls = []
        ordered = []
        isCollecting = false
        changeCount = -1
        NSPasteboard.general.clearContents()
    }
}
