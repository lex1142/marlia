import SwiftUI
import AppKit

// Columns mode (Miller columns): rendering columns/rows, the preview column,
// auto-scroll, click navigation and drag selection. Split out of PaneView.swift; the
// Columns @State stays in the PaneView struct itself (stored properties aren't allowed
// in an extension).
extension PaneView {

    var fileColumns: some View {
        // GeometryReader makes the horizontal ScrollView fill all the available height
        // (otherwise it would shrink to its content). Each column takes care of its row
        // height itself: the native ColumnNSTableView.layout() stretches the clip view
        // so clicks below the rows (deselect) reach the table.
        GeometryReader { _ in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(displayedColumns) { column in
                        columnList(column)
                            // The column frame in content coordinates ("columnsContent") —
                            // for auto-scrolling to the active column. The columns are in a
                            // plain HStack (not lazy) — all instantiated, so the frames are
                            // reliable, unlike LazyVStack rows.
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: ColumnFramesKey.self,
                                    value: [column.id: g.frame(in: .named("columnsContent"))]
                                )
                            })
                        resizableDivider(for: column)
                    }
                }
                .coordinateSpace(name: "columnsContent")
                // An AppKit anchor inside the ScrollView's document: enables scrollToVisible
                // to the active column's frame — a minimal shift, nothing if it's already
                // visible (unlike ScrollViewReader.scrollTo, which always aligns to the
                // anchor and so jerked the scroll even when clicking an already-visible
                // column).
                .background(ColumnsScrollAnchor(driver: columnsScrollDriver))
            }
            // The keyboard (↑↓ natively, →/←/Return/Tab) is handled inside the active
            // column (ColumnTableView.keyDown → handleActiveColumnKey), not by a
            // separate NSView monitor over the table — otherwise it would take first
            // responder away from it.
            .onPreferenceChange(ColumnFramesKey.self) { frames in
                columnFrames = frames
                // A new column (navigating deeper) appears in the chain before its frame
                // is measured — then scrollToActiveColumn has set pendingColumnScroll,
                // and we finish the scroll here as soon as the frame arrives. async — so
                // NSScrollView has time to widen the document for the new column BEFORE
                // scrollToVisible (otherwise it hits the old width and the scroll lags
                // one step behind).
                if let target = pendingColumnScroll, let f = frames[target] {
                    pendingColumnScroll = nil
                    performColumnScroll(f)
                }
            }
            .onAppear { rebuildColumnChain(); updatePreviewColumn(); scrollToRightmostColumn() }
            .onChange(of: model.currentURL) { _ in
                rebuildColumnChain()
                // Reset the preview ONLY if it now collides with the chain (going
                // deeper: the previewed folder became currentURL — otherwise ForEach
                // would have two identical ids). On ← the preview of the folder we left
                // has already been set by goToParentColumn from ready data and doesn't
                // collide — keep it so the column doesn't flicker (an async reload of
                // the same thing isn't needed here).
                if let p = previewColumn, columnChain.contains(where: { $0.id == p.id }) {
                    previewColumn = nil
                }
                updatePreviewColumn()
                scrollToRightmostColumn()
            }
            .onChange(of: model.showHidden) { _ in previewColumn = nil; rebuildColumnChain(forceReload: true); updatePreviewColumn(); scrollToRightmostColumn() }
            .onChange(of: model.items) { _ in refreshLastColumn() }
            // As in Finder: select a folder in the active column (by keyboard or mouse)
            // and its contents are immediately previewed in the column to the right,
            // WITHOUT entering it (currentURL doesn't change, focus/↑↓ stay in the
            // active column). Scrolling to the preview is done by updatePreviewColumn
            // itself, and only on a real preview change (otherwise scrollToVisible on
            // every click would knock out the keyboard focus).
            .onChange(of: model.selection) { _ in updatePreviewColumn() }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                acceptDrop(providers, destination: model.currentURL)
            }
        }
    }

    /// Scroll to the rightmost column (the preview column if there is one, otherwise the
    /// active one) with NSView.scrollToVisible semantics: a minimal horizontal shift,
    /// nothing if the column is already fully visible. If its frame isn't measured yet (it
    /// just appeared), set pendingColumnScroll — .onPreferenceChange(ColumnFramesKey) will
    /// finish the scroll.
    private func scrollToRightmostColumn() {
        let target = previewColumn?.id ?? model.currentURL
        if let f = columnFrames[target] {
            performColumnScroll(f)
        } else {
            pendingColumnScroll = target
        }
    }

    /// The common auto-scroll path: async — the layout (cutting off columns to the
    /// right / a new/preview column appearing) is applied in this same pass; scroll
    /// after it, otherwise we'd see the position "one step behind".
    private func performColumnScroll(_ f: CGRect) {
        DispatchQueue.main.async { columnsScrollDriver.ensureVisible(horizontalRect(f)) }
    }

    /// Horizontal only: y=0, height=1 — so scrollToVisible doesn't try to move
    /// vertically as well (the ScrollView is horizontal, but a rect with a
    /// "foreign" y could provoke an extra adjustment).
    private func horizontalRect(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: 0, width: f.width, height: 1)
    }

    /// Columns to render: the chain + the preview on the right (if any).
    private var displayedColumns: [ColumnEntry] {
        previewColumn.map { columnChain + [$0] } ?? columnChain
    }

    /// Recomputes the preview column from the current selection. Deciding "what to
    /// preview" is synchronous and cheap; reading the folder's contents goes to the
    /// background with a 150ms debounce, so holding ↑/↓ over folders doesn't read the
    /// disk on every step and doesn't stutter.
    private func updatePreviewColumn() {
        previewLoadTask?.cancel()

        guard model.selection.count == 1,
              let id = model.selection.first,
              let item = model.items.first(where: { $0.id == id }),
              item.isNavigableFolder else {
            // A file / nothing / several are selected — do NOT collapse a previously
            // opened preview column (otherwise the UI jitters). The preview changes
            // only when focus lands on ANOTHER folder, and is fully reset when
            // currentURL changes (see onChange(currentURL)).
            return
        }
        let folder = item.url.resolvingSymlinksInPath()
        // If the folder (via a symlink) is already in the chain — don't preview it,
        // otherwise ForEach would end up with two identical ids.
        guard !columnChain.contains(where: { $0.id == folder }) else {
            setPreview(nil)
            return
        }
        // Already showing this folder — don't re-read it.
        guard previewColumn?.id != folder else { return }

        let includeHidden = model.showHidden
        previewLoadTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // debounce
            if Task.isCancelled { return }
            let items = await Self.loadPreviewItems(in: folder, includeHidden: includeHidden)
            if Task.isCancelled { return }
            // The selection may have moved during loading (cancellation catches almost
            // everything, but the window between the last check and the assignment is
            // closed by also checking the selection).
            guard model.selection.count == 1, model.selection.first == id else { return }
            setPreview(ColumnEntry(id: folder, items: items, selectedChildURL: nil))
        }
    }

    /// Reads a folder's contents in the background (FileItem.loadItems isn't isolated and
    /// is safe off the main thread: FileManager + resourceValues; icons load lazily
    /// later).
    private static func loadPreviewItems(in url: URL, includeHidden: Bool) async -> [FileItem] {
        await Task.detached { FileItem.loadItems(in: url, includeHidden: includeHidden) }.value
    }

    /// Applies the preview column and scrolls to it ONLY on a real change (otherwise
    /// scrollToVisible on every update would knock first responder off the active
    /// column).
    func setPreview(_ new: ColumnEntry?) {
        let oldID = previewColumn?.id
        previewColumn = new
        if previewColumn?.id != oldID { scrollToRightmostColumn() }
    }

    /// Rebuilds the column chain from the root to currentURL. By default it REUSES
    /// already-loaded parent columns (their contents don't change during navigation),
    /// reading from disk only the truly new ones — otherwise every navigation step re-read
    /// ALL ancestors and recreated every ColumnEntry (extra stats + re-rendering unchanged
    /// columns). forceReload=true (showHidden changed) disables reuse, since the set of
    /// visible items changes.
    private func rebuildColumnChain(forceReload: Bool = false) {
        var ancestors: [URL] = []
        var cursor = model.currentURL
        while true {
            ancestors.append(cursor)
            if cursor.pathComponents.count <= 1 { break }
            cursor = cursor.deletingLastPathComponent()
        }
        ancestors.reverse()

        let cached = forceReload ? [:] : Dictionary(columnChain.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        columnChain = ancestors.enumerated().map { index, dir in
            let isLast = index == ancestors.count - 1
            let selectedChild = isLast ? nil : ancestors[index + 1]
            // The last column always mirrors the current model.items.
            if isLast { return ColumnEntry(id: dir, items: model.items, selectedChildURL: nil) }
            // The parent was already loaded — reuse its items (no disk access),
            // updating only the highlighted child. Otherwise read from disk.
            let items = cached[dir]?.items ?? FileItem.loadItems(in: dir, includeHidden: model.showHidden)
            return ColumnEntry(id: dir, items: items, selectedChildURL: selectedChild)
        }
    }

    private func refreshLastColumn() {
        guard let last = columnChain.last, last.id == model.currentURL else {
            rebuildColumnChain()
            return
        }
        columnChain[columnChain.count - 1] = ColumnEntry(id: last.id, items: model.items, selectedChildURL: nil)
    }

    private func columnList(_ column: ColumnEntry) -> some View {
        let isLastColumn = column.id == model.currentURL
        return ColumnTableView(
            items: column.items,
            isActive: isLastColumn,
            selectedIDs: isLastColumn ? model.selection : [],
            zoomLevel: model.zoomLevel,
            isCut: { appState.isCut($0) },
            cutURLs: clipboard.isCutPending ? clipboard.urls : [],
            themeGeneration: theme.generation,
            onRowClick: { item, isOnName, clickCount, wasSole, modifiers in
                handleColumnClick(item, in: column, isOnName: isOnName, clickCount: clickCount, wasSole: wasSole, modifiers: modifiers)
            },
            onEmptyClick: {
                if renamingItem != nil { commitRename() }
                appState.activate(side)
                isEditingPath = false
                keyFocusTrigger += 1
                cancelPendingRename()
                // A click on empty space always collapses the preview column on the right
                // (nothing selected/not going deeper — nothing to preview). Active: clear
                // the selection explicitly — the native super.mouseDown on the table's empty
                // area did this unreliably (the deselect inside its tracking loop never
                // reached the model). Parent: make it current (columns to the right are cut
                // off by rebuilding the chain).
                previewColumn = nil
                if isLastColumn {
                    if !model.selection.isEmpty { model.selection = [] }
                } else {
                    model.navigate(to: column.id)
                }
            },
            onSelectionChanged: { model.selection = $0 },
            onKeyCommand: { handleActiveColumnKey($0) },
            onEscape: { handleEscape() },
            buildContextMenu: { items in contextNSMenu(for: items) },
            onDrop: { urls, destination in acceptColumnsDrop(urls: urls, destination: destination) },
            columnURL: column.id,
            editRequestID: isLastColumn ? columnEditRequestID : nil,
            onEditRequestHandled: { columnEditRequestID = nil },
            onRenameCommit: { item, newName in
                guard !newName.isEmpty, newName != item.name else { return }
                appState.rename(item: item, to: newName, in: model)
            },
            focusRequestTrigger: keyFocusTrigger
        )
        .frame(width: columnWidth(for: column))
        .background(Color(nsColor: Theme.current.paneBackground ?? .textBackgroundColor))
    }

    /// Drop in Columns mode: after the transfer, reload NOT only currentURL (like
    /// acceptTableDrop) but rebuild the whole chain (forceReload) + the preview —
    /// otherwise the receiving column (an ancestor folder or the preview) and the source
    /// column didn't update until you navigated into them again.
    @discardableResult
    func acceptColumnsDrop(urls: [URL], destination: URL) -> Bool {
        let items = urls.compactMap(FileItem.init)
        guard !items.isEmpty else { return false }
        appState.transfer(items: items, to: destination, mode: .move) {
            model.reload()
            // Reset the preview before rebuilding: if the drop was into the preview column
            // itself (the folder on the right), updatePreviewColumn would otherwise see the same
            // folder and, per its guard, not re-read it — the items didn't appear until it was
            // reopened (bug 5).
            previewColumn = nil
            rebuildColumnChain(forceReload: true)
            updatePreviewColumn()
        }
        return true
    }

    /// Keyboard of the active column: ↑/↓ — native NSTableView navigation (return false);
    /// →/←/Return/Delete/Tab — Columns mode commands.
    func handleActiveColumnKey(_ event: NSEvent) -> Bool {
        guard let command = ShortcutStore.shared.command(for: event) else { return false }
        switch command {
        case .navigateRight: enterSelectedFolder(); return true
        case .navigateLeft: goToParentColumn(); return true
        case .openSelection:
            // Return: a folder — open it like → (enter + focus + select the first item), a file
            // — open it.
            if let id = model.selection.first, let item = model.items.first(where: { $0.id == id }), item.isNavigableFolder {
                enterSelectedFolder()
            } else {
                openSelected()
            }
            return true
        case .goToParentDirectory: model.goUp(); return true
        case .switchPane: switchActivePaneIfPossible(); return true
        default: return false  // ↑↓ and everything else — native table navigation
        }
    }

    /// Column width: set by dragging (columnWidths by id) or the common default.
    private func columnWidth(for column: ColumnEntry) -> CGFloat {
        columnWidths[column.id] ?? CGFloat(columnDefaultWidth)
    }

    /// The handle-divider between columns. A separate HStack cell with a fixed 8pt width (a
    /// thin line in the middle + a transparent AppKit handle across the full width on top)
    /// — neighbouring columns DON'T overlap it (unlike an .overlay on a 1pt Divider), so
    /// the whole width is reliably clickable and the ⟺ cursor works across the entire zone.
    private func resizableDivider(for column: ColumnEntry) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: Theme.current.separator))
                .frame(width: 1)
            ColumnResizeHandle(
                // Before dragging, "freeze" the widths of all visible columns into explicit
                // values — otherwise columns without their own width read the common
                // default, and changing the default (in onEnd) would move them along with
                // the one being dragged.
                onBegin: {
                    for col in displayedColumns where columnWidths[col.id] == nil {
                        columnWidths[col.id] = CGFloat(columnDefaultWidth)
                    }
                },
                onResize: { dx in resizeColumn(column, by: dx) },
                // When the drag ends, remember the width as the default for NEW columns (and
                // for the next launch) — already-open columns are frozen and won't move.
                onEnd: { columnDefaultWidth = Double(columnWidth(for: column)) }
            )
        }
        .frame(width: 8)
    }

    /// Incremental change of a column's width by dragging its right edge.
    private func resizeColumn(_ column: ColumnEntry, by dx: CGFloat) {
        let current = columnWidth(for: column)
        columnWidths[column.id] = min(max(current + dx, 150), 520)
    }

    /// A click on a column row (from ColumnTableView). The selection in the active column
    /// has already been set NATIVELY by the table (plain/shift/cmd), so here only: a
    /// double-click — enter/open; a single click on the name of the solely selected item —
    /// rename; a click in a parent/preview column — navigate into it, selecting the item.
    private func handleColumnClick(_ item: FileItem, in column: ColumnEntry, isOnName: Bool, clickCount: Int, wasSole: Bool, modifiers: NSEvent.ModifierFlags) {
        appState.activate(side)
        isEditingPath = false
        keyFocusTrigger += 1
        let isLastColumn = column.id == model.currentURL

        if clickCount >= 2 {
            cancelPendingRename()
            if item.isNavigableFolder {
                model.navigate(to: item.url.resolvingSymlinksInPath())
                if let first = model.items.first { model.selection = [first.id] }
            } else {
                model.open(item)
            }
            return
        }

        if isLastColumn {
            let clean = !modifiers.contains(.command) && !modifiers.contains(.shift)
                && !modifiers.contains(.control) && !modifiers.contains(.option)
            if wasSole, isOnName, clean {
                scheduleRename(for: item)  // a repeated click on the name → rename
            } else {
                cancelPendingRename()      // the selection has already been set natively
            }
        } else {
            // Not the last column: make it the current directory (columns to the right are
            // cut off by rebuilding the chain), and the item gets selected in it. navigate
            // reloads model.items synchronously, so the selection can be set right away.
            // Reset the stale preview column (from a deeper level) — otherwise it would stay
            // on the right: updatePreviewColumn doesn't collapse it by itself for a
            // file/empty selection, and onChange(currentURL) only clears a collision with the
            // chain (bug 3).
            cancelPendingRename()
            previewColumn = nil
            model.navigate(to: column.id)
            model.selection = [item.id]
        }
    }
}
