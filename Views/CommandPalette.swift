import AppKit

/// The command palette (⇧⌘P): type a few letters of any command, press Return.
///
/// Its list is not a separate registry — it is the **main menu itself**, walked at the moment
/// the palette opens. That way everything the menu can do is reachable (sort fields, themes,
/// columns, favorites by their real folder names, "Undo Rename" with its current label, user
/// commands), nothing has to be kept in sync by hand, and running an entry is literally the
/// same as choosing its menu item.
///
/// AppKit rather than SwiftUI for the same reason as the search/filter bars: the panel is
/// opened from a menu command while an AppKit table holds first responder, and only an
/// explicit `makeFirstResponder` reliably puts the caret into the field (see CLAUDE.md).
@MainActor
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = CommandPaletteController()

    struct Entry {
        let title: String
        let path: String
        let shortcut: String
        let item: NSMenuItem
    }

    private var panel: PalettePanel?
    private weak var hostWindow: NSWindow?
    private let field = NSTextField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    private var entries: [Entry] = []
    private var shown: [Entry] = []

    private static let width: CGFloat = 580
    private static let height: CGFloat = 392
    private static let rowHeight: CGFloat = 36

    // MARK: Showing

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        // The palette acts on the window it was opened from: commands reach their window's
        // AppState through NSApp.keyWindow, so that window becomes key again before an
        // entry runs.
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow, !(host is PalettePanel) else { return }
        hostWindow = host
        MainMenuController.shared.refreshDynamicState()
        entries = NSApp.mainMenu.map { Self.collect(from: $0, path: []) } ?? []
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.stringValue = ""
        refilter()

        let frame = host.frame
        panel.setFrame(NSRect(x: frame.midX - Self.width / 2, y: frame.maxY - 96 - Self.height,
                              width: Self.width, height: Self.height), display: false)
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func run(_ entry: Entry) {
        close()
        hostWindow?.makeKeyAndOrderFront(nil)
        // Next turn of the run loop: the host window must be key before the action runs,
        // both for AppStateRegistry.activeState and for responder-chain items like
        // Close Tab whose target is nil.
        let item = entry.item
        DispatchQueue.main.async {
            guard let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    // MARK: Collecting entries from the menu

    private static func collect(from menu: NSMenu, path: [String]) -> [Entry] {
        var result: [Entry] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // The Services menu belongs to other apps, and its contents depend on the
                // current selection in a way the palette can't reproduce.
                if submenu === NSApp.servicesMenu { continue }
                let title = submenu.title.isEmpty ? item.title : submenu.title
                result += collect(from: submenu, path: path + [title])
                continue
            }
            guard item.isEnabled, item.action != nil, !item.title.isEmpty else { continue }
            // Skip the palette itself and the per-window items AppKit adds to the Window menu.
            if item.title == AppCommand.commandPalette.title { continue }
            if item.representedObject is NSWindow || item.action == #selector(NSWindow.makeKeyAndOrderFront(_:)) { continue }
            result.append(Entry(title: item.title,
                                path: path.joined(separator: " › "),
                                shortcut: shortcutText(item),
                                item: item))
        }
        return result
    }

    /// "⇧⌘N", "F5", "⌘↑" from a menu item's key equivalent.
    static func shortcutText(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var flags = item.keyEquivalentModifierMask
        // An uppercase letter as key equivalent means Shift is part of it.
        if key.count == 1, let c = key.first, c.isLetter, c.isUppercase { flags.insert(.shift) }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyName(key)
    }

    private static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71F: return "F\(scalar.value - 0xF703)"   // NSF1FunctionKey = F704
        case 0x0D, 0x03: return "↩"
        case 0x08, 0x7F: return "⌫"
        case 0xF728: return "⌦"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }

    // MARK: Filtering

    private func refilter() {
        shown = FuzzyMatch.rank(entries, query: field.stringValue, title: \.title, context: \.path)
        table.reloadData()
        emptyLabel.isHidden = !shown.isEmpty
        if !shown.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let current = table.selectedRow < 0 ? -1 : table.selectedRow
        let next = min(max(current + delta, 0), shown.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): moveSelection(by: -8); return true
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): moveSelection(by: 8); return true
        case #selector(NSResponder.insertNewline(_:)):
            if shown.indices.contains(table.selectedRow) { run(shown[table.selectedRow]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); hostWindow?.makeKeyAndOrderFront(nil); return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PaletteCell.identifier, owner: nil) as? PaletteCell) ?? PaletteCell()
        cell.configure(shown[row])
        return cell
    }

    @objc private func tableDoubleClicked() {
        if shown.indices.contains(table.clickedRow) { run(shown[table.clickedRow]) }
    }

    // MARK: NSWindowDelegate — clicking anywhere else dismisses the palette

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Building the panel

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        panel.contentView = background

        field.placeholderString = "Type a command"
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        // The field keeps focus; the table only shows and is clicked.
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [field, separator, scroll, emptyLabel] as [NSView] { background.addSubview(view) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
        ])
        column.width = Self.width - 12
        return panel
    }
}

/// A titled, borderless-looking panel that can become key (a plain borderless window can't,
/// and then the field would never get the caret).
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        CommandPaletteController.shared.close()
        parent?.makeKeyAndOrderFront(nil)
    }
}

/// One row: the command title, its menu path underneath, the shortcut on the right.
private final class PaletteCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PaletteCell")
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingTail
        shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [title, path, shortcut] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            path.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ entry: CommandPaletteController.Entry) {
        title.stringValue = entry.title
        path.stringValue = entry.path
        shortcut.stringValue = entry.shortcut
    }
}
