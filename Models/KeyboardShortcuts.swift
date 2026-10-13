import AppKit
import Foundation

/// The registry of the file panes' keyboard commands.
///
/// Phase 1 of rebindable shortcuts: keys used to be handled by independent `switch event.keyCode`
/// statements with magic numbers (List — FileNSTableView.keyDown, Icons — FileIconsView, Columns
/// — handleActiveColumnKey in PaneView+Columns). Now the physical key is separated from the
/// MEANING of the action: handlers ask ShortcutStore for the command and handle that, so changing
/// a shortcut is an edit in one place, not three. The defaults reproduce the previous shortcuts
/// one to one.
///
/// Commands are deliberately semantic ("navigate left") rather than literal ("left arrow"): the
/// same `navigateLeft` moves the selection in Icons but goes to the parent column in Columns —
/// interpretation is up to the mode.

/// One shortcut: a physical key (keyCode) + the significant modifiers. keyCode rather
/// than a character — it doesn't depend on the keyboard layout (a character-based
/// record would break on a Cyrillic layout; keyCode↔character conversion is needed
/// only for the menu, that's phase 2).
struct Shortcut: Codable, Hashable {
    let keyCode: UInt16
    /// rawValue of the already-normalized modifiers (see `normalize`).
    let modifiers: UInt
    /// The character for `NSMenuItem.keyEquivalent`: the AppKit menu matches a shortcut
    /// BY CHARACTER, while the pane handlers match by keyCode. Both representations are
    /// stored rather than converting one into the other: keyCode→character conversion
    /// depends on the layout and would need UCKeyTranslate, whereas the shortcut
    /// recorder gets an NSEvent that already has both `keyCode` and
    /// `charactersIgnoringModifiers`. Empty — a menu item without a shortcut.
    let character: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], character: String = "") {
        self.keyCode = keyCode
        self.modifiers = Shortcut.normalize(modifiers).rawValue
        self.character = character
    }

    /// Format compatibility: shortcuts saved earlier have no `character` field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt.self, forKey: .modifiers)
        character = try container.decodeIfPresent(String.self, forKey: .character) ?? ""
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Keep only ⌘⇧⌥⌃. Critical: for arrows and Enter macOS additionally sets
    /// .function/.numericPad — without dropping them a "bare ↑" would NEVER match.
    /// It also gives strict comparison: ⇧↑ doesn't match a bare ↑ (which is exactly
    /// how List hands ⇧-arrows to the native NSTableView for range selection).
    static func normalize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && modifierFlags == Shortcut.normalize(event.modifierFlags)
    }

    /// Human-readable notation ("⇧⌘N", "↩", "⌫") — for the settings UI.
    var displayString: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    /// A special key by its own symbol; everything else by the recorded character
    /// (the recorder stores `charactersIgnoringModifiers` there, so the layout is
    /// already accounted for by the system and UCKeyTranslate isn't needed).
    private var keyLabel: String {
        if let name = Shortcut.specialKeyName(for: keyCode) { return name }
        if !character.isEmpty { return character.uppercased() }
        return "key \(keyCode)"
    }

    /// Keys without a printable character — only these need a name of their own.
    private static func specialKeyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"       // Enter on the numeric keypad
        case 117: return "⌦"      // Forward Delete
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 96: return "F5"
        case 97: return "F6"
        default: return nil
        }
    }
}

/// Section for grouping in the settings screen (phase 3) — doesn't affect the menu
/// structure, which MainMenu.swift sets explicitly.
enum CommandCategory: String, CaseIterable {
    case navigation, file, edit, view, actions, help

    var title: String {
        switch self {
        case .navigation: return "Navigation"
        case .file: return "File"
        case .edit: return "Edit"
        case .view: return "View"
        case .actions: return "Actions"
        case .help: return "Help"
        }
    }
}

