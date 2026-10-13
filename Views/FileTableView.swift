import AppKit
import SwiftUI

/// Table columns — a type shared by FileTableView, its Coordinator and
/// FileTableCellView.
enum FileTableColumn: String, CaseIterable {
    // Order = the order of columns in the table and of items in "Show View Options"
    // (Name always).
    case name, modified, created, lastOpened, dateAdded, size, kind, tags

    /// Columns that can be hidden in "Show View Options" (all but Name).
    static var optional: [FileTableColumn] { allCases.filter { $0 != .name } }

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .lastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .tags: return "Tags"
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 180
        case .size: return 70
        case .kind: return 90
        case .modified, .created, .lastOpened, .dateAdded: return 120
        case .tags: return 80
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: return 320
        case .size: return 90
        case .kind: return 110
        case .modified, .created, .lastOpened, .dateAdded: return 140
        case .tags: return 120
        }
    }

    /// As in the old SwiftUI Table: name/kind/tags are alphabetical by default,
    /// size/dates largest/most recent first (see setSort in PaneView.swift).
    var defaultAscending: Bool {
        switch self {
        case .size, .modified, .created, .lastOpened, .dateAdded: return false
        case .name, .kind, .tags: return true
        }
    }
}

/// An AppKit replacement for SwiftUI's Table in List mode.
///
/// Why it exists: dragging a file/folder from ANY point of an already-selected row
/// (as in Finder) is required — a critical capability for a file manager. SwiftUI
/// Table + .onDrag on row content won't do it: .onDrag installs its own recognizer on
/// a specific SwiftUI subview, which competes with Table's native click-selection for
/// mouseDown — confirmed empirically that the regression reproduces on ANY cell
/// (Name/Size/Kind/Modified), not just one column (see the history in PaneView.swift
/// and the comment on fileTable).
///
/// NSTableView supports drag-from-any-point-of-a-selected-row natively via
/// tableView(_:pasteboardWriterForRow:) — the whole mouseDown-to-drag-threshold
/// transition happens inside NSTableView's own AppKit-owned event-tracking loop, with
/// no SwiftUI gesture on top, so there's fundamentally nothing to compete with. It
/// also gives a multi-file drag of the whole current selection "with one finger" —
/// something even the old SwiftUI implementation didn't have (its onDrag dragged only
/// one item).
struct FileTableView: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<FileItem.ID>
    @Binding var sortOrder: [KeyPathComparator<FileItem>]
    /// Which columns to show (Name is always included) — controlled from "Show View
    /// Options". Hidden via NSTableColumn.isHidden rather than add/remove: that keeps the
    /// width that was set and doesn't jolt the table by reinstalling columns.
    let visibleColumns: Set<FileTableColumn>
    let zoomLevel: CGFloat
    let currentDirectoryURL: URL
    let isCut: (URL) -> Bool
    /// The set of URLs currently actually "cut" — only for a cheap "did the cells' look
    /// change" comparison in updateNSView. Without it, every visible cell was
    /// reconfigured on EVERY selection change (@Published selection → re-render), which
    /// made held-arrow navigation feel like jelly. Rendering itself still goes through
    /// isCut.
    let cutURLs: Set<URL>
    /// Theme-change counter (ThemeStore.generation) — one more "affects the look"
    /// signal alongside zoom/cutURLs: on a change, visible cells are reconfigured and
    /// the table repainted, without comparing colors.
    let themeGeneration: Int

    /// Any click on the table (including empty space) activates the pane/closes path
    /// editing. Unlike the old SwiftUI Table, this isn't a "known limitation" here:
    /// we own mouseDown ourselves, including clicks outside rows.
    let onActivate: () -> Void
    let onOpen: (FileItem) -> Void
    /// Called when inline name editing finished successfully (Enter or a click
    /// outside, not Escape) — newName is what actually remained in the text field.
    let onRenameCommit: (FileItem, String) -> Void
    let onGoUp: () -> Void
    /// Tab — switch the active pane, only when appropriate (e.g. both panes are
    /// visible) — the caller decides, see switchActivePaneIfPossible() in
    /// PaneView.swift.
    let onSwitchPane: () -> Void
    /// Esc in the list: close the filter/search. true — the key was handled.
    let onEscape: () -> Bool
    /// ← / → in List mode — focus the left (toRight=false) or right (toRight=true) pane.
    /// A no-op if the second pane is hidden or the target one is already active (the
    /// caller decides). List only — the other modes use the arrows to navigate items.
    let onFocusPane: (_ toRight: Bool) -> Void
    let buildContextMenu: ([FileItem]) -> NSMenu
    let onDrop: ([URL], URL) -> Bool
    /// Grows when first responder has to be forced back into the table from outside —
    /// currently the only reason: closing the search bar removes the TextField from the
    /// hierarchy, but first responder doesn't move anywhere by itself (as
    /// .focused($isTableFocused) on the SwiftUI Table used to handle — but a plain
    /// .focused() doesn't bridge to an arbitrary NSViewRepresentable, so the reclaim is
    /// explicit here).
    let focusRequestTrigger: Int
    /// A bridge to "start inline rename for this item" from OUTSIDE the AppKit world —
    /// its only consumer is the "Rename…" context-menu item in PaneView.swift (a click
    /// on a name right in the table is handled inside FileNSTableView directly; this
    /// bridge isn't needed). onEditRequestHandled is called right after editing has
    /// started — PaneView must reset editRequestID to nil, otherwise a repeated
    /// request for THE SAME item (e.g. Rename… again after Cancel) won't be noticed.
    let editRequestID: FileItem.ID?
    let onEditRequestHandled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = FileNSTableView()
        tableView.coordinator = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: false)
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.target = context.coordinator
        tableView.focusRingType = .none
        tableView.style = .inset

        // The header is drawn by us (see Theme.swift): the system NSTableHeaderCell
        // doesn't obey the palette and stays noticeably lighter than the pane in the dark
        // appearance.
        tableView.headerView = ThemedTableHeaderView()

        for column in FileTableColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            // headerCell before title: title is the cell's stringValue, and swapping the
            // cell afterwards would lose the title.
            tableColumn.headerCell = ThemedTableHeaderCell(textCell: column.title)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.idealWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.defaultAscending)
            tableView.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // Remember the table's default background so the "System" theme restores exactly
        // that rather than a guessed semantic color (see themedBackground in Theme.swift).
        context.coordinator.defaultBackgroundColor = tableView.backgroundColor
        context.coordinator.tableView = tableView
        context.coordinator.applySortDescriptors(from: sortOrder)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let tableView = coordinator.tableView else { return }

        // Column visibility (Name is always visible) — synced from "Show View Options".
        for tableColumn in tableView.tableColumns {
            guard let column = FileTableColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            let shouldHide = column != .name && !visibleColumns.contains(column)
            if tableColumn.isHidden != shouldHide { tableColumn.isHidden = shouldHide }
        }

        // Reconfiguring visible cells is needed ONLY when something affecting their look
        // changed: zoom or the set of cut items. A selection change isn't one of those
        // (NSTableView draws the highlight itself), so it's let through — otherwise arrow
        // navigation would be bogged down by reconfiguring all visible cells on every
        // step ("jelly").
        let themeChanged = themeGeneration != coordinator.lastAppliedThemeGeneration
        if themeChanged {
            coordinator.lastAppliedThemeGeneration = themeGeneration
            let palette = Theme.current
            tableView.backgroundColor = palette.paneBackground ?? coordinator.defaultBackgroundColor
            // The selection highlight is drawn by the rows (ThemedTableRowView) — they have
            // to be redrawn separately: reconfiguring the cells below only touches the
            // rows' contents.
            tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            // Header text color is a cell property (the background is drawn by
            // ThemedTableHeaderCell); .headerTextColor is the native default the System
            // theme returns to.
            for tableColumn in tableView.tableColumns {
                (tableColumn.headerCell as? NSTableHeaderCell)?.textColor = palette.isCustom ? palette.label : .headerTextColor
            }
            tableView.headerView?.needsDisplay = true
        }
        let appearanceChanged = themeChanged || zoomLevel != coordinator.lastAppliedZoom || cutURLs != coordinator.lastAppliedCutURLs
        if coordinator.displayedItems != items {
            coordinator.displayedItems = items
            tableView.reloadData()
        } else if appearanceChanged {
            tableView.enumerateAvailableRowViews { _, row in
                for columnIndex in tableView.tableColumns.indices {
                    if let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? FileTableCellView,
                       coordinator.displayedItems.indices.contains(row) {
                        cell.configure(item: coordinator.displayedItems[row], column: cell.column, zoomLevel: zoomLevel, isCut: isCut(coordinator.displayedItems[row].url))
                    }
                }
            }
        }
        coordinator.lastAppliedZoom = zoomLevel
        coordinator.lastAppliedCutURLs = cutURLs

        tableView.rowHeight = max(18, 16 * zoomLevel + 4)
        coordinator.applySortDescriptors(from: sortOrder)

        if coordinator.lastFocusRequestTrigger != focusRequestTrigger {
            coordinator.lastFocusRequestTrigger = focusRequestTrigger
            DispatchQueue.main.async { tableView.window?.makeFirstResponder(tableView) }
        }

        let desiredRows = IndexSet(items.enumerated().compactMap { index, item in selection.contains(item.id) ? index : nil })
        if tableView.selectedRowIndexes != desiredRows {
            coordinator.isSyncingSelectionFromBinding = true
            tableView.selectRowIndexes(desiredRows, byExtendingSelection: false)
            coordinator.isSyncingSelectionFromBinding = false
        }

        if let editRequestID {
            if editRequestID != coordinator.lastHandledEditRequestID {
                coordinator.lastHandledEditRequestID = editRequestID
                if let row = items.firstIndex(where: { $0.id == editRequestID }) {
                    tableView.beginEditingName(atRow: row)
                }
                DispatchQueue.main.async { onEditRequestHandled() }
            }
        } else {
            coordinator.lastHandledEditRequestID = nil
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: FileTableView
        weak var tableView: FileNSTableView?
        var displayedItems: [FileItem] = []
        var isSyncingSelectionFromBinding = false
        var lastFocusRequestTrigger = 0
        /// The last applied "affects the cells' look" parameters — so visible cells
        /// are reconfigured only when they actually changed (zoom / the set of cut
        /// items), not on every selection change. The -1 sentinel for zoom
        /// guarantees a reconfigure on the very first non-empty update.
        var lastAppliedZoom: CGFloat = -1
        var lastAppliedCutURLs: Set<URL> = []
        /// -1 (not 0) — so the background/cells get painted on the very first
        /// update.
        var lastAppliedThemeGeneration = -1
        /// The table background "as it was before themes" — the System theme
        /// returns to it.
        var defaultBackgroundColor: NSColor = .controlBackgroundColor
        var lastHandledEditRequestID: FileItem.ID?
        private var pendingRenameWorkItem: DispatchWorkItem?
        private var dragSessionStarted = false
        /// Whether a file drag is allowed for the current mouseDown. As in Finder: file(s)
        /// can only be dragged by grabbing an ALREADY-selected row; pressing+dragging an
        /// unselected row should start a drag-SELECTION rather than move a file. Set in
        /// mouseDown (from a snapshot of the selection BEFORE the click), read in
        /// pasteboardWriterForRow.
        var dragAllowedFromMouseDown = false
        /// Set in menu(for:) and suppresses rename scheduling in handlePostMouseDown.
        /// Needed because for a click that shows the context menu, menu(for:) is called
        /// INSIDE super.mouseDown — i.e. BEFORE handlePostMouseDown runs, so a
        /// cancel/modifier check there isn't enough. Reset at the start of every
        /// mouseDown, so a regular left click schedules a rename as before.
        var suppressRenameScheduling = false
        /// true between the start and end of a forced editing cancel (Escape) —
        /// controlTextDidEndEditing checks this flag so it doesn't take the cancel for
        /// a normal end of editing and send onRenameCommit with text we ourselves just
        /// rolled back to the original name.
        private var isCancellingEdit = false

        init(_ parent: FileTableView) {
            self.parent = parent
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            // nil → the row isn't a drag source, and NSTableView interprets the drag as
            // selection (rubber-band over rows) rather than a file drag. A drag is
            // allowed only when the gesture started on an already-selected row (see
            // dragAllowedFromMouseDown) — otherwise dragging an unselected row =
            // selecting.
            guard dragAllowedFromMouseDown, displayedItems.indices.contains(row) else { return nil }
            return displayedItems[row].url as NSURL
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragSessionStarted = true
        }

        /// The folder under the drag cursor — computed by our own hit-test of the point,
        /// NOT from proposedRow/.on. AppKit's proposal couldn't be relied on here: over
        /// a row it easily comes as .above (insert between rows), and then a drop "into
        /// the folder" went down the "not over a folder" branch → the target became the
        /// current directory, i.e. the file was moved to where it already was — the move
        /// silently didn't happen. Icons reached exactly the same conclusion (see the
        /// comment at validateDrop in FileIconsView): the drop target is determined by
        /// the point, not the hint.
        ///
        /// The folder being dragged itself doesn't count as a target — otherwise
        /// dropping a folder on itself would look like nesting it inside itself.
        private func folderRow(under info: NSDraggingInfo, in tableView: NSTableView) -> Int? {
            let point = tableView.convert(info.draggingLocation, from: nil)
            let row = tableView.row(at: point)
            guard displayedItems.indices.contains(row), displayedItems[row].isNavigableFolder else { return nil }
            let dragged = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            return dragged.contains(displayedItems[row].url) ? nil : row
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
            if let folderRow = folderRow(under: info, in: tableView) {
                // An explicit setDropRow(.on) also draws the target row's
                // highlight.
                tableView.setDropRow(folderRow, dropOperation: .on)
                return .move
            }
            // Between rows or on empty space — the current directory is the
            // target, as .onDrop on the whole SwiftUI Table used to do.
            tableView.setDropRow(-1, dropOperation: .on)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
                return false
            }
            // The same hit-test as in validateDrop rather than the row passed in:
            // they have to agree, otherwise one row would be highlighted while the
            // file went into another.
            let folderRow = folderRow(under: info, in: tableView)
            let destination = folderRow.map { displayedItems[$0].url } ?? parent.currentDirectoryURL
            return parent.onDrop(urls, destination)
        }


        // MARK: Type-to-select

        /// NSTableView can jump to typed letters by itself, but only if the delegate
        /// says which string to match against: for view-based tables AppKit can't
        /// extract the text from a cell, and without this method typing simply does
        /// nothing. Return the file name — and get Finder's behavior for free.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            displayedItems.indices.contains(row) ? displayedItems[row].name : nil
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, let column = FileTableColumn(rawValue: identifier.rawValue),
                  displayedItems.indices.contains(row) else { return nil }
            let item = displayedItems[row]
            let cell: FileTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? FileTableCellView {
                cell = reused
            } else {
                cell = FileTableCellView(column: column)
                cell.identifier = identifier
            }
            cell.configure(item: item, column: column, zoomLevel: parent.zoomLevel, isCut: parent.isCut(item.url))
            if column == .name {
                // The name field is NOT editable by default. Confirmed by diagnostics
                // (2026-07-19): with isEditable=true the native NSTableView enters editing
                // by itself on a click (including a right-click) in an already-selected
                // row — that was the cause of "right-clicking a selected item starts a
                // rename", bypassing all our checks (beginEditingName wasn't called at
                // all). Editing is enabled selectively, only in beginEditingName; here —
                // just the delegate.
                cell.textField?.isEditable = false
                cell.textField?.delegate = self
            }
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

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelectionFromBinding, let tableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { displayedItems.indices.contains($0) ? displayedItems[$0].id : nil })
            if parent.selection != ids {
                parent.selection = ids
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let column = FileTableColumn(rawValue: descriptor.key ?? "") else { return }
            let order: SortOrder = descriptor.ascending ? .forward : .reverse
            switch column {
            case .name: parent.sortOrder = [KeyPathComparator(\FileItem.name, order: order)]
            case .size: parent.sortOrder = [KeyPathComparator(\FileItem.size, order: order)]
            case .kind: parent.sortOrder = [KeyPathComparator(\FileItem.kind, order: order)]
            case .modified: parent.sortOrder = [KeyPathComparator(\FileItem.modified, order: order)]
            case .created: parent.sortOrder = [KeyPathComparator(\FileItem.created, order: order)]
            case .lastOpened: parent.sortOrder = [KeyPathComparator(\FileItem.lastOpened, order: order)]
            case .dateAdded: parent.sortOrder = [KeyPathComparator(\FileItem.dateAdded, order: order)]
            case .tags: parent.sortOrder = [KeyPathComparator(\FileItem.tagsDisplay, order: order)]
            }
        }

        func applySortDescriptors(from sortOrder: [KeyPathComparator<FileItem>]) {
            guard let tableView, let first = sortOrder.first else { return }
            let column: FileTableColumn
            if first.keyPath == \FileItem.name { column = .name }
            else if first.keyPath == \FileItem.size { column = .size }
            else if first.keyPath == \FileItem.kind { column = .kind }
            else if first.keyPath == \FileItem.modified { column = .modified }
            else if first.keyPath == \FileItem.created { column = .created }
            else if first.keyPath == \FileItem.lastOpened { column = .lastOpened }
            else if first.keyPath == \FileItem.dateAdded { column = .dateAdded }
            else if first.keyPath == \FileItem.tagsDisplay { column = .tags }
            else { return }
            let descriptor = NSSortDescriptor(key: column.rawValue, ascending: first.order == .forward)
            if tableView.sortDescriptors.first != descriptor {
                tableView.sortDescriptors = [descriptor]
            }
        }

        // MARK: Clicks

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            pendingRenameWorkItem?.cancel()
            let row = tableView.clickedRow
            guard displayedItems.indices.contains(row) else { return }
            parent.onOpen(displayedItems[row])
        }

        func prepareForMouseDown() {
            dragSessionStarted = false
        }

        /// Called from FileNSTableView.mouseDown AFTER super.mouseDown.
        /// row/wasSoleSelectedBeforeClick/hitNameLabel are a snapshot from BEFORE the
        /// click, taken in FileNSTableView before calling super.
        ///
        /// Confirmed 2026-07-16: super.mouseDown does NOT block for the whole drag cycle
        /// — it returns right after handling the selection, and the actual turning of
        /// the click into a drag happens later, in separate mouseDragged events, after
        /// handlePostMouseDown has already run. So checking dragSessionStarted here is
        /// useless (dragging an already-selected file by its name always landed in the
        /// rename-scheduling branch) — instead the dragSessionStarted check itself is
        /// deferred until the timer below fires: if the user drags the mouse between the
        /// click and that moment, the drag has time to start and set the flag before the
        /// timer fires.
        func handlePostMouseDown(row: Int, wasSoleSelectedBeforeClick: Bool, hitNameLabel: Bool, clickCount: Int, modifierFlags: NSEvent.ModifierFlags) {
            parent.onActivate()
            guard clickCount == 1,
                  // A click that showed the context menu (right/⌃-click) doesn't rename:
                  // menu(for:) already set suppressRenameScheduling INSIDE
                  // super.mouseDown.
                  !suppressRenameScheduling,
                  !modifierFlags.contains(.command), !modifierFlags.contains(.shift),
                  !modifierFlags.contains(.control),
                  wasSoleSelectedBeforeClick, hitNameLabel,
                  displayedItems.indices.contains(row),
                  let tableView, tableView.selectedRowIndexes.count == 1, tableView.selectedRowIndexes.contains(row)
            else { return }
            pendingRenameWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.dragSessionStarted else { return }
                self.tableView?.beginEditingName(atRow: row)
            }
            pendingRenameWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
        }

        func cancelPendingRename() {
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
        }

        // MARK: NSTextFieldDelegate (inline name editing)

        /// Escape doesn't end field editing by itself (unlike Enter) — it's
        /// intercepted explicitly: roll the text back to the original name and
        /// forcibly take first responder away from the field, which ends editing, but
        /// with isCancellingEdit=true so controlTextDidEndEditing below doesn't take
        /// it for a normal commit with a "new" name (especially since by then it
        /// matches the original again).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let textField = control as? NSTextField, let tableView else { return false }
            let row = tableView.row(for: textField)
            if displayedItems.indices.contains(row) {
                textField.stringValue = displayedItems[row].name
            }
            isCancellingEdit = true
            tableView.window?.makeFirstResponder(tableView)
            isCancellingEdit = false
            return true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Return the field to the non-editable state (it was enabled only for
            // the rename) — on any ending: commit, click outside or Escape cancel.
            (obj.object as? NSTextField)?.isEditable = false
            guard !isCancellingEdit, let textField = obj.object as? NSTextField, let tableView else { return }
            let row = tableView.row(for: textField)
            guard displayedItems.indices.contains(row) else { return }
            let item = displayedItems[row]
            let newName = textField.stringValue
            // The same check as in the model (FileOperationService.isValidItemName): an
            // empty name, spaces only, "." / ".." and names with a slash aren't
            // accepted, and the previous name is put back in the field. Only .isEmpty
            // used to be checked, so a name of only spaces reached the model and was
            // rejected there — while the cell kept the typed space, and the file looked
            // nameless until a reload.
            guard FileOperationService.isValidItemName(newName), newName != item.name else {
                textField.stringValue = item.name
                return
            }
            parent.onRenameCommit(item, newName)
        }
    }
}

