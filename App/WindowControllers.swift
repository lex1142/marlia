import AppKit
import SwiftUI
import Combine

/// One pane window. Owns its `AppState`. The content is SwiftUI, but in an AppKit frame:
/// `window.contentViewController` = `MarliaSplitViewController` (sidebar ↔ panes), while the
/// toolbar and window title are AppKit. We moved away from `NavigationSplitView` in an
/// `NSHostingController` because inside an AppKit window it broke the sidebar's width/resizing;
/// `NSSplitViewController` gives full control. Windows/tabs/auxiliary windows are still managed
/// by `AppWindowManager` (not SwiftUI scenes).
final class MarliaWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let appState = AppState()
    private var cancellables: Set<AnyCancellable> = []
    private weak var toggleSecondPaneItem: NSToolbarItem?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MarliaTabGroup"
        window.minSize = NSSize(width: 900, height: 500)
        ThemeStore.shared.apply(to: window)   // window background from the theme (see Theme.swift)
        window.contentViewController = MarliaSplitViewController(appState: appState)
        super.init(window: window)
        window.delegate = self
        appState.window = window

        let toolbar = NSToolbar(identifier: "MarliaMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // The toolbar's contents are user-customizable and remembered — standard
        // macOS app behavior (right-click the toolbar → Customize Toolbar).
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Window title = name of the active directory; the "second pane" icon reflects the
        // state.
        appState.$activeDirectoryURL.receive(on: RunLoop.main).sink { [weak window] url in
            window?.title = FileManager.default.displayName(atPath: url.path)
            // representedURL gives the title a folder proxy icon and ⌘-click on the
            // title to reveal the path — what a user expects from a file manager
            // (Finder does exactly this).
            window?.representedURL = url
        }.store(in: &cancellables)
        appState.$showSecondPane.receive(on: RunLoop.main).sink { [weak self] shown in
            self?.updateToggleSecondPaneItem(shown)
        }.store(in: &cancellables)
        appState.$showInspector.receive(on: RunLoop.main).sink { [weak self] shown in
            (self?.contentViewController as? MarliaSplitViewController)?.setInspectorVisible(shown)
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        AppWindowManager.shared.removeMain(self)
    }

    private func updateToggleSecondPaneItem(_ shown: Bool) {
        toggleSecondPaneItem?.image = NSImage(systemSymbolName: shown ? "rectangle.split.2x1" : "rectangle", accessibilityDescription: "Toggle Second Pane")
        toggleSecondPaneItem?.toolTip = shown ? "Hide second pane (\u{21e7}\u{2318}J)" : "Show second pane (\u{21e7}\u{2318}J)"
    }

    // MARK: Toolbar actions (for THIS window's appState)
    @objc private func newTabAction() { AppWindowManager.shared.requestNewTab() }
    @objc private func toggleSecondPaneAction() { appState.toggleSecondPane() }
    @objc private func copyAction() { appState.copySelection() }
    @objc private func cutAction() { appState.cutSelection() }
    @objc private func pasteAction() { appState.pasteIntoActive() }
    @objc private func copyToOtherAction() { appState.copyToOtherPane() }
    @objc private func moveToOtherAction() { appState.moveToOtherPane() }
    @objc private func trashAction() { appState.trashSelection() }

    // MARK: NSToolbarDelegate
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .newTab, .toggleSecondPane, .space, .copyItem, .cutItem, .pasteItem, .space, .copyToOther, .moveToOther, .trashItem]
    }
    /// The allowed set is wider than the default: the customization palette must include
    /// separators too, otherwise the user can't arrange their own order.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .newTab, .toggleSecondPane, .copyItem, .cutItem, .pasteItem,
         .copyToOther, .moveToOther, .trashItem, .space, .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .newTab: return item(id, "plus", "New Tab", "Open a new tab window (\u{2318}T)", #selector(newTabAction))
        case .toggleSecondPane:
            let it = item(id, appState.showSecondPane ? "rectangle.split.2x1" : "rectangle", "Toggle Second Pane",
                          appState.showSecondPane ? "Hide second pane (\u{21e7}\u{2318}J)" : "Show second pane (\u{21e7}\u{2318}J)", #selector(toggleSecondPaneAction))
            toggleSecondPaneItem = it
            return it
        case .copyItem: return item(id, "doc.on.doc.fill", "Copy", "Copy selection to clipboard (\u{2318}C)", #selector(copyAction))
        case .cutItem: return item(id, "scissors", "Cut", "Cut selection to clipboard (\u{2318}X)", #selector(cutAction))
        case .pasteItem: return item(id, "doc.on.clipboard", "Paste", "Paste from clipboard into the current pane (\u{2318}V)", #selector(pasteAction))
        case .copyToOther: return item(id, "doc.on.doc", "Copy \u{2192}", "Copy selection to the other pane (F5)", #selector(copyToOtherAction))
        case .moveToOther: return item(id, "arrow.right.doc.on.clipboard", "Move \u{2192}", "Move selection to the other pane (F6)", #selector(moveToOtherAction))
        case .trashItem: return item(id, "trash", "Trash", "Move to Trash (\u{2318}\u{232b})", #selector(trashAction))
        default: return nil  // .toggleSidebar / .flexibleSpace / .space are system items provided by NSToolbar itself
        }
    }
    private func item(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ tooltip: String, _ action: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        it.label = label
        it.paletteLabel = label   // label in the "Customize Toolbar" palette
        it.toolTip = tooltip
        it.isBordered = true
        it.target = self
        it.action = action
        return it
    }
}

private extension NSToolbarItem.Identifier {
    static let newTab = NSToolbarItem.Identifier("marlia.newTab")
    static let toggleSecondPane = NSToolbarItem.Identifier("marlia.toggleSecondPane")
    static let copyItem = NSToolbarItem.Identifier("marlia.copy")
    static let cutItem = NSToolbarItem.Identifier("marlia.cut")
    static let pasteItem = NSToolbarItem.Identifier("marlia.paste")
    static let copyToOther = NSToolbarItem.Identifier("marlia.copyToOther")
    static let moveToOther = NSToolbarItem.Identifier("marlia.moveToOther")
    static let trashItem = NSToolbarItem.Identifier("marlia.trash")
}

/// The window split in AppKit: sidebar (`SidebarHostView`) ↔ content with the panes
/// (`PanesRootView`). Replaces SwiftUI's `NavigationSplitView`, which broke the sidebar's
/// width/resizing inside an AppKit window. The `autosaveName` is ours — the sidebar width is
/// saved reliably; the collapse button comes from the `.toggleSidebar` toolbar item
/// (`NSSplitViewController` is in the responder chain).
final class MarliaSplitViewController: NSSplitViewController {
    /// Keep a reference so the info panel can be expanded and collapsed according to
    /// AppState (see the subscription in MarliaWindowController).
    private(set) var inspectorItem: NSSplitViewItem?

    init(appState: AppState) {
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSHostingController(rootView: SidebarHostView(appState: appState))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        addSplitViewItem(sidebarItem)
        // Forbid keyboard focus on the sidebar list: clicking a row still navigates
        // (selection on mouseDown), but arrow keys never land on the sidebar — they always
        // move through the active pane. SwiftUI builds the list lazily/rebuilds it, so
        // refusesFirstResponder is set several times with a delay.
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak sidebar] in
                Self.refuseFirstResponder(in: sidebar?.view)
            }
        }

        let content = NSHostingController(rootView: PanesRootView(appState: appState))
        addSplitViewItem(NSSplitViewItem(viewController: content))

        // The info panel is the third split item, not part of PanesRootView. It needs
        // to observe the active pane, and PanesRootView must not do that: there every
        // selection step would redraw the whole window (see the comment on
        // PanesRootView). A separate NSHostingController keeps its redraws to itself.
        let inspector = NSHostingController(rootView: InspectorHostView(appState: appState))
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !appState.showInspector
        addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem

        splitView.autosaveName = "MarliaMainSplit"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setInspectorVisible(_ visible: Bool) {
        guard let inspectorItem, inspectorItem.isCollapsed == visible else { return }
        // Through the animator, as the system toggleSidebar does: without animation
        // the panel appears with a jerk and it's unclear where it came from.
        inspectorItem.animator().isCollapsed = !visible
    }

    /// Recursively takes away the sidebar tables'/outlines' ability to become first
    /// responder — so arrow keys never reach the sidebar list. Scope is the sidebar subtree
    /// only; the panes (with their own NSTableViews) are left alone.
    private static func refuseFirstResponder(in view: NSView?) {
        guard let view else { return }
        if let table = view as? NSTableView { table.refusesFirstResponder = true }
        for sub in view.subviews { refuseFirstResponder(in: sub) }
    }
}

/// An auxiliary window (Get Info / Archive Contents / Help / Settings) — same
/// technique: a SwiftUI view in an `NSHostingController`, an AppKit window. Replaces
/// the former SwiftUI `Window`/`WindowGroup(for:)` scenes + `openWindow`.
final class AuxWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    /// miniaturizable=false — for utility windows like Settings: by macOS convention
    /// they can't be minimized to the Dock.
    init<Content: View>(title: String, content: Content, contentSize: NSSize, resizable: Bool, miniaturizable: Bool = true) {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if miniaturizable { style.insert(.miniaturizable) }
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        ThemeStore.shared.apply(to: window)
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Owner and factory of the app's windows (main windows/tabs + auxiliary windows).
/// Nothing else retains the `NSWindowController`s anymore, so they're kept here and
/// removed on `windowWillClose`.
@MainActor
final class AppWindowManager {
    static let shared = AppWindowManager()
    private init() {}

    private var mainControllers: [MarliaWindowController] = []

    // MARK: Main windows / tabs

    @discardableResult
    func newWindow(restoring state: WindowState? = nil) -> MarliaWindowController {
        let controller = MarliaWindowController()
        mainControllers.append(controller)
        if let state {
            controller.appState.restore(from: state)
            if !state.frame.isEmpty { controller.window?.setFrame(NSRectFromString(state.frame), display: false) }
        }
        return controller
    }

    /// A new tab in the current window's group (⌘T / toolbar "+" / native "+"). An explicit
    /// `addTabbedWindow` is deterministic, unlike automatic merging by tabbingIdentifier.
    func requestNewTab() {
        let source = NSApp.keyWindow ?? NSApp.mainWindow ?? mainControllers.last?.window
        let controller = newWindow()
        // A new tab inherits the layout of the one it was opened from: each pane's view
        // mode and the number of panes. The key window may be an auxiliary one (Help,
        // Get Info) — then take the last main window.
        let sourceState = (source?.windowController as? MarliaWindowController)?.appState
            ?? mainControllers.last(where: { $0 !== controller })?.appState
        if let sourceState {
            controller.appState.showSecondPane = sourceState.showSecondPane
            controller.appState.leftPane.viewMode = sourceState.leftPane.viewMode
            controller.appState.rightPane.viewMode = sourceState.rightPane.viewMode
        }
        if let source, let win = controller.window {
            source.addTabbedWindow(win, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        // The AppKit split leaves first responder on the sidebar — move focus to the
        // active pane (async — after the window has become key and the hierarchy is
        // built).
        DispatchQueue.main.async { controller.appState.focusActivePane() }
    }

    func removeMain(_ controller: MarliaWindowController) {
        mainControllers.removeAll { $0 === controller }
    }

    /// Startup: one window per saved state, all as tabs of one group; with an empty
    /// session, one default window.
    func openInitialWindows() {
        let saved = WindowStateStore.load()
        guard let firstState = saved.first else {
            let only = newWindow()
            only.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { only.appState.focusActivePane() }
            return
        }
        let first = newWindow(restoring: firstState)
        first.window?.makeKeyAndOrderFront(nil)
        for state in saved.dropFirst() {
            let c = newWindow(restoring: state)
            if let win = c.window { first.window?.addTabbedWindow(win, ordered: .above) }
        }
        first.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { first.appState.focusActivePane() }
    }

    // MARK: Auxiliary windows

    private var helpController: AuxWindowController?
    private var settingsController: AuxWindowController?
    private var getInfoControllers: [URL: AuxWindowController] = [:]
    private var archiveControllers: [URL: AuxWindowController] = [:]
    private var diskImageControllers: [String: AuxWindowController] = [:]
    private var unmountObserver: NSObjectProtocol?

    func openHelp() {
        if let w = helpController?.window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let c = AuxWindowController(title: "Marlia Help", content: HelpView(),
                                    contentSize: NSSize(width: 560, height: 620), resizable: true)
        c.onClose = { [weak self] in self?.helpController = nil }
        helpController = c
        c.showAndFocus()
    }

    func openSettings() {
        if let w = settingsController?.window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let c = AuxWindowController(title: "Settings", content: ShortcutSettingsView(),
                                    contentSize: NSSize(width: 520, height: 480), resizable: false,
                                    miniaturizable: false)
        c.onClose = { [weak self] in self?.settingsController = nil }
        settingsController = c
        c.showAndFocus()
    }

    func openGetInfo(_ url: URL) {
        if let w = getInfoControllers[url]?.window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let c = AuxWindowController(title: url.lastPathComponent, content: GetInfoView(url: url),
                                    contentSize: NSSize(width: 340, height: 420), resizable: false)
        c.onClose = { [weak self] in self?.getInfoControllers[url] = nil }
        getInfoControllers[url] = c
        c.showAndFocus()
    }

    func openArchiveContents(_ url: URL) {
        if let w = archiveControllers[url]?.window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let c = AuxWindowController(title: url.lastPathComponent, content: ArchiveContentsView(url: url),
                                    contentSize: NSSize(width: 420, height: 480), resizable: true)
        c.onClose = { [weak self] in self?.archiveControllers[url] = nil }
        archiveControllers[url] = c
        c.showAndFocus()
    }

    /// The window of a mounted disk image (see `DiskImageOpener`), one per volume. Closes
    /// by itself when the volume is unmounted — by the Eject button in the window, from
    /// the sidebar or externally.
    func openDiskImage(volume: URL, image: URL) {
        // Keyed by path: URLs from hdiutil and from the notification may differ in a
        // trailing "/".
        let key = volume.standardizedFileURL.path
        if let w = diskImageControllers[key]?.window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let c = AuxWindowController(title: FileManager.default.displayName(atPath: volume.path),
                                    content: DiskImageInstallView(volume: volume, image: image),
                                    contentSize: NSSize(width: 480, height: 300), resizable: true)
        c.onClose = { [weak self] in self?.diskImageControllers[key] = nil }
        diskImageControllers[key] = c
        if unmountObserver == nil {
            unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
            ) { note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                Task { @MainActor in
                    AppWindowManager.shared.diskImageControllers[url.standardizedFileURL.path]?.close()
                }
            }
        }
        c.showAndFocus()
    }
}