/// An action that can be invoked from the keyboard.
enum AppCommand: String, CaseIterable, Codable {
    // Pane navigation (handled by the modes' keyDown, not the menu)
    case navigateUp, navigateDown, navigateLeft, navigateRight
    case openSelection, goToParentDirectory, switchPane
    // Menu
    case newTab
    case undo, redo
    case copy, cut, paste, selectAll, duplicate
    case copyToOtherPane, moveToOtherPane
    case moveToTrash, deleteImmediately
    case newFolder, newFile
    case refresh, find, getInfo, addToWorkspace
    case showContextMenu
    case zoomIn, zoomOut, actualSize
    case toggleHiddenFiles, toggleRecentsInSidebar, toggleSecondPane, toggleInspector
    case help
    // Commands that used to live only in the pane context menu or only as path-bar
    // buttons — now they're menu-bar items too, so they need a place in the registry.
    case quickLook, showInFinder, copyPath, openInTerminal, rename
    case compress, extractArchive, viewArchiveContents, addToFavorites
    case viewAsList, viewAsIcons, viewAsColumns
    case goBack, goForward, goHome, showRecents, connectToServer
    case filterItems, selectByPattern, invertSelection
    // Go to a favorite by its position — like Places in Dolphin.
    case goToFavorite1, goToFavorite2, goToFavorite3, goToFavorite4, goToFavorite5, goToFavorite6, goToFavorite7, goToFavorite8, goToFavorite9
    case batchRename

    /// Zero-based position in the favorites list for the go-to commands.
    var favoriteIndex: Int? {
        Self.favoriteCommands.firstIndex(of: self)
    }

    /// Go-to commands in order — the source for both the menu and the
    /// shortcuts.
    static let favoriteCommands: [AppCommand] = [
        .goToFavorite1, .goToFavorite2, .goToFavorite3, .goToFavorite4, .goToFavorite5,
        .goToFavorite6, .goToFavorite7, .goToFavorite8, .goToFavorite9,
    ]

    var title: String {
        switch self {
        case .navigateUp: return "Move Selection Up"
        case .navigateDown: return "Move Selection Down"
        case .navigateLeft: return "Move Selection Left / Parent Column"
        case .navigateRight: return "Move Selection Right / Enter Folder"
        case .openSelection: return "Open Selection"
        case .goToParentDirectory: return "Go to Parent Directory"
        case .switchPane: return "Switch Pane"
        case .newTab: return "New Tab"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .copy: return "Copy"
        case .cut: return "Cut"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .duplicate: return "Duplicate"
        case .copyToOtherPane: return "Copy to Other Pane"
        case .moveToOtherPane: return "Move to Other Pane"
        case .moveToTrash: return "Move to Trash"
        case .deleteImmediately: return "Delete Immediately…"
        case .newFolder: return "New Folder"
        case .newFile: return "New File"
        case .refresh: return "Refresh"
        case .find: return "Find"
        case .getInfo: return "Get Info"
        case .addToWorkspace: return "Add to Workspace"
        case .showContextMenu: return "Show Context Menu"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .toggleHiddenFiles: return "Show Hidden Files"
        case .toggleRecentsInSidebar: return "Show Recents in Sidebar"
        case .toggleSecondPane: return "Toggle Second Pane"
        case .toggleInspector: return "Show Info Panel"
        case .help: return "Marlia Help"
        case .quickLook: return "Quick Look"
        case .showInFinder: return "Show in Finder"
        case .copyPath: return "Copy Path"
        case .openInTerminal: return "Open in Terminal"
        case .rename: return "Rename"
        case .compress: return "Compress…"
        case .extractArchive: return "Extract"
        case .viewArchiveContents: return "View Archive Contents"
        case .addToFavorites: return "Add to Favorites"
        case .viewAsList: return "as List"
        case .viewAsIcons: return "as Icons"
        case .viewAsColumns: return "as Columns"
        case .goBack: return "Back"
        case .goForward: return "Forward"
        case .goHome: return "Home"
        case .showRecents: return "Recents"
        case .connectToServer: return "Connect to Server…"
        case .filterItems: return "Filter Items"
        case .selectByPattern: return "Select by Pattern…"
        case .invertSelection: return "Invert Selection"
        case .goToFavorite1, .goToFavorite2, .goToFavorite3, .goToFavorite4, .goToFavorite5,
             .goToFavorite6, .goToFavorite7, .goToFavorite8, .goToFavorite9:
            return "Favorite \((favoriteIndex ?? 0) + 1)"
        case .batchRename: return "Rename Multiple…"
        }
    }