/// An NSTableView subclass: the only place that genuinely needs access to raw
/// mouseDown/keyDown/menu(for:) — the Coordinator receives already-parsed events.
final class FileNSTableView: NSTableView {
    weak var coordinator: FileTableView.Coordinator?

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


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let wasSoleSelectedBefore = row >= 0 && selectedRowIndexes.count == 1 && selectedRowIndexes.contains(row)
        let hitNameLabel = row >= 0 && hitTestNameLabel(at: point, row: row)
        let clickCount = event.clickCount
        let modifiers = event.modifierFlags
        // Reset before super.mouseDown: if this click shows the context menu, menu(for:)
        // sets the flag back INSIDE super.mouseDown, and handlePostMouseDown will see it.
        coordinator?.suppressRenameScheduling = false
        // ANY row can be dragged, not only an already-selected one. Dragging used to be
        // allowed only on a selected row (dragging an unselected one counted as
        // drag-selection), so the familiar gesture "press on a file and drag it into a
        // folder" didn't start a drag at all in List: pasteboardWriterForRow returned nil,
        // no session started, and dragging simply appeared not to work. Icons and Columns
        // had no such restriction — the discrepancy surfaced as "a file can't be dragged in
        // the list".
        //
        // This is exactly what Finder does: a gesture on an UNselected row first selects it
        // and drags it, while rubber-band selection starts from empty space, not over a
        // row. Modifiers (⌘/⇧) are left to selection: there the gesture extends the
        // selection rather than dragging.
        let plainClick = !modifiers.contains(.command) && !modifiers.contains(.shift)
        if row >= 0, plainClick, !selectedRowIndexes.contains(row) {
            // Select BEFORE super.mouseDown, because the "can it be dragged" decision is
            // read from pasteboardWriterForRow already inside its tracking loop.
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        coordinator?.dragAllowedFromMouseDown = row >= 0 && plainClick && selectedRowIndexes.contains(row)
        coordinator?.cancelPendingRename()
        coordinator?.prepareForMouseDown()
        // super.mouseDown handles the click/selection and returns right away — it does
        // NOT wait for the outcome of a possible drag (confirmed 2026-07-16: the click
        // turns into a drag later, via separate mouseDragged events, after returning
        // from here). So "was this just a click on the name of an already-selected row
        // rather than the start of a drag" is sorted out in handlePostMouseDown with a
        // deferred dragSessionStarted check (see its comment) — not right here.
        super.mouseDown(with: event)
        coordinator?.handlePostMouseDown(
            row: row, wasSoleSelectedBeforeClick: wasSoleSelectedBefore, hitNameLabel: hitNameLabel,
            clickCount: clickCount, modifierFlags: modifiers
        )
    }

