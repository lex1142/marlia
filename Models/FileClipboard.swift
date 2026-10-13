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
        self.mode = mode
    }

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
        changeCount = -1
        NSPasteboard.general.clearContents()
    }
}
