import AppKit
import SwiftUI

/// One column of Columns mode as a native `NSTableView` (a single column: icon + name +
/// chevron for folders). Same reason as for List and Icons: in SwiftUI every row of every
/// column was re-evaluated on each selection step (measured ~200 rebuilds per step),
/// which made navigation feel like jelly. The native table does
/// selection/↑↓/scrolling/range/rubber-band itself, while the SwiftUI layer only lays the
/// columns out horizontally (preview/resize/auto-scroll stay in SwiftUI — they work with
/// column frames, not rows).
///
/// A column's role is set by `isActive` (the last one = currentURL): the active one is
/// selectable, with selection/rename/keyboard; a parent/preview one is not selectable — a
/// row click goes to `onRowClick` (navigation), no keyboard.
struct ColumnTableView: NSViewRepresentable {
    let items: [FileItem]
    let isActive: Bool
    let selectedIDs: Set<FileItem.ID>   // highlight (the active column passes model.selection)
    let zoomLevel: CGFloat
    let isCut: (URL) -> Bool
    let cutURLs: Set<URL>
    /// Theme-change counter — the same "the view changed" signal as
    /// zoom/cutURLs (see ThemeStore.generation).
    let themeGeneration: Int

    /// A row click (both roles). isOnName/clickCount/modifiers are for
    /// click-to-rename and double-click; the interpretation (select/enter/navigate)
    /// is up to the caller in handleColumnClick.
    let onRowClick: (FileItem, _ isOnName: Bool, _ clickCount: Int, _ wasSoleSelectedBefore: Bool, _ modifiers: NSEvent.ModifierFlags) -> Void
    let onEmptyClick: () -> Void
    /// Active column only: native selection change (↑↓/shift/cmd/rubber-band) → model.
    let onSelectionChanged: (Set<FileItem.ID>) -> Void
    /// Active column only: →/←/Return/Tab etc. — true if handled.
    let onKeyCommand: (NSEvent) -> Bool
    /// Esc in columns: close the filter/search. true — the key was handled.
    let onEscape: () -> Bool
    let buildContextMenu: ([FileItem]) -> NSMenu
    let onDrop: ([URL], URL) -> Bool
    /// This column's directory — the default drop destination (when not over a
    /// folder row).
    let columnURL: URL
    let editRequestID: FileItem.ID?
    let onEditRequestHandled: () -> Void
    let onRenameCommit: (FileItem, String) -> Void
    let focusRequestTrigger: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ColumnNSTableView()
        table.coordinator = context.coordinator
        table.headerView = nil
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = isActive ? .regular : .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.intercellSpacing = NSSize(width: 0, height: 0)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay        // the vertical scroller doesn't take width from the content
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none  // the column doesn't scroll/bounce sideways
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }

        table.selectionHighlightStyle = isActive ? .regular : .none

        if coordinator.displayedItems != items {
            coordinator.displayedItems = items
            table.reloadData()
        } else {
            let appearanceChanged = zoomLevel != coordinator.lastZoom
                || cutURLs != coordinator.lastCutURLs
                || themeGeneration != coordinator.lastThemeGeneration
            if appearanceChanged {
                table.enumerateAvailableRowViews { rowView, row in
                    // The selection highlight is drawn by the row itself (ThemedTableRowView)
                    // — on a theme change it has to be redrawn separately from the cell
                    // contents.
                    rowView.needsDisplay = true
                    if let cell = rowView.view(atColumn: 0) as? ColumnCellView, coordinator.displayedItems.indices.contains(row) {
                        cell.configure(with: coordinator.displayedItems[row], zoom: zoomLevel, isCut: isCut(coordinator.displayedItems[row].url))
                    }
                }
            }
        }
        table.rowHeight = max(18, 16 * zoomLevel + 8)
        coordinator.lastZoom = zoomLevel
        coordinator.lastCutURLs = cutURLs
        coordinator.lastThemeGeneration = themeGeneration

        // Selection (active column only): model → native.
        if isActive {
            let desired = IndexSet(items.enumerated().compactMap { i, it in selectedIDs.contains(it.id) ? i : nil })
            if table.selectedRowIndexes != desired {
                coordinator.isSyncingSelection = true
                table.selectRowIndexes(desired, byExtendingSelection: false)
                coordinator.isSyncingSelection = false
            }
        } else if !table.selectedRowIndexes.isEmpty {
            table.deselectAll(nil)
        }

        if coordinator.lastFocusTrigger != focusRequestTrigger {
            coordinator.lastFocusTrigger = focusRequestTrigger
            if isActive { DispatchQueue.main.async { table.window?.makeFirstResponder(table) } }
        }

        if let editRequestID, editRequestID != coordinator.lastHandledEditRequestID {
            coordinator.lastHandledEditRequestID = editRequestID
            if let row = items.firstIndex(where: { $0.id == editRequestID }) {
                table.beginEditingName(atRow: row)
            }
            DispatchQueue.main.async { onEditRequestHandled() }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

        // MARK: Type-to-select

        /// NSTableView can jump to typed letters by itself, but only if the delegate
        /// says which string to match against: for view-based tables AppKit can't
        /// extract the text from a cell, and without this method typing simply does
        /// nothing. Return the file name — and get Finder's behavior for free.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            displayedItems.indices.contains(row) ? displayedItems[row].name : nil
        }

        var parent: ColumnTableView
        weak var table: ColumnNSTableView?
        var displayedItems: [FileItem] = []
        var isSyncingSelection = false
        var lastZoom: CGFloat = -1
        var lastCutURLs: Set<URL> = []
        /// -1 (not 0) — so cells get themed colors on the very first update.
        var lastThemeGeneration = -1
        var lastFocusTrigger = 0
        var lastHandledEditRequestID: FileItem.ID?
        var pendingRenameWorkItem: DispatchWorkItem?
        private var isCancellingEdit = false

        init(_ parent: ColumnTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayedItems.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("ColumnCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ColumnCellView) ?? {
                let c = ColumnCellView(); c.identifier = id; return c
            }()
            cell.configure(with: displayedItems[row], zoom: parent.zoomLevel, isCut: parent.isCut(displayedItems[row].url))
            cell.textField?.delegate = self
            return cell
        }

        /// A custom row only for drawing the selection highlight in the theme color (see
        /// ThemedTableRowView).
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("ThemedRow")
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? ThemedTableRowView { return reused }
            let rowView = ThemedTableRowView()
            rowView.identifier = id
            return rowView
        }

        // Active column: native selection change → model.
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard parent.isActive, !isSyncingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { displayedItems.indices.contains($0) ? displayedItems[$0].id : nil })
            parent.onSelectionChanged(ids)
        }

        // --- drag ---
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            displayedItems.indices.contains(row) ? (displayedItems[row].url as NSURL) : nil
        }

        // --- drop ---
        /// The drop target is determined by hit-testing the point rather than by
        /// AppKit's proposed .on/.above: over a row the proposal easily comes as
        /// .above, and a drop "into the folder" fell into the "not over a folder"
        /// branch — the file was moved into the column's own directory, i.e. usually
        /// where it already was, and the move silently didn't happen. List and Icons do
        /// the same.
        private func folderRow(under info: NSDraggingInfo, in tableView: NSTableView) -> Int? {
            let point = tableView.convert(info.draggingLocation, from: nil)
            let row = tableView.row(at: point)
            guard displayedItems.indices.contains(row), displayedItems[row].isNavigableFolder else { return nil }
            let dragged = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return dragged.contains(displayedItems[row].url) ? nil : row
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            if let folderRow = folderRow(under: info, in: tableView) {
                tableView.setDropRow(folderRow, dropOperation: .on)
                return .move
            }
            tableView.setDropRow(-1, dropOperation: .on)  // not over a folder → into the column's directory
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
            let destination = folderRow(under: info, in: tableView).map { displayedItems[$0].url } ?? parent.columnURL
            return parent.onDrop(urls, destination)
        }

        // --- context menu ---
        func contextMenu(atRow row: Int) -> NSMenu {
            cancelPendingRename()
            // Active column — a menu for the whole selection (multi-select); parent —
            // for the single item under the cursor; empty space — the empty-area menu.
            if parent.isActive, let table {
                let items = table.selectedRowIndexes.compactMap { displayedItems.indices.contains($0) ? displayedItems[$0] : nil }
                return parent.buildContextMenu(items)
            }
            if displayedItems.indices.contains(row) { return parent.buildContextMenu([displayedItems[row]]) }
            return parent.buildContextMenu([])
        }

        func cancelPendingRename() { pendingRenameWorkItem?.cancel(); pendingRenameWorkItem = nil }

        // --- inline rename ---
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField, let table else { return false }
            isCancellingEdit = true
            let row = table.row(for: field)
            if displayedItems.indices.contains(row) { field.stringValue = displayedItems[row].name }
            table.window?.makeFirstResponder(table)
            isCancellingEdit = false
            return true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            field.isEditable = false
            guard !isCancellingEdit, let table, case let row = table.row(for: field), displayedItems.indices.contains(row) else { return }
            let item = displayedItems[row]
            let newName = field.stringValue
            // See the comment in FileTableView: the name check is shared with
            // the model.
            guard FileOperationService.isValidItemName(newName), newName != item.name else {
                field.stringValue = item.name
                return
            }
            parent.onRenameCommit(item, newName)
        }
    }
}

