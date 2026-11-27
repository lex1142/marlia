import AppKit

/// A type-to-find panel over the window: one text field, a ranked list, Return runs the
/// selected entry. Two pickers share it:
/// - the **command palette** (⇧⌘P) — every menu command, see `CommandSource`;
/// - **Go to Folder** (⇧⌘G) — a typed path with completion, plus recent folders, see
///   `FolderSource`.
///
/// AppKit rather than SwiftUI for the same reason as the search/filter bars: the panel opens
/// from a menu command while an AppKit table holds first responder, and only an explicit
/// `makeFirstResponder` reliably puts the caret into the field (see CLAUDE.md).
struct QuickPickerEntry {
    let title: String
    let subtitle: String
    let trailing: String
    /// What Tab puts into the field (path completion); nil — Tab does nothing.
    var completion: String? = nil
    let run: () -> Void
}

@MainActor
protocol QuickPickerSource: AnyObject {
    var placeholder: String { get }
    var emptyText: String { get }
    /// Called when the panel opens, while the host window is still key.
    func prepare()
    func entries(for query: String) -> [QuickPickerEntry]
}

@MainActor
final class QuickPickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    static let commands = QuickPickerController(source: CommandSource())
    static let folders = QuickPickerController(source: FolderSource())

    private let source: QuickPickerSource
    private var panel: QuickPickerPanel?
    private weak var hostWindow: NSWindow?
    private let field = NSTextField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var shown: [QuickPickerEntry] = []

    private static let width: CGFloat = 580
    private static let height: CGFloat = 392
    private static let rowHeight: CGFloat = 36

    init(source: QuickPickerSource) {
        self.source = source
        super.init()
    }

    // MARK: Showing

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        // The picker acts on the window it was opened from: commands reach their window's
        // AppState through NSApp.keyWindow, so that window becomes key again before an
        // entry runs.
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow, !(host is QuickPickerPanel) else { return }
        // Only one picker at a time.
        for other in [Self.commands, Self.folders] where other !== self { other.close() }
        hostWindow = host
        source.prepare()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.placeholderString = source.placeholder
        emptyLabel.stringValue = source.emptyText
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
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    fileprivate func dismiss() {
        close()
        hostWindow?.makeKeyAndOrderFront(nil)
    }

    private func run(_ entry: QuickPickerEntry) {
        dismiss()
        // Next turn of the run loop: the host window must be key before the action runs,
        // both for AppStateRegistry.activeState and for responder-chain menu items like
        // Close Tab whose target is nil.
        DispatchQueue.main.async { entry.run() }
    }

    // MARK: Filtering

    private func refilter() {
        shown = source.entries(for: field.stringValue)
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
        case #selector(NSResponder.insertTab(_:)):
            if shown.indices.contains(table.selectedRow), let completion = shown[table.selectedRow].completion {
                field.stringValue = completion
                textView.moveToEndOfDocument(nil)
                refilter()
            }
            return true   // Tab never leaves the field
        case #selector(NSResponder.insertNewline(_:)):
            if shown.indices.contains(table.selectedRow) { run(shown[table.selectedRow]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: QuickPickerCell.identifier, owner: nil) as? QuickPickerCell) ?? QuickPickerCell()
        cell.configure(shown[row])
        return cell
    }

    @objc private func tableDoubleClicked() {
        if shown.indices.contains(table.clickedRow) { run(shown[table.clickedRow]) }
    }

    // MARK: NSWindowDelegate — clicking anywhere else dismisses the panel

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Building the panel

    private func makePanel() -> QuickPickerPanel {
        let panel = QuickPickerPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                                     styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.owner = self
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

        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        // Single line that scrolls sideways: without wraps/isScrollable a long path wraps
        // onto a second line and the first one is pushed out of the field's frame.
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
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
final class QuickPickerPanel: NSPanel {
    weak var owner: QuickPickerController?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { owner?.dismiss() }
}

/// One row: the title, a secondary line underneath, a right-aligned hint (shortcut).
private final class QuickPickerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QuickPickerCell")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead   // paths: keep the end visible
        trailing.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        trailing.textColor = .secondaryLabelColor
        trailing.alignment = .right
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [title, subtitle, trailing] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ entry: QuickPickerEntry) {
        title.stringValue = entry.title
        subtitle.stringValue = entry.subtitle
        trailing.stringValue = entry.trailing
    }
}

// MARK: - Command palette (⇧⌘P)