    var category: CommandCategory {
        switch self {
        case .navigateUp, .navigateDown, .navigateLeft, .navigateRight,
             .openSelection, .goToParentDirectory, .switchPane,
             .goBack, .goForward, .goHome, .showRecents, .connectToServer,
             .goToFavorite1, .goToFavorite2, .goToFavorite3, .goToFavorite4, .goToFavorite5,
             .goToFavorite6, .goToFavorite7, .goToFavorite8, .goToFavorite9:
            return .navigation
        case .newTab, .newFolder, .newFile, .getInfo,
             .quickLook, .showInFinder, .openInTerminal,
             .compress, .extractArchive, .viewArchiveContents:
            return .file
        case .undo, .redo, .copy, .cut, .paste, .selectAll, .duplicate, .copyPath, .rename,
             .batchRename:
            return .edit
        case .zoomIn, .zoomOut, .actualSize, .toggleHiddenFiles,
             .toggleRecentsInSidebar, .toggleSecondPane, .toggleInspector,
             .viewAsList, .viewAsIcons, .viewAsColumns:
            return .view
        case .copyToOtherPane, .moveToOtherPane, .moveToTrash, .deleteImmediately,
             .refresh, .find, .addToWorkspace, .showContextMenu, .addToFavorites,
             .filterItems, .selectByPattern, .invertSelection:
            return .actions
        case .help:
            return .help
        }
    }

