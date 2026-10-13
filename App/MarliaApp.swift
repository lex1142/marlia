import AppKit
import Combine
import SwiftUI

/// The AppKit application delegate (the entry point is `main.swift`). Owns the
/// lifecycle: installing the menu, restoring the session, creating tabs, saving on
/// quit. Implements `newWindowForTab(_:)` — the action of the native "+" button in
/// the tab bar.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The static "create a tab" entry point — the New Tab menu item and the toolbar "+" are
    /// wired to it.
    @MainActor static func requestNewTab() { AppWindowManager.shared.requestNewTab() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Theme before creating windows: the app's appearance has to be set before AppKit
        // draws the first window, otherwise it flashes system colors (see Theme.swift).
        ThemeStore.shared.applyToApp()
        // Our own AppKit menu (see MainMenu.swift) and the bridges for opening
        // auxiliary windows.
        MainMenuController.shared.install()
        MainMenuController.openHelpWindow = { AppWindowManager.shared.openHelp() }
        MainMenuController.openSettingsWindow = { AppWindowManager.shared.openSettings() }
        MainMenuController.openGetInfoWindow = { AppWindowManager.shared.openGetInfo($0) }
        AppWindowManager.shared.openInitialWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func newWindowForTab(_ sender: Any?) {
        Self.requestNewTab()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// macOS 14+ asks the delegate about this and logs a warning if there's no answer.
    /// The app saves its window state itself (WindowStateStore) and puts nothing into
    /// the restorable archive, so secure decoding is enabled.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        let states = AppStateRegistry.liveStates.map { $0.snapshotWindowState() }
        WindowStateStore.save(states)
    }
}

/// Space = Quick Look (see QuickLookController.swift), as in Finder. It's caught by an
/// app-wide keyDown monitor rather than inside the modes themselves, so as not to take
/// first responder away from the table in List mode — that already broke native click
/// navigation once (see the comment in PaneView.swift about the known limitation with the
/// empty area). The monitor is app-wide, but the event is accepted only if it's addressed
/// to THIS window specifically — so a space typed in a text field of a sheet/alert opened
/// on top (they have their own NSWindow) never gets here.
final class QuickLookMonitoringView: NSView {
    var appState: AppState?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window, event.keyCode == 49 else { return event }
            if window.firstResponder is NSTextView { return event }
            guard let urls = self.appState?.activePane.selectedItems.map(\.url), !urls.isEmpty else { return event }
            QuickLookCoordinator.shared.toggle(urls: urls)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct QuickLookKeyCatcher: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> QuickLookMonitoringView {
        let view = QuickLookMonitoringView()
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: QuickLookMonitoringView, context: Context) {
        nsView.appState = appState
    }
}


/// A folder/file whose name already exists at the destination — waiting for the user's
/// decision.
struct PendingConflict: Identifiable {
    let id = UUID()
    let item: FileItem
    let destination: URL
}

/// A permanent delete awaiting confirmation — unlike "Move to Trash", it can't
/// be undone; the files are physically erased.
struct PendingPermanentDelete: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let pane: PaneViewModel
}

/// A batch-rename request handed to the sheet. Holds the pane itself, because after
/// applying it's that pane that has to be re-read and have its selection restored.
@MainActor
struct PendingBatchRename: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let pane: PaneViewModel
}

/// Waiting for the name/format/password choice in CreateArchiveView.
struct PendingArchiveCreation: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let pane: PaneViewModel
}

/// Extraction hit a password prompt — waiting for input in the dialog, after
/// which extraction is retried with the given password.
struct PendingArchiveExtraction: Identifiable {
    let id = UUID()
    let item: FileItem
    let pane: PaneViewModel
}

/// Per-window state: the two panes and which one is active.
@MainActor
final class AppState: ObservableObject {
    enum PaneSide { case left, right }