/// Every menu command. The list is **the main menu itself**, walked when the palette opens:
/// that way sort fields, themes, columns, favorites by their real folder names, "Undo Rename"
/// with its current label and user commands are all reachable without a separate registry
/// to keep in sync, and running an entry is literally choosing its menu item.
@MainActor
final class CommandSource: QuickPickerSource {
    let placeholder = "Type a command"
    let emptyText = "No matching commands"

    private struct Command {
        let title: String
        let path: String
        let shortcut: String
        let item: NSMenuItem
    }
    private var commands: [Command] = []

    func prepare() {
        MainMenuController.shared.refreshDynamicState()
        commands = NSApp.mainMenu.map { Self.collect(from: $0, path: []) } ?? []
    }

    func entries(for query: String) -> [QuickPickerEntry] {
        FuzzyMatch.rank(commands, query: query, title: \.title, context: \.path).map { command in
            let item = command.item
            return QuickPickerEntry(title: command.title, subtitle: command.path, trailing: command.shortcut) {
                guard let action = item.action else { return }
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
    }

    private static func collect(from menu: NSMenu, path: [String]) -> [Command] {
        var result: [Command] = []
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
            // Skip the pickers themselves and the per-window items AppKit adds to the Window menu.
            if item.title == AppCommand.commandPalette.title { continue }
            if item.representedObject is NSWindow || item.action == #selector(NSWindow.makeKeyAndOrderFront(_:)) { continue }
            result.append(Command(title: item.title, path: path.joined(separator: " › "),
                                  shortcut: shortcutText(item), item: item))
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
}

// MARK: - Go to Folder (⇧⌘G)

/// A path typed by hand (`~`, absolute, or relative to the active pane's folder; Tab
/// completes the last component) plus the recently visited folders. A file path goes to its
/// folder and selects the file.
@MainActor
final class FolderSource: QuickPickerSource {
    let placeholder = "Go to folder: type a path, ~ for home, Tab completes"
    let emptyText = "No such folder"

    private weak var appState: AppState?
    private var recents: [URL] = []

    func prepare() {
        appState = AppStateRegistry.activeState
        let fm = FileManager.default
        recents = RecentFolders.shared.items.filter { fm.fileExists(atPath: $0.path) }
    }

    func entries(for query: String) -> [QuickPickerEntry] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        var result: [QuickPickerEntry] = []
        var seen = Set<String>()

        if !typed.isEmpty {
            let base = appState?.activePane.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
            let resolved = PathInput.resolve(typed, relativeTo: base)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) {
                let url = resolved
                result.append(QuickPickerEntry(
                    title: isDirectory.boolValue ? "Go to \(PathInput.display(url))" : "Show \(url.lastPathComponent)",
                    subtitle: isDirectory.boolValue ? "Folder" : "In \(PathInput.display(url.deletingLastPathComponent()))",
                    trailing: "↩",
                    completion: isDirectory.boolValue ? PathInput.display(url) + "/" : nil
                ) { [weak self] in self?.go(to: url) })
                seen.insert(url.standardizedFileURL.path)
            }
            for child in PathInput.completions(typed, relativeTo: base) where !seen.contains(child.standardizedFileURL.path) {
                seen.insert(child.standardizedFileURL.path)
                result.append(QuickPickerEntry(title: child.lastPathComponent, subtitle: PathInput.display(child),
                                               trailing: "⇥", completion: PathInput.display(child) + "/") { [weak self] in self?.go(to: child) })
            }
        }

        let ranked = FuzzyMatch.rank(recents, query: typed, title: { $0.lastPathComponent }, context: { PathInput.display($0) })
        for url in ranked where !seen.contains(url.standardizedFileURL.path) {
            result.append(QuickPickerEntry(title: url.lastPathComponent, subtitle: PathInput.display(url),
                                           trailing: "", completion: PathInput.display(url) + "/") { [weak self] in self?.go(to: url) })
        }
        return result
    }

    private func go(to url: URL) {
        guard let state = appState ?? AppStateRegistry.activeState else { return }
        let pane = state.activePane
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            // A symlinked folder must be resolved first (see CLAUDE.md, ENOTDIR).
            pane.navigate(to: url.resolvingSymlinksInPath())
        } else {
            pane.navigate(to: url.deletingLastPathComponent().resolvingSymlinksInPath())
            if let item = pane.items.first(where: { $0.name == url.lastPathComponent }) {
                pane.selection = [item.id]
            }
        }
        state.focusActivePane()
    }
}
