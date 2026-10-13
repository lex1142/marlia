import AppKit

/// The app's main menu, built by hand in AppKit.
///
/// Why not SwiftUI `.commands`: there `.keyboardShortcut` takes a static
/// `KeyEquivalent`, doesn't support function keys (that's why F5/F6 didn't work —
/// AppKit complained about `.function` at launch) and doesn't allow changing a
/// shortcut at runtime. On `NSMenuItem`, `keyEquivalent` is a plain property:
/// assign it and it takes effect immediately. That's the whole point of moving the
/// menu to AppKit — shortcuts come from the `ShortcutStore` shared with the panes,
/// and `refreshShortcuts()` applies changes without a restart.
///
/// This continues the project's established "one input surface — one owner" line:
/// List, the Icons/Columns gestures and the context menus are already AppKit
/// (`ClosureMenuItem` is reused here as well).
@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {
    static let shared = MainMenuController()

    /// Bridges to SwiftUI scenes: an AppKit action can't reach
    /// `@Environment(\.openWindow)`, so the root view passes closures in here —
    /// the same technique already used for `AppDelegate.openNewTab`.
    static var openHelpWindow: (() -> Void)?
    static var openGetInfoWindow: ((URL) -> Void)?
    static var openSettingsWindow: (() -> Void)?

    /// Items with a rebindable shortcut — so `refreshShortcuts()` can reassign the
    /// key equivalent without rebuilding the menu.
    private var itemsByCommand: [AppCommand: NSMenuItem] = [:]
    /// Items with dynamic state (checkmark/title), updated before the menu is shown.
    private var hiddenFilesItem: NSMenuItem?
    private var recentsItem: NSMenuItem?
    private var secondPaneItem: NSMenuItem?
    private var inspectorItem: NSMenuItem?
    private var viewModeItems: [ViewMode: NSMenuItem] = [:]
    private var sortFieldItems: [SortField: NSMenuItem] = [:]
    private var groupFieldItems: [GroupField: NSMenuItem] = [:]
    private var columnItems: [FileTableColumn: NSMenuItem] = [:]
    private var themeItems: [AppTheme: NSMenuItem] = [:]
    private var undoItem: NSMenuItem?
    private var redoItem: NSMenuItem?
    /// Nine go-to-favorite slots. The items are created right away rather than in
    /// menuNeedsUpdate: a shortcut is matched against existing items, and for one
    /// created up front it works even before the menu has ever been opened (verified
    /// by calling performKeyEquivalent on a menu that was never opened).
    private var favoriteItems: [NSMenuItem] = []
    private var goBackItem: NSMenuItem?
    private var goForwardItem: NSMenuItem?
    private var goUpItem: NSMenuItem?

    private var appState: AppState? { AppStateRegistry.activeState }

    /// Our assembled menu — a reference is kept so it can be restored when SwiftUI
    /// swaps it out.
    private var installedMenu: NSMenu?
    private var menuGuardObserver: Any?

    // MARK: Installation

    func install() {
        let menu = buildMainMenu()
        installedMenu = menu
        NSApp.mainMenu = menu
        // SwiftUI manages NSApp.mainMenu according to its scenes and replaces our AppKit
        // menu with its own generated one (empirically — after a window minimize→restore,
        // but NOT at didBecomeMain, later; confirmed by logs: the File menu disappeared,
        // ⌘T stopped working). The most reliable approach is to guard this on
        // didUpdateNotification (posted at the end of every event-loop iteration): the
        // check is cheap (a pointer comparison), and the menu is restored only when it
        // really isn't ours (no "fighting", since SwiftUI swaps it only on a scene change,
        // not on every update).
        if menuGuardObserver == nil {
            menuGuardObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // "Our" menu is recognized by the presence of the File submenu: SwiftUI cuts
                // our items out of THE SAME object (verified — same pointer, but 4 items
                // instead of ours, the File menu is gone), so comparing pointers is useless.
                // If File is missing, the menu has been gutted — rebuild a fresh one and put
                // it back.
                if NSApp.mainMenu?.items.contains(where: { $0.title == "File" }) == true { return }
                let fresh = self.buildMainMenu()
                self.installedMenu = fresh
                NSApp.mainMenu = fresh
            }
        }
    }

    /// Apply the current shortcuts from ShortcutStore (phase 3: after a change in
    /// settings).
    func refreshShortcuts() {
        for (command, item) in itemsByCommand { applyShortcut(command, to: item) }
    }

    // MARK: Building

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: "Marlia"))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        main.addItem(submenu(goMenu(), title: "Go"))
        main.addItem(submenu(actionsMenu(), title: "Actions"))

        let window = windowMenu()
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window  // AppKit adds the tab items to it by itself

        let help = helpMenu()
        main.addItem(submenu(help, title: "Help"))
        // An explicit assignment rather than "the system will find a menu titled
        // Help": only this guarantees the system menu-search field appears.
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(standard("About Marlia", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // ⌘, is a system convention, so the item isn't rebindable (see reserved in
        // ShortcutStore) and is built by hand rather than from the command
        // registry.
        let settings = ClosureMenuItem(title: "Settings…") { Self.openSettingsWindow?() }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        menu.addItem(.separator())
        let services = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(standard("Hide Marlia", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(standard("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(standard("Quit Marlia", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command(.newTab) { AppDelegate.requestNewTab() })
        menu.addItem(.separator())
        menu.addItem(command(.newFolder) { [weak self] in self?.appState?.createFolder() })
        menu.addItem(command(.newFile) { [weak self] in self?.appState?.createFile() })
        menu.addItem(.separator())
        menu.addItem(command(.openSelection) { [weak self] in self?.appState?.openSelection() })
        menu.addItem(command(.quickLook) { [weak self] in self?.appState?.quickLookSelection() })
        menu.addItem(command(.openInTerminal) { [weak self] in self?.appState?.openActiveInTerminal() })
        menu.addItem(.separator())
        menu.addItem(command(.getInfo) { [weak self] in
            guard let url = self?.appState?.activePane.selectedItems.first?.url else { return }
            Self.openGetInfoWindow?(url)
        })
        menu.addItem(command(.showInFinder) { [weak self] in self?.appState?.showSelectionInFinder() })
        menu.addItem(.separator())
        menu.addItem(command(.compress) { [weak self] in self?.appState?.compressSelection() })
        menu.addItem(command(.extractArchive) { [weak self] in self?.appState?.extractSelection() })
        menu.addItem(command(.viewArchiveContents) { [weak self] in
            guard let url = self?.appState?.selectedArchive?.url else { return }
            AppWindowManager.shared.openArchiveContents(url)
        })
        menu.addItem(.separator())
        // ⌘W closes the tab, ⇧⌘W the whole window: that's the macOS convention for
        // tabbed apps. Each tab here is a separate window in a tab group, so "close
        // window" = close all windows of its group.
        menu.addItem(standard("Close Tab", #selector(NSWindow.performClose(_:)), "w"))
        let closeWindow = ClosureMenuItem(title: "Close Window") {
            guard let window = NSApp.keyWindow else { return }
            for tabbed in window.tabGroup?.windows ?? [window] { tabbed.performClose(nil) }
        }
        closeWindow.keyEquivalent = "w"
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindow)
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        // Undo/Redo are disabled when the stack is empty, so the menu stops enabling the
        // items by itself.
        menu.delegate = self
        menu.autoenablesItems = false
        let undo = command(.undo) { [weak self] in self?.appState?.undoLast() }
        let redo = command(.redo) { [weak self] in self?.appState?.redoLast() }
        undoItem = undo
        redoItem = redo
        menu.addItem(undo)
        menu.addItem(redo)
        menu.addItem(.separator())
        // Cut/Copy/Paste/Select All are FILE operations, BUT only when no text is being
        // edited. A menu item's key equivalent is intercepted before the event reaches
        // the field being edited (inline rename, search, path bar), so with an active
        // field editor the standard text action is forwarded to it first — otherwise
        // ⌘C/⌘X/⌘V/⌘A in a file name would act on files rather than text.
        menu.addItem(command(.cut) { [weak self] in
            guard self?.forwardEditingAction(#selector(NSText.cut(_:))) != true else { return }
            self?.appState?.cutSelection()
        })
        menu.addItem(command(.copy) { [weak self] in
            guard self?.forwardEditingAction(#selector(NSText.copy(_:))) != true else { return }
            self?.appState?.copySelection()
        })
        menu.addItem(command(.paste) { [weak self] in
            guard self?.forwardEditingAction(#selector(NSText.paste(_:))) != true else { return }
            self?.appState?.pasteIntoActive()
        })
        menu.addItem(.separator())
        menu.addItem(command(.selectAll) { [weak self] in
            guard self?.forwardEditingAction(#selector(NSText.selectAll(_:))) != true else { return }
            self?.appState?.selectAllInActive()
        })
        menu.addItem(command(.selectByPattern) { [weak self] in self?.appState?.beginSelectByPattern() })
        menu.addItem(command(.invertSelection) { [weak self] in self?.appState?.invertSelectionInActivePane() })
        menu.addItem(.separator())
        menu.addItem(command(.duplicate) { [weak self] in self?.appState?.duplicateSelection() })
        menu.addItem(command(.copyPath) { [weak self] in self?.appState?.copySelectionPath() })
        menu.addItem(command(.rename) { [weak self] in self?.appState?.renameSelection() })
        menu.addItem(command(.batchRename) { [weak self] in self?.appState?.beginBatchRename() })
        menu.addItem(.separator())
        menu.addItem(command(.find) { [weak self] in
            self?.appState?.activePane.isSearchBarVisible.toggle()
        })
        menu.addItem(command(.filterItems) { [weak self] in self?.appState?.toggleFilterBar() })
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self  // menuNeedsUpdate will refresh the checkmarks/title
        menu.addItem(standard("Toggle Sidebar", Selector(("toggleSidebar:"))))
        menu.addItem(.separator())

        // View modes used to exist only as segments in the pane — they weren't in the
        // menu bar at all, although it's one of the app's main commands (⌘1/2/3 in
        // Finder).
        let modeItems: [(AppCommand, ViewMode)] = [(.viewAsList, .list), (.viewAsIcons, .icons), (.viewAsColumns, .columns)]
        for (cmd, mode) in modeItems {
            let item = command(cmd) { [weak self] in self?.appState?.setViewMode(mode) }
            viewModeItems[mode] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Sort By / Group By / Show View Options — also used to be available only via
        // right-click inside the pane.
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortSubmenu = NSMenu(title: "Sort By")
        for field in SortField.allCases {
            let item = ClosureMenuItem(title: field.label) { [weak self] in self?.appState?.setSortActive(field) }
            sortFieldItems[field] = item
            sortSubmenu.addItem(item)
        }
        sortItem.submenu = sortSubmenu
        menu.addItem(sortItem)

        let groupItem = NSMenuItem(title: "Group By", action: nil, keyEquivalent: "")
        let groupSubmenu = NSMenu(title: "Group By")
        for field in GroupField.allCases {
            let item = ClosureMenuItem(title: field.label) { [weak self] in self?.appState?.setGroupActive(field) }
            groupFieldItems[field] = item
            groupSubmenu.addItem(item)
        }
        groupItem.submenu = groupSubmenu
        menu.addItem(groupItem)

        let columnsItem = NSMenuItem(title: "Show View Options", action: nil, keyEquivalent: "")
        let columnsSubmenu = NSMenu(title: "Show View Options")
        // Without this AppKit enables the items itself (they have a
        // target/action) and our isEnabled from menuNeedsUpdate is ignored.
        columnsSubmenu.autoenablesItems = false
        for column in FileTableColumn.optional {
            let item = ClosureMenuItem(title: column.title) {
                let key = Self.columnDefaultsKey(column)
                let defaults = UserDefaults.standard
                // The same key as @AppStorage in PaneView — a write here is picked up by it
                // ("Show Recents in Sidebar" already works the same way).
                let current = defaults.object(forKey: key) as? Bool ?? Self.columnDefaultValue(column)
                defaults.set(!current, forKey: key)
            }
            columnItems[column] = item
            columnsSubmenu.addItem(item)
        }
        columnsItem.submenu = columnsSubmenu
        menu.addItem(columnsItem)
        menu.addItem(.separator())

        // The theme is app-wide (see ThemeStore), so it isn't tied to the active window,
        // unlike the mode/sort above.
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu(title: "Theme")
        for theme in AppTheme.allCases {
            // System isn't a palette but "don't interfere"; it's separated from the
            // rest by a line.
            if theme != .system, themeSubmenu.items.count == 1 { themeSubmenu.addItem(.separator()) }
            let item = ClosureMenuItem(title: theme.title) { ThemeStore.shared.set(theme) }
            themeItems[theme] = item
            themeSubmenu.addItem(item)
        }
        themeItem.submenu = themeSubmenu
        menu.addItem(themeItem)
        menu.addItem(.separator())

        menu.addItem(command(.zoomIn) { [weak self] in self?.appState?.zoomInActive() })
        menu.addItem(command(.zoomOut) { [weak self] in self?.appState?.zoomOutActive() })
        menu.addItem(command(.actualSize) { [weak self] in self?.appState?.resetZoomActive() })
        menu.addItem(.separator())

        let hidden = command(.toggleHiddenFiles) { [weak self] in
            self?.appState?.activePane.showHidden.toggle()
        }
        hiddenFilesItem = hidden
        menu.addItem(hidden)

        let recents = command(.toggleRecentsInSidebar) {
            let key = "Marlia.showRecentsInSidebar"
            let defaults = UserDefaults.standard
            // The key is shared with @AppStorage in SidebarView — a write here is
            // picked up by it.
            let current = defaults.object(forKey: key) as? Bool ?? true
            defaults.set(!current, forKey: key)
        }
        recentsItem = recents
        menu.addItem(recents)

        menu.addItem(.separator())
        let secondPane = command(.toggleSecondPane) { [weak self] in self?.appState?.toggleSecondPane() }
        secondPaneItem = secondPane
        menu.addItem(secondPane)
        let inspector = command(.toggleInspector) { [weak self] in self?.appState?.toggleInspector() }
        inspectorItem = inspector
        menu.addItem(inspector)
        menu.addItem(.separator())
        // The system doesn't add this item by itself — AppKit templates always
        // declare it by hand, and without it full screen is available only via the
        // green button.
        let fullScreen = standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(fullScreen)
        return menu
    }

    /// The Go menu: navigation used to be available only through the path-bar
    /// buttons (back/forward) and the Delete key (one level up) — it wasn't in the
    /// menu bar at all.
    private func goMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self          // menuNeedsUpdate disables items with nowhere to go
        menu.autoenablesItems = false // otherwise AppKit enables them itself (the items have a target)
        let back = command(.goBack) { [weak self] in self?.appState?.goBackActive() }
        let forward = command(.goForward) { [weak self] in self?.appState?.goForwardActive() }
        let up = command(.goToParentDirectory) { [weak self] in self?.appState?.goUpActive() }
        goBackItem = back
        goForwardItem = forward
        goUpItem = up
        menu.addItem(back)
        menu.addItem(forward)
        menu.addItem(up)
        menu.addItem(.separator())
        menu.addItem(command(.goHome) { [weak self] in self?.appState?.goHomeActive() })
        menu.addItem(command(.showRecents) { [weak self] in self?.appState?.showRecentsActive() })
        menu.addItem(.separator())
        menu.addItem(command(.connectToServer) { [weak self] in self?.appState?.connectToServer() })
        menu.addItem(.separator())
        favoriteItems = AppCommand.favoriteCommands.enumerated().map { index, favoriteCommand in
            let item = command(favoriteCommand) { [weak self] in self?.appState?.goToFavorite(at: index) }
            menu.addItem(item)
            return item
        }
        return menu
    }

    private func actionsMenu() -> NSMenu {
        let menu = NSMenu()
        // Switch Pane deliberately has no key equivalent: a global Tab would
        // intercept tabbing in text fields (rename/search/path). Tab is handled by
        // the modes themselves — see switchActivePaneIfPossible() in PaneView.swift.
        menu.addItem(command(.switchPane) { [weak self] in self?.appState?.toggleActivePane() })
        menu.addItem(.separator())
        menu.addItem(command(.copyToOtherPane) { [weak self] in self?.appState?.copyToOtherPane() })
        menu.addItem(command(.moveToOtherPane) { [weak self] in self?.appState?.moveToOtherPane() })
        menu.addItem(.separator())
        menu.addItem(command(.moveToTrash) { [weak self] in self?.appState?.trashSelection() })
        menu.addItem(command(.deleteImmediately) { [weak self] in self?.appState?.deletePermanently() })
        menu.addItem(.separator())
        menu.addItem(command(.refresh) { [weak self] in self?.appState?.refreshActive() })
        menu.addItem(.separator())
        menu.addItem(command(.addToFavorites) { [weak self] in self?.appState?.addSelectionToFavorites() })
        menu.addItem(command(.addToWorkspace) { [weak self] in
            guard let items = self?.appState?.activePane.selectedItems, !items.isEmpty else { return }
            WorkspaceStore.shared.addToDefaultWorkspace(items)
        })
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(standard("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command(.help) { Self.openHelpWindow?() })
        return menu
    }

    // MARK: Items

    /// An item bound to a registry command: the title and shortcut come from
    /// there.
    private func command(_ command: AppCommand, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: command.title, handler: action)
        applyShortcut(command, to: item)
        itemsByCommand[command] = item
        return item
    }

    private func applyShortcut(_ command: AppCommand, to item: NSMenuItem) {
        guard let shortcut = command.menuShortcut, !shortcut.character.isEmpty else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = shortcut.character
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    /// If text is currently being edited (first responder is a field editor: inline rename,
    /// search, path bar), forwards the standard editing action to it
    /// (cut:/copy:/paste:/selectAll:) and returns true. Otherwise false — the caller performs
    /// the file operation. That way ⌘C/⌘X/⌘V/⌘A in a text field act on TEXT, not on files.
    private func forwardEditingAction(_ selector: Selector) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// A system item that works through the responder chain (target = nil).
    private func standard(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: selector, keyEquivalent: key)
    }

    // MARK: NSMenuDelegate — dynamic state

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The title changes along with the state: "Undo Rename" is clearer than a
        // faceless "Undo", especially when you can rewind fifty steps back.
        let history = appState
        undoItem?.isEnabled = history?.canUndo ?? false
        undoItem?.title = history?.undoLabel.map { "Undo \($0)" } ?? AppCommand.undo.title
        redoItem?.isEnabled = history?.canRedo ?? false
        redoItem?.title = history?.redoLabel.map { "Redo \($0)" } ?? AppCommand.redo.title
        let state = appState
        // Show the real folder names rather than "Favorite 3": a menu item naming its
        // destination is far more useful than a number. Unused slots are hidden — but
        // ONLY hidden, nothing more: verified that a hidden (and even a disabled) item
        // still catches its shortcut. What makes ⌥7 harmless with three favorites
        // isn't the hiding but the range check in goToFavorite(at:).
        let favorites = state?.favorites.items ?? []
        for (index, item) in favoriteItems.enumerated() {
            if index < favorites.count {
                item.isHidden = false
                item.title = favorites[index].lastPathComponent
            } else {
                item.isHidden = true
            }
        }
        if let pane = state?.activePane {
            goBackItem?.isEnabled = pane.canGoBack
            goForwardItem?.isEnabled = pane.canGoForward
            goUpItem?.isEnabled = pane.canGoUp
        }
        hiddenFilesItem?.state = (state?.activePane.showHidden ?? false) ? .on : .off
        let showRecents = UserDefaults.standard.object(forKey: "Marlia.showRecentsInSidebar") as? Bool ?? true
        recentsItem?.state = showRecents ? .on : .off
        secondPaneItem?.title = (state?.showSecondPane == false) ? "Show Second Pane" : "Hide Second Pane"
        inspectorItem?.state = (state?.showInspector ?? false) ? .on : .off

        // "What's currently selected" checkmarks for mode/sort/grouping/columns —
        // computed from the active pane right before the menu is shown; no live updates
        // are needed (the same approach as the pane's context menu).
        let pane = state?.activePane
        for (mode, item) in viewModeItems { item.state = pane?.viewMode == mode ? .on : .off }
        for (field, item) in sortFieldItems { item.state = pane?.activeSortField == field ? .on : .off }
        for (field, item) in groupFieldItems { item.state = pane?.groupBy == field ? .on : .off }
        for (theme, item) in themeItems { item.state = ThemeStore.shared.theme == theme ? .on : .off }
        for (column, item) in columnItems {
            let key = Self.columnDefaultsKey(column)
            let visible = UserDefaults.standard.object(forKey: key) as? Bool ?? Self.columnDefaultValue(column)
            item.state = visible ? .on : .off
            // Columns exist only in List mode — in the others the item is
            // disabled.
            item.isEnabled = pane?.viewMode == .list
        }
    }

    /// Keys and defaults are the same as @AppStorage in PaneView (the only place the
    /// columns are actually stored).
    private static func columnDefaultsKey(_ column: FileTableColumn) -> String {
        switch column {
        case .modified: return "Marlia.col.modified"
        case .created: return "Marlia.col.created"
        case .lastOpened: return "Marlia.col.lastOpened"
        case .dateAdded: return "Marlia.col.dateAdded"
        case .size: return "Marlia.col.size"
        case .kind: return "Marlia.col.kind"
        case .tags: return "Marlia.col.tags"
        case .name: return ""
        }
    }

    private static func columnDefaultValue(_ column: FileTableColumn) -> Bool {
        switch column {
        case .modified, .size, .kind: return true
        default: return false
        }
    }
}