    let leftPane: PaneViewModel
    let rightPane: PaneViewModel
    let favorites = FavoritesStore()
    @Published var activeSide: PaneSide = .left
    /// The info panel. Like showSecondPane, it's window state rather than app state: it
    /// can be open differently in different windows, and it's saved with the session.
    @Published var showInspector = false
    /// The second pane isn't removed from the tree when turned off but collapsed to zero
    /// width (see ContentView.paneContent) — switching the container from HSplitView to a
    /// single View once caused a ~1s freeze from fully recreating the Table inside AppKit
    /// (the same effect that broke the experiment with a 2×2 grid of panes).
    @Published var showSecondPane = true

    /// Values derived from the ACTIVE pane that only the window chrome (window title) and
    /// the sidebar need. Pulled out here so ContentView/the sidebar subscribe to them
    /// rather than to the whole pane model via @ObservedObject: otherwise every selection
    /// change (arrows) redrew the whole window and both panes (measured). They're updated
    /// with de-dup, so a selection step within a non-empty set doesn't touch them — the
    /// window isn't redrawn, only the active pane itself re-renders.
    @Published private(set) var activeDirectoryURL: URL
    @Published private(set) var activeHasSelection = false
    @Published private(set) var activeRecentsMode = false

    private var derivedCancellables: Set<AnyCancellable> = []

    /// If the pane being hidden was the active one, move activity to the left pane,
    /// otherwise commands like Paste/Copy→ would silently target an invisible pane.
    func toggleSecondPane() {
        showSecondPane.toggle()
        if !showSecondPane, activeSide == .right {
            activeSide = .left
        }
    }

    func toggleInspector() { showInspector.toggle() }

    /// Go to a favorite by position. Position rather than a remembered path: the list
    /// can be reordered by dragging, and ⌥⌘1 should lead to whatever is first in the
    /// sidebar right now — the same way Places behave in Dolphin.
    func goToFavorite(at index: Int) {
        let items = favorites.items
        // The only real protection against ⌥⌘7 with three favorites: hiding the menu item
        // doesn't block its shortcut (verified), so the range check has to be here.
        guard items.indices.contains(index) else { return }
        activePane.navigate(to: items[index])
        // Return focus to the pane: after navigating, the arrows should move
        // through files.
        focusActivePane()
    }
    @Published var activeConflict: PendingConflict?
    @Published var pendingPermanentDelete: PendingPermanentDelete?
    @Published var pendingArchiveCreation: PendingArchiveCreation?
    @Published var pendingArchiveExtraction: PendingArchiveExtraction?
    @Published var archiveExtractionPassword = ""
    private let archiveService = ArchiveService()

    /// Active operations for the HUD overlay (see OperationsOverlay in
    /// ContentView).
    @Published var activeOperations: [OperationProgress] = []

    @discardableResult
    private func beginOperation(_ title: String, total: Int = 0) -> OperationProgress {
        let op = OperationProgress(title: title, total: total)
        activeOperations.append(op)
        return op
    }

    private func endOperation(_ op: OperationProgress) {
        activeOperations.removeAll { $0.id == op.id }
    }

    /// The clipboard is app-wide (FileClipboard), not one per window and tab: an AppState
    /// is created for each of them, and a "cut" known only to its own tab turned a paste
    /// in a neighbouring one into a copy. Only the wiring to the shared state remains
    /// here; the views subscribe to it themselves (see PaneView.clipboard).
    var clipboardMode: ClipboardMode? { FileClipboard.shared.mode }
    var clipboardURLs: Set<URL> { FileClipboard.shared.urls }

    func isCut(_ url: URL) -> Bool { FileClipboard.shared.isCut(url) }

    private let ops = FileOperationService()

    /// The undo stack lives in UndoHistory (Models/UndoHistory.swift) — together with
    /// the check that entries still apply to the current state of the disk.
    private var history = UndoHistory()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    /// Titles for the menu items: "Undo Rename" instead of a faceless "Undo".
    var undoLabel: String? { history.undoLabel }
    var redoLabel: String? { history.redoLabel }