    /// The defaults are exactly the shortcuts that were in effect before the registry
    /// (pane ones from the old keyDown, menu ones from the old `.keyboardShortcut`). A
    /// list rather than a single value: Enter and Delete have historically had two
    /// equivalents each (the main key and the numeric keypad / forward delete).
    var defaultShortcuts: [Shortcut] {
        switch self {
        case .navigateUp: return [Shortcut(keyCode: 126)]
        case .navigateDown: return [Shortcut(keyCode: 125)]
        case .navigateLeft: return [Shortcut(keyCode: 123)]
        case .navigateRight: return [Shortcut(keyCode: 124)]
        // ⌘O first — it goes into the File ▸ Open menu item (as in Finder); ⏎ and
        // keypad ⏎ keep working in the panes themselves.
        case .openSelection:
            return [Shortcut(keyCode: 31, modifiers: .command, character: "o"),
                    Shortcut(keyCode: 36), Shortcut(keyCode: 76)]
        // ⌘↑ first — it's Finder's system convention, and it's what goes into the menu
        // item (menuShortcut takes the first one). Delete/⌦ stay as they were: strict
        // modifier comparison keeps them apart from the bare navigation arrow.
        case .goToParentDirectory:
            return [Shortcut(keyCode: 126, modifiers: .command, character: "\u{F700}"),
                    Shortcut(keyCode: 51), Shortcut(keyCode: 117)]
        case .switchPane: return [Shortcut(keyCode: 48)]

        case .newTab: return [Shortcut(keyCode: 17, modifiers: .command, character: "t")]
        case .undo: return [Shortcut(keyCode: 6, modifiers: .command, character: "z")]
        case .redo: return [Shortcut(keyCode: 6, modifiers: [.command, .shift], character: "z")]
        case .copy: return [Shortcut(keyCode: 8, modifiers: .command, character: "c")]
        case .cut: return [Shortcut(keyCode: 7, modifiers: .command, character: "x")]
        case .paste: return [Shortcut(keyCode: 9, modifiers: .command, character: "v")]
        case .selectAll: return [Shortcut(keyCode: 0, modifiers: .command, character: "a")]
        case .duplicate: return [Shortcut(keyCode: 2, modifiers: .command, character: "d")]
        // F5/F6: AppKit identifies a function key by its NSxxxFunctionKey Unicode value
        // (NSF5FunctionKey = F708), no modifiers needed — .function is dropped by
        // normalization anyway, otherwise arrow matching would break. This is exactly
        // what SwiftUI's .keyboardShortcut couldn't do, which is why F5/F6 didn't work
        // before.
        case .copyToOtherPane: return [Shortcut(keyCode: 96, character: "\u{F708}")]
        case .moveToOtherPane: return [Shortcut(keyCode: 97, character: "\u{F709}")]
        case .moveToTrash: return [Shortcut(keyCode: 51, modifiers: .command, character: "\u{8}")]
        case .deleteImmediately: return [Shortcut(keyCode: 51, modifiers: [.command, .option], character: "\u{8}")]
        case .newFolder: return [Shortcut(keyCode: 45, modifiers: [.command, .shift], character: "n")]
        case .newFile: return [Shortcut(keyCode: 45, modifiers: [.command, .option, .shift], character: "n")]
        case .refresh: return [Shortcut(keyCode: 15, modifiers: .command, character: "r")]
        case .find: return [Shortcut(keyCode: 3, modifiers: .command, character: "f")]
        case .getInfo: return [Shortcut(keyCode: 34, modifiers: .command, character: "i")]
        case .addToWorkspace: return [Shortcut(keyCode: 36, modifiers: [.command, .shift], character: "\r")]
        // ⌃↩ (Control-Return) — the context menu for the selected item from the
        // keyboard. Mnemonic: Ctrl-click = right-click; keyCode 36 = Return.
        case .showContextMenu: return [Shortcut(keyCode: 36, modifiers: .control, character: "\r")]
        case .zoomIn: return [Shortcut(keyCode: 24, modifiers: .command, character: "+")]
        case .zoomOut: return [Shortcut(keyCode: 27, modifiers: .command, character: "-")]
        case .actualSize: return [Shortcut(keyCode: 29, modifiers: .command, character: "0")]
        case .toggleHiddenFiles: return [Shortcut(keyCode: 47, modifiers: [.command, .shift], character: ".")]
        case .toggleRecentsInSidebar: return []   // menu item without a shortcut
        case .toggleSecondPane: return [Shortcut(keyCode: 38, modifiers: [.command, .shift], character: "j")]
        case .help: return [Shortcut(keyCode: 44, modifiers: .command, character: "?")]

        // Shortcuts are taken from Finder where it has an equivalent: ⌘Y — Quick
        // Look, ⌥⌘C — copy path, ⌘1/⌘2/⌘3 — view modes, ⌘[ / ⌘] — back/forward, ⇧⌘H
        // — home folder, ⇧⌘F — recents, ⌘K — connect to server.
        case .quickLook: return [Shortcut(keyCode: 16, modifiers: .command, character: "y")]
        case .showInFinder: return []
        case .copyPath: return [Shortcut(keyCode: 8, modifiers: [.command, .option], character: "c")]
        case .openInTerminal: return []
        case .rename: return []
        case .compress: return []
        case .extractArchive: return []
        case .viewArchiveContents: return []
        case .addToFavorites: return []
        case .viewAsList: return [Shortcut(keyCode: 18, modifiers: .command, character: "1")]
        case .viewAsIcons: return [Shortcut(keyCode: 19, modifiers: .command, character: "2")]
        case .viewAsColumns: return [Shortcut(keyCode: 20, modifiers: .command, character: "3")]
        case .goBack: return [Shortcut(keyCode: 33, modifiers: .command, character: "[")]
        case .goForward: return [Shortcut(keyCode: 30, modifiers: .command, character: "]")]
        case .goHome: return [Shortcut(keyCode: 4, modifiers: [.command, .shift], character: "h")]
        case .showRecents: return [Shortcut(keyCode: 3, modifiers: [.command, .shift], character: "f")]
        case .connectToServer: return [Shortcut(keyCode: 40, modifiers: .command, character: "k")]
        // ⌘F is taken by recursive search, so the filter is ⌥⌘F: a neighbouring
        // function, a neighbouring shortcut. ⌘I is taken by Get Info, so
        // inversion is ⌥⌘I.
        case .filterItems: return [Shortcut(keyCode: 3, modifiers: [.command, .option], character: "f")]
        case .selectByPattern: return [Shortcut(keyCode: 0, modifiers: [.command, .option], character: "a")]
        case .invertSelection: return [Shortcut(keyCode: 34, modifiers: [.command, .option], character: "i")]
        // ⌘R is taken by refreshing the pane, so batch rename is ⌥⌘R.
        case .batchRename: return [Shortcut(keyCode: 15, modifiers: [.command, .option], character: "r")]
        // ⌘I — Get Info, ⌥⌘I — invert selection, so the info panel is ⌃⌘I.
        case .toggleInspector: return [Shortcut(keyCode: 34, modifiers: [.command, .control], character: "i")]
        // ⌘1…⌘3 are taken by the view modes (as in Finder), and ⌃1…⌃9 are
        // usually grabbed by macOS for switching desktops.
        case .goToFavorite1, .goToFavorite2, .goToFavorite3, .goToFavorite4, .goToFavorite5,
             .goToFavorite6, .goToFavorite7, .goToFavorite8, .goToFavorite9:
            let position = (favoriteIndex ?? 0)
            let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
            return [Shortcut(keyCode: codes[position], modifiers: [.command, .option], character: "\(position + 1)")]
        }
    }