    private func hitTestNameLabel(at point: NSPoint, row: Int) -> Bool {
        guard let nameColumnIndex = tableColumns.firstIndex(where: { $0.identifier.rawValue == FileTableColumn.name.rawValue }) else { return false }
        guard let cellView = view(atColumn: nameColumnIndex, row: row, makeIfNecessary: false) as? FileTableCellView,
              let textField = cellView.textField else {
            return frameOfCell(atColumn: nameColumnIndex, row: row).contains(point)
        }
        // The name area is the actual text rectangle inside the cell, not the whole
        // width of the Name column: otherwise a click on the empty "tail" of a short
        // name in a wide column would also schedule a rename.
        let textFrameInTable = cellView.convert(textField.frame, to: self)
        return textFrameInTable.contains(point)
    }

    override func keyDown(with event: NSEvent) {
        // Keys are resolved through the command registry
        // (Models/KeyboardShortcuts.swift) rather than by magic keyCodes. No command —
        // the event must be passed on.
        guard let coordinator, let command = ShortcutStore.shared.command(for: event) else {
            super.keyDown(with: event)
            return
        }
        switch command {
        case .openSelection:
            if let row = selectedRowIndexes.first, coordinator.displayedItems.indices.contains(row) {
                coordinator.parent.onOpen(coordinator.displayedItems[row])
            }
        case .goToParentDirectory:
            coordinator.parent.onGoUp()
        case .switchPane:
            coordinator.parent.onSwitchPane()
        case .showContextMenu:
            presentContextMenuFromKeyboard()
        case .navigateLeft:
            // List doesn't need horizontal navigation between items — ← / → are used to
            // switch the active pane (left / right).
            coordinator.parent.onFocusPane(false)
        case .navigateRight:
            coordinator.parent.onFocusPane(true)
        case .navigateDown, .navigateUp:
            // Explicit select+scroll instead of super (the native moveDown:/moveUp:) —
            // otherwise scrolling waits for a full SwiftUI round trip (native selection
            // changes → tableViewSelectionDidChange → parent.selection → PaneView redraw →
            // updateNSView), and with a fast held arrow it lags noticeably. ⇧-arrows don't
            // get here: the shortcut is compared with modifiers strictly, so extending the
            // selection as a range goes to super, as before.
            let delta = command == .navigateDown ? 1 : -1
            let current = selectedRowIndexes.first ?? (delta > 0 ? -1 : coordinator.displayedItems.count)
            let newRow = min(max(current + delta, 0), coordinator.displayedItems.count - 1)
            if coordinator.displayedItems.indices.contains(newRow) {
                selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                scrollRowToVisible(newRow)
            }
        default:
            // Horizontal navigation isn't used in List, and menu commands never get
            // here (NSApplication intercepts their key equivalents earlier) —
            // everything else goes to the table.
            super.keyDown(with: event)
        }
    }