    // State of the current series of name-conflict dialogs (there may be several in a
    // row).
    private var conflictQueue: [FileItem] = []
    private var conflictDestination = URL(fileURLWithPath: "/")
    private var conflictMode: TransferMode = .copy
    private var conflictResolutions: [FileItem.ID: ConflictAction] = [:]
    private var conflictRemaining: [FileItem] = []
    private var conflictApplyToAll: ConflictAction?
    private var conflictCompletion: (() -> Void)?

    /// The window this AppState belongs to. Set in MarliaWindowController; the (AppKit)
    /// main menu uses it to find the active window's state — see
    /// AppStateRegistry.activeState.
    weak var window: NSWindow?

    /// A "focus the active pane" signal counter. Bumped after a window/tab is created (see
    /// focusActivePane / AppWindowManager); the active PaneView takes first responder on a
    /// change — otherwise the AppKit split leaves it on the sidebar.
    @Published var paneFocusNonce = 0

    /// Asks the active pane to take keyboard focus (see paneFocusNonce).
    func focusActivePane() { paneFocusNonce += 1 }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        leftPane = PaneViewModel(url: home)
        rightPane = PaneViewModel(url: home)
        activeDirectoryURL = home
        AppStateRegistry.register(self)

        // Recompute the derived values when the active pane changes or any of the
        // sources in EITHER pane changes. async — the @Published publisher fires in
        // willSet (before the property is written), so the pane is read on the next
        // tick, once the new value is in place; the de-dup in recomputeActiveDerived
        // suppresses idle updates.
        let recompute: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.recomputeActiveDerived() }
        }
        $activeSide.dropFirst().sink { _ in recompute() }.store(in: &derivedCancellables)
        for pane in [leftPane, rightPane] {
            pane.$currentURL.dropFirst().sink { _ in recompute() }.store(in: &derivedCancellables)
            pane.$selection.dropFirst().sink { _ in recompute() }.store(in: &derivedCancellables)
            pane.$recentsMode.dropFirst().sink { _ in recompute() }.store(in: &derivedCancellables)
        }
    }

    private func recomputeActiveDerived() {
        let pane = activePane
        if activeDirectoryURL != pane.currentURL { activeDirectoryURL = pane.currentURL }
        let hasSelection = !pane.selection.isEmpty
        if activeHasSelection != hasSelection { activeHasSelection = hasSelection }
        if activeRecentsMode != pane.recentsMode { activeRecentsMode = pane.recentsMode }
    }

    var activePane: PaneViewModel { activeSide == .left ? leftPane : rightPane }
    var passivePane: PaneViewModel { activeSide == .left ? rightPane : leftPane }

    /// Make a pane active with de-dup: @Published sends objectWillChange even for an
    /// equal value, so an unconditional `activeSide = side` on every click (including in
    /// the already-active pane) redrew the whole window. Assign only on a real change.
    func activate(_ side: PaneSide) {
        if activeSide != side { activeSide = side }
    }

    // MARK: Saving/restoring window state (tabs, open directories, view mode)

    func snapshotWindowState() -> WindowState {
        WindowState(
            leftPath: leftPane.currentURL.path,
            leftViewMode: leftPane.viewMode.rawValue,
            rightPath: rightPane.currentURL.path,
            rightViewMode: rightPane.viewMode.rawValue,
            showSecondPane: showSecondPane,
            showInspector: showInspector,
            frame: window.map { NSStringFromRect($0.frame) } ?? ""
        )
    }

    func restore(from state: WindowState) {
        showSecondPane = state.showSecondPane
        showInspector = state.showInspector
        if FileManager.default.fileExists(atPath: state.leftPath) {
            leftPane.navigate(to: URL(fileURLWithPath: state.leftPath))
        }
        if let mode = ViewMode(rawValue: state.leftViewMode) {
            leftPane.viewMode = mode
        }
        if FileManager.default.fileExists(atPath: state.rightPath) {
            rightPane.navigate(to: URL(fileURLWithPath: state.rightPath))
        }
        if let mode = ViewMode(rawValue: state.rightViewMode) {
            rightPane.viewMode = mode
        }
    }

    // MARK: Clipboard (⌘C / ⌘X / ⌘V)

    /// With nothing selected, ⌘C copies the current directory's path as text —
    /// handy for pasting it into another app or back via ⌘V.
    func copySelection() {
        let items = activePane.selectedItems
        if items.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(activePane.currentURL.path, forType: .string)
        } else {
            copySelection(items)
        }
    }

    func cutSelection() { cutSelection(activePane.selectedItems) }

    func copySelection(_ items: [FileItem]) { setClipboard(items, mode: .copy) }
    func cutSelection(_ items: [FileItem]) { setClipboard(items, mode: .cut) }

    private func setClipboard(_ items: [FileItem], mode: ClipboardMode) {
        guard !items.isEmpty else { return }
        // Copying a symbolic link (e.g. from a Workspace) puts the real file on the
        // pasteboard, not the link itself — pasting elsewhere produces a real copy of
        // the contents. Cut deliberately doesn't do this: it must move the link
        // itself (rather than pulling the original out of its real location).
        let urls = mode == .copy ? items.map { $0.url.resolvingSymlinksInPath() } : items.map(\.url)
        FileClipboard.shared.set(urls, mode: mode)
    }

    func selectAllInActive() {
        activePane.selection = Set(activePane.items.map(\.id))
    }

    // MARK: Menu bar commands
    //
    // The HIG requires everything the app can do to be available from the menu bar,
    // with the context menu only speeding up access. These commands used to exist
    // ONLY inside PaneView.contextNSMenu (i.e. on right-click), so here they're
    // reshaped into methods on the active pane — MainMenuController calls them,
    // while the context menu keeps working on the items under the cursor.

    func openSelection() {
        guard let item = activePane.selectedItems.first else { return }
        activePane.open(item)
    }

    func quickLookSelection() {
        let urls = activePane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookCoordinator.shared.toggle(urls: urls)
    }

    func showSelectionInFinder() {
        let urls = activePane.selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [activePane.currentURL] : urls)
    }

    /// Paths of the selection to the clipboard (⌥⌘C — like Finder's "Copy as
    /// Pathname"). With no selection, the folder's own path is copied.
    func copySelectionPath() {
        let items = activePane.selectedItems
        let paths = items.isEmpty ? [activePane.currentURL.path] : items.map(\.url.path)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func openActiveInTerminal() { Self.openInTerminal(activePane.currentURL) }

    /// The common entry point for the menu item and the pane's context menu.
    static func openInTerminal(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", url.path]
        try? process.run()
    }

    func compressSelection() {
        let items = activePane.selectedItems
        guard !items.isEmpty else { return }
        compress(items: items, in: activePane)
    }

    /// Whether the selection is an archive — this decides whether Extract / View
    /// Contents are available.
    var selectedArchive: FileItem? {
        guard let item = activePane.selectedItems.first, activePane.selectedItems.count == 1,
              ArchiveFormat(url: item.url) != nil else { return nil }
        return item
    }

    func extractSelection() {
        guard let item = selectedArchive else { return }
        extractArchive(item: item, in: activePane)
    }

    func addSelectionToFavorites() {
        guard let item = activePane.selectedItems.first, item.isNavigableFolder else {
            favorites.add(activePane.currentURL)
            return
        }
        favorites.add(item.url)
    }

    func renameSelection() { activePane.renameRequest = activePane.selectedItems.first?.id }

    // MARK: Navigation (Go menu)

    func goBackActive() { activePane.goBack() }
    func goForwardActive() { activePane.goForward() }
    func goUpActive() { activePane.goUp() }
    func goHomeActive() { activePane.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    func showRecentsActive() { activePane.showRecents() }

    /// The "Connect to Server" sheet lives in the sidebar — from the menu bar it's
    /// raised with a flag (the sheet itself stayed where it was, so it isn't
    /// duplicated in two places).
    @Published var isConnectingToServer = false
    /// The select-by-pattern sheet is open.
    @Published var isSelectingByPattern = false
    /// The batch-rename sheet is open (with the items it will apply to).
    @Published var pendingBatchRename: PendingBatchRename?

    func beginBatchRename() {
        let items = activePane.selectedItems
        guard !items.isEmpty else { return }
        pendingBatchRename = PendingBatchRename(items: items, pane: activePane)
    }

    func applyBatchRename(_ plan: [(url: URL, newName: String)], in pane: PaneViewModel) {
        pendingBatchRename = nil
        guard !plan.isEmpty else { return }
        ops.batchRename(plan) { [weak self] performed in
            guard !performed.isEmpty else { return }
            self?.record(.batchRename(pairs: performed))
            // The selection moves to the new names: losing fifty just-renamed files from
            // the selection would mean hunting for them again by eye.
            pane.reload()
            pane.selection = Set(pane.items.filter { item in
                performed.contains { $0.to.standardizedFileURL == item.url.standardizedFileURL }
            }.map(\.id))
        }
    }

    func toggleFilterBar() { activePane.isFilterBarVisible.toggle() }

    func invertSelectionInActivePane() { activePane.invertSelection() }

    func beginSelectByPattern() { isSelectingByPattern = true }

    func applyPatternSelection(_ pattern: String) {
        activePane.selectMatching(pattern: pattern)
        isSelectingByPattern = false
        // The selection changed programmatically — return focus to the pane, otherwise
        // the arrows go nowhere after the sheet closes.
        focusActivePane()
    }
    func connectToServer() { isConnectingToServer = true }

    // MARK: View of the active pane (View menu)

    func setViewMode(_ mode: ViewMode) { activePane.viewMode = mode }
    func setSortActive(_ field: SortField) { activePane.setSort(field) }
    func setGroupActive(_ field: GroupField) { activePane.groupBy = field }

    /// Pastes from the system pasteboard, so it works with files copied in
    /// Finder too. "Cut" is recognized only for what was cut by this same app —
    /// in which case the sources are moved.
    func pasteIntoActive() { paste(into: activePane) }

    func paste(into pane: PaneViewModel) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap { $0 as? URL } ?? []
        guard !urls.isEmpty else {
            // There are no files on the pasteboard — maybe there's a text path (e.g.
            // copied via ⌘C with no selection, or from somewhere else): navigate to it.
            if let text = NSPasteboard.general.string(forType: .string) {
                pastePath(text, into: pane)
            }
            return
        }
        let items = urls.compactMap(FileItem.init)
        // The "cut" flag comes from the shared clipboard: it also checks that nobody
        // has put anything on top of our write since ⌘X.
        let isCut = FileClipboard.shared.isCutPending && Set(urls) == FileClipboard.shared.urls
        if isCut { FileClipboard.shared.clear() }
        transfer(items: items, to: pane.currentURL, mode: isCut ? .move : .copy) { [weak self] in
            pane.reload()
            if isCut { self?.activePane.reload(); self?.passivePane.reload() }
        }
    }

    /// Supports "~" and trims spaces/newlines — handy if the path was copied
    /// from Terminal with a trailing newline.
    private func pastePath(_ text: String, into pane: PaneViewModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        pane.navigate(to: URL(fileURLWithPath: expanded).resolvingSymlinksInPath())
    }

    func duplicateSelection() { duplicate(items: activePane.selectedItems, in: activePane) }

    func duplicate(items: [FileItem], in pane: PaneViewModel) {
        guard !items.isEmpty else { return }
        let op = beginOperation("Duplicating \(items.count == 1 ? items[0].name : "\(items.count) items")", total: items.count)
        ops.duplicate(items: items, control: op.control, onProgress: { [weak op] done in op?.completed = done }) { [weak self] pairs in
            if !pairs.isEmpty { self?.record(.transfer(mode: .copy, pairs: pairs)) }
            self?.endOperation(op)
            pane.reload()
        }
    }

    func deletePermanently() { deletePermanently(items: activePane.selectedItems, from: activePane) }

    /// A permanent delete can't be recovered via undo — the data is physically
    /// erased, so confirmation is requested first (see confirmPermanentDelete()).
    func deletePermanently(items: [FileItem], from pane: PaneViewModel) {
        guard !items.isEmpty else { return }
        pendingPermanentDelete = PendingPermanentDelete(items: items, pane: pane)
    }

    func confirmPermanentDelete() {
        guard let pending = pendingPermanentDelete else { return }
        pendingPermanentDelete = nil
        ops.deletePermanently(items: pending.items) {
            pending.pane.reload()
        }
    }

    // MARK: Archives (ZIP / tar.gz / tar.bz2 / tar.xz — see ArchiveService)

    func compress(items: [FileItem], in pane: PaneViewModel) {
        guard !items.isEmpty else { return }
        pendingArchiveCreation = PendingArchiveCreation(items: items, pane: pane)
    }

    func createArchive(name: String, format: ArchiveFormat, password: String) {
        guard let pending = pendingArchiveCreation else { return }
        pendingArchiveCreation = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard FileOperationService.isValidItemName(trimmedName) else {
            pending.pane.errorMessage = FileOperationService.invalidNameMessage
            return
        }
        let destination = FileOperationService.uniqueURL(
            for: pending.pane.currentURL.appendingPathComponent(trimmedName).appendingPathExtension(format.fileExtension)
        )
        let op = beginOperation("Compressing \(pending.items.count == 1 ? pending.items[0].name : "\(pending.items.count) items")")
        archiveService.createArchive(items: pending.items, destination: destination, format: format, password: password, control: op.control) { [weak self, weak op, weak pane = pending.pane] result in
            if let op { self?.endOperation(op) }
            if case .failure(let error) = result, !(error is CancellationError) {
                pane?.errorMessage = error.localizedDescription
            }
            pane?.reload()
        }
    }

    func extractArchive(item: FileItem, in pane: PaneViewModel) {
        attemptExtract(item: item, pane: pane, password: nil)
    }

    private func attemptExtract(item: FileItem, pane: PaneViewModel, password: String?) {
        guard let format = ArchiveFormat(url: item.url) else { return }
        let destination = FileOperationService.uniqueURL(
            for: item.url.deletingLastPathComponent().appendingPathComponent(format.baseName(for: item.url))
        )
        let op = beginOperation("Extracting \(item.name)")
        archiveService.extractArchive(
            url: item.url, format: format, destination: destination, password: password, control: op.control,
            onProgress: { [weak op] done, total in
                op?.total = total
                op?.completed = done
            }
        ) { [weak self, weak pane, weak op] result in
            if let op { self?.endOperation(op) }
            switch result {
            case .success:
                pane?.reload()
            case .failure(let error):
                if case ArchiveService.ArchiveError.passwordRequired = error, let pane {
                    self?.archiveExtractionPassword = ""
                    self?.pendingArchiveExtraction = PendingArchiveExtraction(item: item, pane: pane)
                } else if !(error is CancellationError) {
                    pane?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func retryArchiveExtraction() {
        guard let pending = pendingArchiveExtraction else { return }
        pendingArchiveExtraction = nil
        let password = archiveExtractionPassword
        // Don't keep the password in @Published longer than needed: the value has
        // already been copied into a local variable, while the field in AppState
        // lives as long as the window.
        archiveExtractionPassword = ""
        attemptExtract(item: pending.item, pane: pending.pane, password: password)
    }

    func toggleActivePane() {
        activeSide = activeSide == .left ? .right : .left
    }

    func copyToOtherPane() {
        transfer(items: activePane.selectedItems, to: passivePane.currentURL, mode: .copy) { [weak self] in
            self?.passivePane.reload()
        }
    }

    func moveToOtherPane() {
        transfer(items: activePane.selectedItems, to: passivePane.currentURL, mode: .move) { [weak self] in
            self?.activePane.reload()
            self?.passivePane.reload()
        }
    }

    func trashSelection() { trash(items: activePane.selectedItems, from: activePane) }

    func trash(items: [FileItem], from pane: PaneViewModel) {
        ops.trash(items: items) { [weak self] pairs in
            if !pairs.isEmpty { self?.record(.trash(pairs: pairs)) }
            pane.reload()
        }
    }

    func rename(item: FileItem, to newName: String, in pane: PaneViewModel) {
        guard FileOperationService.isValidItemName(newName) else {
            pane.errorMessage = FileOperationService.invalidNameMessage
            return
        }
        let from = item.url
        let to = from.deletingLastPathComponent().appendingPathComponent(newName)
        ops.rename(item: item, to: newName) { [weak self] in
            self?.record(.rename(from: from, to: to))
            self?.revealIfHidden(newName, in: pane)
            // In Columns mode an already-open (parent) folder can be renamed — then the
            // pane's currentURL contains the OLD name in its path, and reload() on it
            // would fail (the path no longer exists). Replace the stale prefix with the
            // new one and navigate there; otherwise (an ordinary rename of a sibling in
            // the current folder) — a plain reload.
            let fromPath = from.standardizedFileURL.path
            let toPath = to.standardizedFileURL.path
            let curPath = pane.currentURL.standardizedFileURL.path
            if curPath == fromPath || curPath.hasPrefix(fromPath + "/") {
                let suffix = String(curPath.dropFirst(fromPath.count))
                pane.navigate(to: URL(fileURLWithPath: toPath + suffix), recordHistory: false)
            } else {
                pane.reload()
            }
        }
    }

    /// A name starting with a dot makes the item HIDDEN — and it disappears from the pane
    /// if showing hidden files is off. That's exactly how files "vanished" on rename: the
    /// inline editor selects the name without the extension (as Finder does), so "delete
    /// and Enter" left ".pdf" in the field — the file was duly renamed and went out of
    /// view, while the user was sure they had deleted it. Refusing such a name isn't an
    /// option (dot-files are legitimate, .gitignore and the like), so instead of
    /// forbidding it we turn on showing hidden files in this pane: the result of the
    /// operation stays in view, and the "eye" in the path bar shows why the list changed.
    private func revealIfHidden(_ name: String, in pane: PaneViewModel) {
        guard name.hasPrefix("."), !pane.showHidden else { return }
        pane.showHidden = true   // didSet re-reads the directory by itself
    }

    /// Opens a popup with a name field on the active pane (⇧⌘N and the operations
    /// menu).
    func createFolder() {
        activePane.newFolderName = "New Folder"
        activePane.isCreatingFolder = true
    }

    /// The actual creation — called from the popup after the name is entered.
    func createFolder(named name: String, in pane: PaneViewModel) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard FileOperationService.isValidItemName(trimmed) else {
            pane.errorMessage = FileOperationService.invalidNameMessage
            return
        }
        let url = FileOperationService.uniqueURL(for: pane.currentURL.appendingPathComponent(trimmed))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        record(.createItem(url: url, isDirectory: true))
        revealIfHidden(url.lastPathComponent, in: pane)
        pane.reload()
    }

    func createFile() {
        activePane.newFileName = "New File"
        activePane.isCreatingFile = true
    }

    func createFile(named name: String, in pane: PaneViewModel) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard FileOperationService.isValidItemName(trimmed) else {
            pane.errorMessage = FileOperationService.invalidNameMessage
            return
        }
        let url = FileOperationService.uniqueURL(for: pane.currentURL.appendingPathComponent(trimmed))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        record(.createItem(url: url, isDirectory: false))
        revealIfHidden(url.lastPathComponent, in: pane)
        pane.reload()
    }

    func refreshActive() { activePane.reload() }

    // MARK: Item zoom (⌘+ / ⌘− / ⌘0)

    func zoomInActive() { activePane.zoomIn() }
    func zoomOutActive() { activePane.zoomOut() }
    func resetZoomActive() { activePane.resetZoom() }

    // MARK: AirDrop

    /// The same system mechanism as Finder's ("Share → AirDrop") — opens the native
    /// AirDrop window with nearby devices, no UI of our own.
    func airDrop(_ items: [FileItem]) {
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        let urls = items.map(\.url) as [Any]
        guard service.canPerform(withItems: urls) else { return }
        service.perform(withItems: urls)
    }

    func airDropSelection() { airDrop(activePane.selectedItems) }

    // MARK: Copy/move with name-conflict detection

    /// The entry point for copy/move (paste, F5/F6, drag-and-drop). If some names
    /// are already taken in destination, it first asks via the dialog
    /// (replace/skip/keepBoth + "apply to all"), and only then performs the
    /// transfer.
    func transfer(items: [FileItem], to destination: URL, mode: TransferMode, completion: @escaping () -> Void) {
        // Copying/moving "into" a Workspace always means the same as "Add to
        // Workspace": a Workspace exists to refer to originals, not to duplicate data
        // inside itself. Any copy/move/drag whose target is the workspace folder
        // itself is redirected here (WorkspaceStore.add already knows how to skip
        // duplicates and show an alert about it — see WorkspaceStore.swift).
        if WorkspaceStore.isWorkspaceFolder(destination) {
            WorkspaceStore.shared.add(items, to: destination)
            completion()
            return
        }

        let conflicting = items.filter {
            let dst = destination.appendingPathComponent($0.name)
            return dst != $0.url && FileManager.default.fileExists(atPath: dst.path)
        }
        guard !conflicting.isEmpty else {
            performTransfer(items: items, to: destination, mode: mode, resolutions: [:], completion: completion)
            return
        }

        conflictQueue = items
        conflictDestination = destination
        conflictMode = mode
        conflictResolutions = [:]
        conflictApplyToAll = nil
        conflictCompletion = completion
        presentNextConflict(Array(conflicting))
    }

    private func presentNextConflict(_ remaining: [FileItem]) {
        guard let next = remaining.first else {
            let items = conflictQueue
            let destination = conflictDestination
            let mode = conflictMode
            let resolutions = conflictResolutions
            let completion = conflictCompletion
            performTransfer(items: items, to: destination, mode: mode, resolutions: resolutions) {
                completion?()
            }
            return
        }
        if let applyAll = conflictApplyToAll {
            conflictResolutions[next.id] = applyAll
            presentNextConflict(Array(remaining.dropFirst()))
            return
        }
        conflictRemaining = Array(remaining.dropFirst())
        activeConflict = PendingConflict(item: next, destination: conflictDestination)
    }

    func resolveConflict(_ action: ConflictAction, applyToAll: Bool) {
        guard let conflict = activeConflict else { return }
        conflictResolutions[conflict.item.id] = action
        if applyToAll { conflictApplyToAll = action }
        activeConflict = nil
        presentNextConflict(conflictRemaining)
    }

    private func performTransfer(
        items: [FileItem],
        to destination: URL,
        mode: TransferMode,
        resolutions: [FileItem.ID: ConflictAction],
        completion: @escaping () -> Void
    ) {
        guard !items.isEmpty else { completion(); return }
        let verb = mode == .copy ? "Copying" : "Moving"
        let label = items.count == 1 ? items[0].name : "\(items.count) items"
        let op = beginOperation("\(verb) \(label) to \(destination.lastPathComponent)", total: items.count)
        ops.transfer(items: items, to: destination, mode: mode, resolutions: resolutions, control: op.control, onProgress: { [weak op] done in
            op?.completed = done
        }) { [weak self] pairs in
            if !pairs.isEmpty { self?.record(.transfer(mode: mode, pairs: pairs)) }
            self?.endOperation(op)
            completion()
        }
    }

    // MARK: Undo/redo of the last operation (⌘Z / ⇧⌘Z)

    private func record(_ action: UndoableAction) {
        history.record(action)
    }

    func undoLast() {
        guard history.undo() != nil else { return }
        refreshPanesAfterHistoryStep()
    }

    func redoLast() {
        guard history.redo() != nil else { return }
        refreshPanesAfterHistoryStep()
    }

    /// Both panes, not just the active one: the undone operation may have touched either
    /// of them (F5/F6 work between panes), and the second pane may be looking at the
    /// same folder anyway.
    private func refreshPanesAfterHistoryStep() {
        leftPane.reload()
        rightPane.reload()
    }
}