    /// The shortcut for the menu item — the first assigned one (a menu item has a
    /// single key equivalent).
    var menuShortcut: Shortcut? { ShortcutStore.shared.shortcuts(for: self).first }
}

/// The single source of truth for "which key invokes which command".
///
/// An app-wide singleton (shortcuts are shared by all windows/tabs, like
/// WorkspaceStore). Overrides are saved in UserDefaults; the store keeps the full
/// contract (set/reset) so the settings UI is just a screen on top of a ready
/// model.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    private static let defaultsKey = "Marlia.Shortcuts"

    /// User overrides: command → shortcuts. A missing key means "the command's
    /// defaults are used".
    @Published private(set) var overrides: [AppCommand: Shortcut]

    init(overrides: [AppCommand: Shortcut]? = nil) {
        if let overrides {
            self.overrides = overrides
        } else {
            self.overrides = Self.loadOverrides()
        }
    }

    /// The shortcuts the command currently responds to.
    func shortcuts(for command: AppCommand) -> [Shortcut] {
        if let override = overrides[command] { return [override] }
        return command.defaultShortcuts
    }

    /// The command for a key press, or nil — then the handler must pass the event on
    /// (super.keyDown) so it doesn't swallow someone else's key.
    func command(for event: NSEvent) -> AppCommand? {
        AppCommand.allCases.first { command in
            shortcuts(for: command).contains { $0.matches(event) }
        }
    }

    /// nil — restore the command's default.
    func setShortcut(_ shortcut: Shortcut?, for command: AppCommand) {
        if let shortcut {
            overrides[command] = shortcut
        } else {
            overrides.removeValue(forKey: command)
        }
        saveOverrides()
    }

    func resetAll() {
        overrides.removeAll()
        saveOverrides()
    }

    // MARK: Assignment validation

    /// Shortcuts that can't be taken: the system or macOS itself expects them, and
    /// intercepting them would leave the user with no way to quit the app/close a
    /// window.
    private static let reserved: [Shortcut] = [
        Shortcut(keyCode: 12, modifiers: .command, character: "q"),  // ⌘Q — quit
        Shortcut(keyCode: 13, modifiers: .command, character: "w"),  // ⌘W — close window
        Shortcut(keyCode: 4, modifiers: .command, character: "h"),   // ⌘H — hide
        Shortcut(keyCode: 46, modifiers: .command, character: "m"),  // ⌘M — minimize
        Shortcut(keyCode: 43, modifiers: .command, character: ","),  // ⌘, — settings
        Shortcut(keyCode: 48, modifiers: .command),                  // ⌘Tab — app switching
    ]

    static func isReserved(_ shortcut: Shortcut) -> Bool {
        reserved.contains { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }
    }

    /// Other commands assigned the same shortcut. An empty array means no conflict.
    /// Compared by key + modifiers rather than by object: for commands with several
    /// equivalents (Enter and keypad Enter) a match on any of them is enough.
    func conflicts(for command: AppCommand) -> [AppCommand] {
        let mine = shortcuts(for: command)
        guard !mine.isEmpty else { return [] }
        return AppCommand.allCases.filter { other in
            guard other != command else { return false }
            return shortcuts(for: other).contains { candidate in
                mine.contains { $0.keyCode == candidate.keyCode && $0.modifiers == candidate.modifiers }
            }
        }
    }

    // MARK: Persistence

    private static func loadOverrides() -> [AppCommand: Shortcut] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data)
        else { return [:] }
        // Unknown keys (a command disappeared between versions) are simply
        // dropped — that makes the format forward- and backward-compatible
        // without a separate migration.
        return decoded.reduce(into: [:]) { result, pair in
            if let command = AppCommand(rawValue: pair.key) { result[command] = pair.value }
        }
    }

    private func saveOverrides() {
        let encodable = overrides.reduce(into: [String: Shortcut]()) { $0[$1.key.rawValue] = $1.value }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