    /// Context menu from the keyboard (⌃↩) — the same menu as on right-click, but
    /// at the selected row. Built from the current selection and popped up at the
    /// first selected row.
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
        // A right-click never renames: cancel an already-deferred rename AND forbid
        // handlePostMouseDown (which runs LATER than this call — see the flag) from scheduling
        // a new one for the click that shows this menu.
        coordinator.cancelPendingRename()
        coordinator.suppressRenameScheduling = true
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        // As in Finder: a right-click on an unselected row selects only it; a
        // right-click within an existing multi-selection keeps the whole selection.
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let items = selectedRowIndexes.compactMap { coordinator.displayedItems.indices.contains($0) ? coordinator.displayedItems[$0] : nil }
        return coordinator.parent.buildContextMenu(items)
    }

    /// Starts native AppKit inline editing for the name in this row — as in Finder:
    /// selects only the base name without the extension (for files; folders have no
    /// extension, so the whole name is selected), not the whole text.
    func beginEditingName(atRow row: Int) {
        guard let coordinator, coordinator.displayedItems.indices.contains(row),
              let nameColumnIndex = tableColumns.firstIndex(where: { $0.identifier.rawValue == FileTableColumn.name.rawValue })
        else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Editing is enabled selectively, only for the duration of our explicit rename
        // (by default the field isn't editable — otherwise NSTableView edits it by
        // itself on a click).
        if let cell = view(atColumn: nameColumnIndex, row: row, makeIfNecessary: true) as? FileTableCellView {
            cell.textField?.isEditable = true
        }
        editColumn(nameColumnIndex, row: row, with: nil, select: true)
        let item = coordinator.displayedItems[row]
        if !item.isNavigableFolder,
           let textField = (view(atColumn: nameColumnIndex, row: row, makeIfNecessary: false) as? FileTableCellView)?.textField,
           let fieldEditor = window?.fieldEditor(true, for: textField) {
            let name = item.name as NSString
            let ext = name.pathExtension
            if !ext.isEmpty {
                let baseLength = name.length - ext.count - 1
                if baseLength > 0 {
                    fieldEditor.selectedRange = NSRange(location: 0, length: baseLength)
                }
            }
        }
    }
}