/// A single-column NSTableView: mouseDown is handled by role (active — native selection +
/// post-processing of double-click/click-to-rename; otherwise — navigation via
/// onRowClick), keyDown (active only), context menu.
final class ColumnNSTableView: NSTableView {
    weak var coordinator: ColumnTableView.Coordinator?

    /// Esc dismisses the filter or search bar even when focus stayed in the list.
    ///
    /// It's cancelOperation specifically, not a keyCode check in keyDown: our keyDown
    /// forwards unrecognized keys to super, which turns Esc into cancelOperation via
    /// interpretKeyEvents. Inline rename isn't affected — while a name is being edited
    /// the text field holds first responder and gets the Esc itself.
    override func cancelOperation(_ sender: Any?) {
        if coordinator?.parent.onEscape() == true { return }
        super.cancelOperation(sender)
    }


    /// Stretch the table to the clip view's full height when there are fewer rows —
    /// otherwise clicks on the empty space BELOW the rows didn't reach the table (no
    /// mouseDown), and the empty area didn't clear the selection.
    override func layout() {
        super.layout()
        if let clip = enclosingScrollView?.contentView, frame.height < clip.bounds.height {
            setFrameSize(NSSize(width: frame.width, height: clip.bounds.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        coordinator.cancelPendingRename()

        guard row >= 0, coordinator.displayedItems.indices.contains(row) else {
            // Empty space.
            coordinator.parent.onEmptyClick()
            if coordinator.parent.isActive { super.mouseDown(with: event) }  // rubber-band/deselect
            return
        }
        let item = coordinator.displayedItems[row]
        let isOnName = hitTestName(at: point, row: row)
        let wasSole = selectedRowIndexes == [row]   // snapshot BEFORE super (for click-to-rename)

        if coordinator.parent.isActive {
            // Native selection (↑↓ are already native; shift/cmd/rubber-band too) +
            // post-processing.
            super.mouseDown(with: event)
            coordinator.parent.onRowClick(item, isOnName, event.clickCount, wasSole, event.modifierFlags)
        } else {
            // Parent/preview column: not selectable, click = navigation.
            coordinator.parent.onRowClick(item, isOnName, event.clickCount, false, event.modifierFlags)
        }
    }

    private func hitTestName(at point: NSPoint, row: Int) -> Bool {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnCellView, let label = cell.textField else { return false }
        return label.convert(label.bounds, to: self).contains(point)
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator, coordinator.parent.isActive else { super.keyDown(with: event); return }
        // Context menu from the keyboard (⌃↩) — here rather than in onKeyCommand: the row
        // geometry is needed to pop the menu up at the selected item.
        if ShortcutStore.shared.command(for: event) == .showContextMenu {
            presentContextMenuFromKeyboard()
            return
        }
        if coordinator.parent.onKeyCommand(event) { return }
        super.keyDown(with: event)  // ↑↓ etc. — native
    }

    /// Context menu from the keyboard (⌃↩) — for the active column's current
    /// selection, popped up at the first selected row.
    private func presentContextMenuFromKeyboard() {
        guard let coordinator else { return }
        coordinator.cancelPendingRename()
        let items = selectedRowIndexes.compactMap { coordinator.displayedItems.indices.contains($0) ? coordinator.displayedItems[$0] : nil }
        let menu = coordinator.parent.buildContextMenu(items)
        let anchor: NSPoint
        if let row = selectedRowIndexes.first, row >= 0 {
            let r = rect(ofRow: row)
            anchor = NSPoint(x: r.minX + 16, y: r.maxY)
        } else {
            anchor = NSPoint(x: bounds.minX + 16, y: (enclosingScrollView?.documentVisibleRect.minY ?? 0) + 20)
        }
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        // Right-click on an unselected row in the active column selects it (as in
        // Finder).
        if coordinator.parent.isActive, row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator.contextMenu(atRow: row)
    }

    /// Inline rename of a row (click-to-rename / from the menu).
    func beginEditingName(atRow row: Int) {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCellView, let field = cell.textField else { return }
        field.isEditable = true
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = field.stringValue as NSString
            let ext = name.pathExtension
            if !ext.isEmpty, name.length - ext.count - 1 > 0 {
                editor.selectedRange = NSRange(location: 0, length: name.length - ext.count - 1)
            }
        }
    }
}

/// A column cell: icon + name + chevron (for folders), symlink badge, dimming of cut items.
final class ColumnCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var badge: NSImageView?
    private var iconSize: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        // See the comment in FileIconsView: an NSImageView accepts file drags itself
        // and would intercept them over the icon, keeping the event from the table.
        icon.unregisterDraggedTypes()
        chevron.unregisterDraggedTypes()
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: FileItem, zoom: CGFloat, isCut: Bool) {
        icon.image = item.icon
        let size = 16 * zoom
        NSLayoutConstraint.deactivate(iconSize)
        iconSize = [icon.widthAnchor.constraint(equalToConstant: size), icon.heightAnchor.constraint(equalToConstant: size)]
        NSLayoutConstraint.activate(iconSize)
        label.stringValue = item.name
        label.font = .systemFont(ofSize: 13 * zoom)
        let palette = Theme.current
        label.textColor = item.isHidden ? palette.secondaryLabel : palette.label
        label.toolTip = item.name
        chevron.contentTintColor = palette.secondaryLabel
        chevron.isHidden = !item.isNavigableFolder
        alphaValue = isCut ? 0.5 : 1
        updateBadge(isSymlink: item.isSymbolicLink, size: max(7, 8 * zoom))
    }

    private func updateBadge(isSymlink: Bool, size: CGFloat) {
        if !isSymlink { badge?.isHidden = true; return }
        let b: NSImageView
        if let existing = badge { b = existing } else {
            b = NSImageView()
            b.unregisterDraggedTypes()   // see the comment above
            b.wantsLayer = true
            b.translatesAutoresizingMaskIntoConstraints = false
            let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .bold)
            b.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            b.contentTintColor = .white
            b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            addSubview(b)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: size),
                b.heightAnchor.constraint(equalToConstant: size),
                b.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -1),
                b.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            ])
            b.layer?.cornerRadius = size / 2
            badge = b
        }
        b.isHidden = false
    }
}