/// A row cell: icon + name (Name) or just text (Size/Kind/Modified).
final class FileTableCellView: NSTableCellView {
    let column: FileTableColumn
    private let label = NSTextField(labelWithString: "")
    private var iconView: NSImageView?
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    /// An "alias arrow" over the icon for symbolic links (Workspace) — as in Finder and
    /// like SymlinkBadge in the SwiftUI modes (Icons/Columns), see its comment.
    private var badgeView: NSImageView?
    private var badgeSizeConstraints: [NSLayoutConstraint] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Date for a column: "—" for a missing one (.distantPast), otherwise the short
    /// format.
    private static func dateString(_ date: Date) -> String {
        date == .distantPast ? "—" : dateFormatter.string(from: date)
    }

    init(column: FileTableColumn) {
        self.column = column
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        if column == .name {
            // By default NSImageView registers ITSELF as a drag destination (its types
            // include NSFilenamesPboardType) — and, when under the cursor, intercepted the
            // file drag: the event never reached the table/collection at all. Hence the
            // symptom "in Icons a file can be dropped on a folder's label but not on its
            // icon" (NSTextField isn't declared a destination, so everything worked over the
            // name).
            let icon = NSImageView()
            icon.unregisterDraggedTypes()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            iconView = icon
            let width = icon.widthAnchor.constraint(equalToConstant: 16)
            let height = icon.heightAnchor.constraint(equalToConstant: 16)
            iconWidthConstraint = width
            iconHeightConstraint = height

            let badge = NSImageView()
            badge.unregisterDraggedTypes()   // see the comment at icon
            badge.translatesAutoresizingMaskIntoConstraints = false
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold)
            badge.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            badge.contentTintColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            badge.isHidden = true
            addSubview(badge)
            badgeView = badge
            let badgeWidth = badge.widthAnchor.constraint(equalToConstant: 8)
            let badgeHeight = badge.heightAnchor.constraint(equalToConstant: 8)
            badgeSizeConstraints = [badgeWidth, badgeHeight]

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                width, height,
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                badge.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -1),
                badge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
                badgeWidth, badgeHeight,
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A tooltip with the full name — only when it's actually truncated. Computed in
    /// layout() (the label's frame is known by then): text width in the system font
    /// vs the label's width.
    override func layout() {
        super.layout()
        guard column == .name else { return }
        let textWidth = (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width
        label.toolTip = textWidth > label.frame.width + 1 ? label.stringValue : nil
    }

    func configure(item: FileItem, column: FileTableColumn, zoomLevel: CGFloat, isCut: Bool) {
        label.font = .systemFont(ofSize: 13 * zoomLevel)
        alphaValue = isCut ? 0.5 : 1
        let palette = Theme.current
        switch column {
        case .name:
            label.stringValue = item.name
            label.textColor = item.isHidden ? palette.secondaryLabel : palette.label
            iconView?.image = item.icon
            let size = 16 * zoomLevel
            iconWidthConstraint?.constant = size
            iconHeightConstraint?.constant = size
            badgeView?.isHidden = !item.isSymbolicLink
            let badgeSize = max(7, 8 * zoomLevel)
            for constraint in badgeSizeConstraints { constraint.constant = badgeSize }
            badgeView?.layer?.cornerRadius = badgeSize / 2
        case .size:
            label.stringValue = item.displaySize
            label.textColor = palette.secondaryLabel
        case .kind:
            label.stringValue = item.kind
            label.textColor = palette.secondaryLabel
        case .modified:
            label.stringValue = Self.dateString(item.modified)
            label.textColor = palette.secondaryLabel
        case .created:
            label.stringValue = Self.dateString(item.created)
            label.textColor = palette.secondaryLabel
        case .lastOpened:
            label.stringValue = Self.dateString(item.lastOpened)
            label.textColor = palette.secondaryLabel
        case .dateAdded:
            label.stringValue = Self.dateString(item.dateAdded)
            label.textColor = palette.secondaryLabel
        case .tags:
            label.stringValue = item.tagsDisplay
            label.textColor = palette.secondaryLabel
        }
    }
}
