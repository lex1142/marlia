import AppKit
import SwiftUI

/// An AppKit replacement for the SwiftUI grid in Icons mode — for the same reason and
/// with the same technique as `FileTableView` for List.
///
/// Motivation (measured 2026-07-22): SwiftUI's `LazyVGrid` re-evaluated ALL cells of
/// the active pane on every selection step — ~200 cell/overlay rebuilds per arrow
/// press, which made keyboard navigation feel like jelly. `NSCollectionView` does
/// selection, arrow navigation, auto-scroll and the rubber-band NATIVELY, without
/// touching SwiftUI, so a selection step costs next to nothing. Click-to-rename,
/// double-click, multi-file drag, drop on a folder and the context menu are
/// implemented by hand — exactly as in `FileNSTableView` (see its comments, same
/// pattern).
struct FileIconsView: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<FileItem.ID>
    let zoomLevel: CGFloat
    let currentDirectoryURL: URL
    let isCut: (URL) -> Bool
    /// The set of cut URLs — a cheap "does the view need reconfiguring" signal (same
    /// role as in FileTableView): without it a reconfigure would run on every selection
    /// change.
    let cutURLs: Set<URL>
    /// Theme-change counter — the same "the view changed" signal as
    /// zoom/cutURLs (see ThemeStore.generation).
    let themeGeneration: Int

    let onActivate: () -> Void
    let onOpen: (FileItem) -> Void
    let onRenameCommit: (FileItem, String) -> Void
    let onGoUp: () -> Void
    let onSwitchPane: () -> Void
    /// Esc in icons: close the filter/search. true — the key was handled.
    let onEscape: () -> Bool
    let buildContextMenu: ([FileItem]) -> NSMenu
    let onDrop: ([URL], URL) -> Bool
    let focusRequestTrigger: Int
    let editRequestID: FileItem.ID?
    let onEditRequestHandled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let collectionView = IconCollectionView()
        collectionView.coordinator = context.coordinator
        collectionView.collectionViewLayout = context.coordinator.makeLayout(zoom: zoomLevel)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: false)
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let collectionView = coordinator.collectionView else { return }

        if coordinator.displayedItems != items {
            coordinator.displayedItems = items
            collectionView.reloadData()
        } else {
            // The contents haven't changed; reconfigure the visible cells only when
            // something affecting their look changed (zoom / the set of cut items) — not
            // on every selection change (its native highlight is drawn by
            // NSCollectionView itself).
            let appearanceChanged = zoomLevel != coordinator.lastAppliedZoom
                || cutURLs != coordinator.lastAppliedCutURLs
                || themeGeneration != coordinator.lastAppliedThemeGeneration
            if appearanceChanged {
                for item in collectionView.visibleItems() {
                    if let fileItem = item as? FileIconItem, let index = fileItem.itemIndex,
                       coordinator.displayedItems.indices.contains(index) {
                        fileItem.configure(with: coordinator.displayedItems[index], zoom: zoomLevel, isCut: isCut(coordinator.displayedItems[index].url))
                    }
                }
            }
        }

        if zoomLevel != coordinator.lastAppliedZoom {
            collectionView.collectionViewLayout = coordinator.makeLayout(zoom: zoomLevel)
        }
        coordinator.lastAppliedZoom = zoomLevel
        coordinator.lastAppliedCutURLs = cutURLs
        coordinator.lastAppliedThemeGeneration = themeGeneration

        // Selection sync: model → the collection's native selection.
        let desired = Set(items.enumerated().compactMap { index, item in
            selection.contains(item.id) ? IndexPath(item: index, section: 0) : nil
        })
        if collectionView.selectionIndexPaths != desired {
            coordinator.isSyncingSelectionFromBinding = true
            collectionView.selectionIndexPaths = desired
            coordinator.isSyncingSelectionFromBinding = false
        }

        if coordinator.lastFocusRequestTrigger != focusRequestTrigger {
            coordinator.lastFocusRequestTrigger = focusRequestTrigger
            DispatchQueue.main.async { collectionView.window?.makeFirstResponder(collectionView) }
        }

        if let editRequestID, editRequestID != coordinator.lastHandledEditRequestID {
            coordinator.lastHandledEditRequestID = editRequestID
            if let index = items.firstIndex(where: { $0.id == editRequestID }) {
                coordinator.beginEditing(atItem: index)
            }
            DispatchQueue.main.async { onEditRequestHandled() }
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
        var parent: FileIconsView
        weak var collectionView: NSCollectionView?
        var displayedItems: [FileItem] = []

        var isSyncingSelectionFromBinding = false
        var lastFocusRequestTrigger = 0
        var lastHandledEditRequestID: FileItem.ID?
        var lastAppliedZoom: CGFloat = -1
        var lastAppliedCutURLs: Set<URL> = []
        /// -1 (not 0) — so cells get themed colors on the very first update.
        var lastAppliedThemeGeneration = -1

        private var pendingRenameWorkItem: DispatchWorkItem?
        private var isCancellingEdit = false
        /// Anchor for ⇧-click (the range from it to the current item). Set on a plain
        /// click and on ⌘-click.
        var selectionAnchor: IndexPath?
        /// The currently highlighted drag target folder (to clear the highlight on moving
        /// on/exiting).
        private var dropHighlightIndexPath: IndexPath?

        init(_ parent: FileIconsView) { self.parent = parent }

        /// Applies the selection programmatically (⇧/⌘-clicks are handled by us —
        /// NSCollectionView's native behavior with modifiers is unreliable and fights the
        /// two-way binding): setting selectionIndexPaths programmatically does NOT send
        /// didSelect, so the binding is synced by hand.
        func applySelection(_ paths: Set<IndexPath>) {
            collectionView?.selectionIndexPaths = paths
            syncSelectionToBinding()
        }

        func selectRange(to target: IndexPath) {
            let anchorItem = selectionAnchor?.item ?? target.item
            let lo = min(anchorItem, target.item), hi = max(anchorItem, target.item)
            applySelection(Set((lo...hi).map { IndexPath(item: $0, section: 0) }))
        }

        func toggle(_ indexPath: IndexPath, currentlySelected: Set<IndexPath>) {
            var next = currentlySelected
            if next.contains(indexPath) { next.remove(indexPath) } else { next.insert(indexPath) }
            selectionAnchor = indexPath
            applySelection(next)
        }

        func makeLayout(zoom: CGFloat) -> NSCollectionViewFlowLayout {
            let layout = FillHeightFlowLayout()
            let width = 96 * zoom
            let thumb = 48 * zoom
            // Height for the icon + 2 lines of name (otherwise the second line spilled
            // outside the cell and the highlight didn't cover it).
            let lineHeight = ceil(NSFont.systemFont(ofSize: 11 * zoom).boundingRectForFont.height)
            layout.itemSize = NSSize(width: width, height: 8 + thumb + 4 + lineHeight * 2 + 8)
            layout.minimumInteritemSpacing = 12
            layout.minimumLineSpacing = 16
            layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            return layout
        }

        // --- data source ---
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            displayedItems.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath) as! FileIconItem
            item.coordinator = self
            item.itemIndex = indexPath.item
            if displayedItems.indices.contains(indexPath.item) {
                let fileItem = displayedItems[indexPath.item]
                item.configure(with: fileItem, zoom: parent.zoomLevel, isCut: parent.isCut(fileItem.url))
            }
            return item
        }

        // --- selection ---
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelectionToBinding() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelectionToBinding() }

        private func syncSelectionToBinding() {
            guard !isSyncingSelectionFromBinding, let collectionView else { return }
            let ids = Set(collectionView.selectionIndexPaths.compactMap {
                displayedItems.indices.contains($0.item) ? displayedItems[$0.item].id : nil
            })
            if parent.selection != ids { parent.selection = ids }
        }

        // --- drag source (multi-file — the whole selection is dragged) ---
        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            (collectionView as? IconCollectionView)?.dragStarted = true
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard displayedItems.indices.contains(indexPath.item) else { return nil }
            return displayedItems[indexPath.item].url as NSURL
        }

        // --- drop (on a folder → into it, otherwise → into the current directory) ---
        //
        // NSCollectionViewFlowLayout does NOT support .on (a drop ONTO a cell) — it's meant
        // for .before/.after (inserting between cells). Forcing .on worked inconsistently:
        // for external (cross-pane) drags, hovering over a folder produced a spurious
        // draggingExited and the drop fell through (confirmed by logs). So we always return
        // the reliable .before (perform/accept are guaranteed to be called), and decide
        // "onto which folder" by hit-testing the point in acceptDrop. The target folder's
        // highlight is drawn by us, setting its highlightState (.asDropTarget) by hand,
        // since the .on mechanism is gone.
        /// Highlighting the target folder while dragging. Called from the view's own
        /// draggingEntered/draggingUpdated (see IconCollectionView) — the delegate's
        /// validateDrop is no longer used, see the comment there.
        func updateDropHighlight(under draggingInfo: NSDraggingInfo, in collectionView: NSCollectionView) {
            setDropHighlight(folderIndexPath(under: draggingInfo, in: collectionView))
        }

        /// The drop itself: the target is the folder under the cursor, otherwise
        /// the current directory.
        func performDrop(_ draggingInfo: NSDraggingInfo, in collectionView: NSCollectionView) -> Bool {
            let folderIP = folderIndexPath(under: draggingInfo, in: collectionView)
            setDropHighlight(nil)
            guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
            let destination = folderIP.map { displayedItems[$0.item].url } ?? parent.currentDirectoryURL
            return parent.onDrop(urls, destination)
        }

        /// The indexPath of the folder under the drag cursor (if it's a folder and isn't
        /// among the items being dragged — so dropping a folder on itself doesn't count as
        /// nesting), otherwise nil.
        private func folderIndexPath(under draggingInfo: NSDraggingInfo, in collectionView: NSCollectionView) -> IndexPath? {
            let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
            guard let ip = collectionView.indexPathForItem(at: point),
                  displayedItems.indices.contains(ip.item),
                  displayedItems[ip.item].isNavigableFolder else { return nil }
            let dragged = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return dragged.contains(displayedItems[ip.item].url) ? nil : ip
        }

        /// Target-folder highlight: set the hovered cell's highlightState to
        /// .asDropTarget by hand (clearing the previous one), since the .on mechanism is
        /// no longer used.
        private func setDropHighlight(_ indexPath: IndexPath?) {
            guard dropHighlightIndexPath != indexPath else { return }
            if let old = dropHighlightIndexPath, let item = collectionView?.item(at: old) as? FileIconItem {
                item.highlightState = .none
            }
            dropHighlightIndexPath = indexPath
            if let new = indexPath, let item = collectionView?.item(at: new) as? FileIconItem {
                item.highlightState = .asDropTarget
            }
        }

        func clearDropHighlight() { setDropHighlight(nil) }

        // --- clicks (double = open; single on the name of an already-selected item =
        // rename) ---
        func handleMouseDown(indexPath: IndexPath, wasSoleSelectedBefore: Bool, hitName: Bool, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
            guard displayedItems.indices.contains(indexPath.item) else { return }
            if clickCount >= 2 {
                pendingRenameWorkItem?.cancel()
                parent.onOpen(displayedItems[indexPath.item])
                return
            }
            let clean = !modifiers.contains(.command) && !modifiers.contains(.shift)
                && !modifiers.contains(.control) && !modifiers.contains(.option)
            guard clickCount == 1, wasSoleSelectedBefore, hitName, clean else { return }
            // Deferred rename (as in List/the old grid): give a second click the chance to
            // arrive.
            pendingRenameWorkItem?.cancel()
            let index = indexPath.item
            let work = DispatchWorkItem { [weak self] in self?.beginEditing(atItem: index) }
            pendingRenameWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }

        func cancelPendingRename() {
            pendingRenameWorkItem?.cancel()
            pendingRenameWorkItem = nil
        }

        func beginEditing(atItem index: Int) {
            guard let collectionView,
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? FileIconItem else { return }
            item.beginEditing()
        }

        // --- open / goUp / switchPane for the keyboard ---
        func openSelected() {
            guard let collectionView, let indexPath = collectionView.selectionIndexPaths.first,
                  displayedItems.indices.contains(indexPath.item) else { return }
            parent.onOpen(displayedItems[indexPath.item])
        }

        // --- context menu ---
        func contextMenu(forItemAt indexPath: IndexPath?) -> NSMenu {
            cancelPendingRename()
            guard let collectionView else { return parent.buildContextMenu([]) }
            if let indexPath, displayedItems.indices.contains(indexPath.item) {
                // Right-click on an unselected item selects only it (a multi-selection is
                // preserved).
                if !collectionView.selectionIndexPaths.contains(indexPath) {
                    collectionView.selectionIndexPaths = [indexPath]
                    syncSelectionToBinding()
                }
                let items = collectionView.selectionIndexPaths.compactMap {
                    displayedItems.indices.contains($0.item) ? displayedItems[$0.item] : nil
                }
                return parent.buildContextMenu(items)
            }
            return parent.buildContextMenu([])  // empty area
        }

        // --- NSTextFieldDelegate (inline rename) ---
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let textField = control as? NSTextField else { return false }
            isCancellingEdit = true
            if let item = textField.superview?.enclosingCollectionViewItem as? FileIconItem, item.itemIndex.map({ displayedItems.indices.contains($0) }) == true {
                textField.stringValue = displayedItems[item.itemIndex!].name
            }
            control.window?.makeFirstResponder(collectionView)
            isCancellingEdit = false
            return true
        }

        /// The name may grow right while typing — the box grows along with it.
        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let item = textField.superview?.enclosingCollectionViewItem as? FileIconItem
            else { return }
            item.updateEditingLabelHeight()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            FileIconItem.configureLabelForDisplay(textField)  // restore the 2-line look with "…"
            // The height is restored BEFORE the checks below: a cancelled rename never
            // reaches them, and the box must collapse in both cases.
            (textField.superview?.enclosingCollectionViewItem as? FileIconItem)?.collapseLabelAfterEditing()
            guard !isCancellingEdit,
                  let item = textField.superview?.enclosingCollectionViewItem as? FileIconItem,
                  let index = item.itemIndex, displayedItems.indices.contains(index) else { return }
            let fileItem = displayedItems[index]
            let newName = textField.stringValue
            // See the comment in FileTableView: the name check is shared with the
            // model, otherwise a name made only of spaces left the cell visually
            // nameless.
            guard FileOperationService.isValidItemName(newName), newName != fileItem.name else {
                textField.stringValue = fileItem.name
                return
            }
            parent.onRenameCommit(fileItem, newName)
        }
    }
}

/// An NSCollectionView with native navigation/selection/rubber-band; by hand —
/// only double-click/click-to-rename (mouseDown), Return/Delete/Tab (keyDown)
/// and the context menu.
final class IconCollectionView: NSCollectionView {
    weak var coordinator: FileIconsView.Coordinator?

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

    /// Set by the delegate when a drag session starts; reset at the start of every mouseDown.
    /// Needed to tell "a click on a member of a multi-selection" (mouseUp arrives — collapse
    /// to one) from "dragged the group" (mouseUp is swallowed by the drag session — keep the
    /// selection).
    var dragStarted = false
    /// The item to collapse the selection to on mouseUp if no drag started (a click on
    /// a member of a multi-selection). See mouseUp.
    private var pendingClickReduce: IndexPath?

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        pendingClickReduce = nil
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        let modifiers = event.modifierFlags
        coordinator?.cancelPendingRename()
        coordinator?.parent.onActivate()

        // A click on empty space — native (rubber-band + deselect).
        guard let coordinator, let indexPath, coordinator.displayedItems.indices.contains(indexPath.item) else {
            super.mouseDown(with: event)
            return
        }

        // ⇧/⌘ — handled by us (deterministically, like Finder); super isn't called so
        // the native selection doesn't interfere.
        if modifiers.contains(.shift) {
            coordinator.selectRange(to: indexPath)
            return
        }
        if modifiers.contains(.command) {
            coordinator.toggle(indexPath, currentlySelected: selectionIndexPaths)
            return
        }

        // A plain click — native (correct selection + the native drag threshold,
        // including dragging the whole group by clicking an already-selected item).
        // After super, record the anchor and handle double-click / click-to-rename.
        let wasSole = selectionIndexPaths == [indexPath]
        // A click on an item within a MULTI-selection: like Finder, do NOT collapse right
        // away (so the whole group can still be dragged) — defer to mouseUp, if a drag
        // never started. With count==1 super repositions the selection correctly by
        // itself.
        if selectionIndexPaths.count > 1 { pendingClickReduce = indexPath }
        let hitName = hitTestName(at: point, indexPath: indexPath)
        super.mouseDown(with: event)
        coordinator.selectionAnchor = indexPath
        coordinator.handleMouseDown(indexPath: indexPath, wasSoleSelectedBefore: wasSole, hitName: hitName, clickCount: event.clickCount, modifiers: modifiers)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // A click (no drag) on an item that was part of a multi-selection → collapse to
        // that one item, as in Finder. Had a group drag started, we wouldn't get here
        // (the drag session swallows mouseUp), or dragStarted would already have been
        // set by the delegate.
        if let path = pendingClickReduce, !dragStarted {
            pendingClickReduce = nil
            if selectionIndexPaths != [path] {
                coordinator?.applySelection([path])
                coordinator?.selectionAnchor = path
            }
        }
        pendingClickReduce = nil
    }

    private func hitTestName(at point: NSPoint, indexPath: IndexPath) -> Bool {
        guard let item = item(at: indexPath) as? FileIconItem, let label = item.textField else { return false }
        let frameInSelf = label.convert(label.bounds, to: self)
        return frameInSelf.contains(point)
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else {
            super.keyDown(with: event)
            return
        }
        guard let command = ShortcutStore.shared.command(for: event) else {
            // Not a command — maybe the person is typing a file name.
            if handleTypeSelect(event, coordinator: coordinator) { return }
            super.keyDown(with: event)
            return
        }
        switch command {
        case .openSelection: coordinator.openSelected()
        case .goToParentDirectory: coordinator.parent.onGoUp()
        case .switchPane: coordinator.parent.onSwitchPane()
        case .showContextMenu: presentContextMenuFromKeyboard()
        case .navigateUp, .navigateDown, .navigateLeft, .navigateRight:
            // With an EMPTY selection (after a click on empty space or Tab into a pane
            // with no selection) NSCollectionView's native arrow navigation selects
            // nothing — the arrows seem "dead". Select the first item ourselves (as List
            // does); from there NSCollectionView drives grid navigation itself.
            if selectionIndexPaths.isEmpty, !coordinator.displayedItems.isEmpty {
                let path = IndexPath(item: 0, section: 0)
                coordinator.applySelection([path])
                coordinator.selectionAnchor = path
                scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            } else {
                super.keyDown(with: event)  // there's a selection — native navigation/scrolling
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Type-to-select

    /// NSTableView does this by itself (List and Columns get it for free by giving
    /// the delegate the file name), but NSCollectionView doesn't at all, so the
    /// typed buffer has to be kept by hand. A second and a half without keystrokes
    /// resets it — the same threshold AppKit uses.
    private var typeSelectBuffer = ""
    private var typeSelectStamp = Date.distantPast

    private func handleTypeSelect(_ event: NSEvent, coordinator: FileIconsView.Coordinator) -> Bool {
        // ⌘ and ⌃ mean commands, and Space is taken by Quick Look; neither may be
        // intercepted. Every other printable character counts as typing a name.
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar)
        else { return false }

        let now = Date()
        if now.timeIntervalSince(typeSelectStamp) > 1.5 { typeSelectBuffer = "" }
        typeSelectStamp = now
        typeSelectBuffer += characters

        let items = coordinator.displayedItems
        guard !items.isEmpty else { return true }

        // A single letter — start from the next item, so repeated presses cycle
        // through the files starting with that letter (as in Finder). A longer
        // string refines what's already found, so search from the current item.
        let current = selectionIndexPaths.sorted().first?.item ?? -1
        let offset = typeSelectBuffer.count == 1 ? 1 : 0
        let prefix = typeSelectBuffer.lowercased()

        for step in 0..<items.count {
            let index = (current + offset + step + items.count) % items.count
            guard items[index].name.lowercased().hasPrefix(prefix) else { continue }
            let path = IndexPath(item: index, section: 0)
            coordinator.applySelection([path])
            coordinator.selectionAnchor = path
            scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            return true
        }
        // No match — swallow the character anyway, otherwise it would go to super and
        // could trigger something unrelated.
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.contextMenu(forItemAt: indexPathForItem(at: point))
    }

    /// Context menu from the keyboard (⌃↩) — for the current selection, popped up at
    /// the first selected cell.
    private func presentContextMenuFromKeyboard() {
        guard let coordinator else { return }
        coordinator.cancelPendingRename()
        let items = selectionIndexPaths.sorted().compactMap {
            coordinator.displayedItems.indices.contains($0.item) ? coordinator.displayedItems[$0.item] : nil
        }
        let menu = coordinator.parent.buildContextMenu(items)
        let anchor: NSPoint
        if let ip = selectionIndexPaths.sorted().first,
           let frame = collectionViewLayout?.layoutAttributesForItem(at: ip)?.frame {
            anchor = NSPoint(x: frame.minX + 16, y: frame.maxY)
        } else {
            anchor = NSPoint(x: bounds.minX + 16, y: enclosingScrollView.map { $0.documentVisibleRect.minY + 20 } ?? 20)
        }
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    // MARK: Accepting drags
    //
    // The drop is handled here, via the NSDraggingDestination protocol, and NOT via the
    // delegate's collectionView(_:validateDrop:…)/(_:acceptDrop:…). The reason was
    // established by logging: validateDrop was called properly and returned .move, the
    // folder under the cursor was detected correctly — but acceptDrop was NEVER called,
    // i.e. NSCollectionView refused to complete the drop itself (its mechanics are
    // designed for inserting between cells, while we need a drop INTO a cell; trying to
    // force .on broke in other ways — see the history above). So we take over accepting
    // the drag: there are no intermediate AppKit decisions and no dependency on the
    // layout here — cursor, hit-test, transfer.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        coordinator?.updateDropHighlight(under: sender, in: self)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        coordinator?.updateDropHighlight(under: sender, in: self)
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return coordinator?.performDrop(sender, in: self) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        coordinator?.clearDropHighlight()
    }

    // Clear the manual target-folder highlight when the drag leaves the collection or
    // ends (otherwise .asDropTarget would "stick" on the cell).
    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.clearDropHighlight()
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        coordinator?.clearDropHighlight()
        super.draggingEnded(sender)
    }
}

/// A flow layout that stretches the content to at least the visible area's height.
/// Without it, with few icons the NSCollectionView occupies only its content's height,
/// and the whole empty zone BELOW the icons belongs to the NSScrollView rather than the
/// collection — so no selection rectangle was drawn there (the rubber-band didn't start
/// outside the collection's bounds) and a click on empty space didn't clear the
/// selection/keep focus. An inflated contentSize makes that zone part of the
/// collection, and both behaviors start working natively.
final class FillHeightFlowLayout: NSCollectionViewFlowLayout {
    override var collectionViewContentSize: NSSize {
        var size = super.collectionViewContentSize
        if let clip = collectionView?.enclosingScrollView?.contentView {
            size.height = max(size.height, clip.bounds.height)
        }
        return size
    }
}

/// An icon cell: thumbnail/icon + name, selection highlight, dimming of cut items,
/// symlink badge, inline name editing.
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")

    weak var coordinator: FileIconsView.Coordinator?
    var itemIndex: Int?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let selectionBackground = NSView()
    private var badge: NSImageView?
    private var currentURL: URL?
    private var thumbnailTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.isHidden = true
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(selectionBackground)

        // By default NSImageView registers ITSELF as a drag destination (its types
        // include NSFilenamesPboardType) — and, when under the cursor, intercepted the
        // file drag: the event never reached the table/collection at all. Hence the
        // symptom "in Icons a file can be dropped on a folder's label but not on its
        // icon" (NSTextField isn't declared a destination, so everything worked over the
        // name).
        icon.unregisterDraggedTypes()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)

        Self.configureLabelForDisplay(label)
        label.alignment = .center
        label.isBordered = false
        label.drawsBackground = false
        // The delegate is the Coordinator (it has the commit/cancel editing methods),
        // NOT the item itself.
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            selectionBackground.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            selectionBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            selectionBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            selectionBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),

            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])
        // The label height is fixed at TWO lines regardless of whether it's displaying
        // or editing: otherwise the text field changed the label's height, and the icon
        // and label jumped on entering and leaving rename.
        let labelHeight = label.heightAnchor.constraint(equalToConstant: 0)
        labelHeight.isActive = true
        labelHeightConstraint = labelHeight
        // The label expanded during rename extends beyond the cell — it must not be
        // clipped. On macOS 14+ NSView gained clipsToBounds, and the historical "NSView
        // doesn't clip" can no longer be relied on.
        if #available(macOS 14.0, *) { container.clipsToBounds = false }
        self.view = container
        // Bind NSCollectionViewItem's built-in outlets to our views — otherwise
        // item.textField/imageView stay nil (that's what broke the name hit-test for
        // click-to-rename: it looked at item.textField, which was empty).
        self.imageView = icon
        self.textField = label
    }

    /// Configure the label for DISPLAY: up to 2 lines, wrapping, an ellipsis on the
    /// last visible line. Pulled into a shared method because it has to be restored
    /// after inline editing (the field temporarily becomes single-line) — otherwise
    /// the name was shown as one truncated line without "…".
    static func configureLabelForDisplay(_ label: NSTextField) {
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true
    }

    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var labelHeightConstraint: NSLayoutConstraint?

    /// Highlight of a selected cell: in the system theme — the system accent with
    /// transparency (exactly as before themes existed), in a theme with its own palette
    /// — its selection color.
    private static var selectionColor: NSColor {
        let palette = Theme.current
        return palette.isCustom ? palette.selection : NSColor.controlAccentColor.withAlphaComponent(0.18)
    }

    /// Height of the name box — exactly two lines of the current font.
    private static func twoLineHeight(for font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font)) * 2 + 2
    }

    /// Ceiling on the text field's height during rename. Without it a
    /// three-hundred-character name would expand across the whole pane and
    /// cover half the screen.
    private static let maxEditingLines = 6

    /// Fits the label's height to the FULL name — only while editing.
    ///
    /// In the normal view the label is clamped to two lines (see the comment on
    /// labelHeightConstraint): that way cells have the same height and the selection
    /// highlight clips nothing. But during rename those same two lines hid the tail of a
    /// long name, and editing had to be done blind. So while editing, the box grows to
    /// fit the text and shrinks back afterwards — the cell itself doesn't change size,
    /// the label simply extends beyond it on top of its neighbours.
    func updateEditingLabelHeight() {
        guard let font = label.font else { return }
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let width = label.bounds.width
        guard width > 1, lineHeight > 0 else { return }
        let measured = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lines = min(Self.maxEditingLines, max(2, Int(ceil(measured.height / lineHeight))))
        let target = CGFloat(lines) * lineHeight + 2
        guard labelHeightConstraint?.constant != target else { return }
        labelHeightConstraint?.constant = target
        view.layoutSubtreeIfNeeded()
    }

    /// Back to the two-line look after a rename — including after a cancel.
    func collapseLabelAfterEditing() {
        labelHeightConstraint?.constant = Self.twoLineHeight(for: label.font ?? .systemFont(ofSize: 11))
        view.layoutSubtreeIfNeeded()
    }

    /// Raises the cell above its neighbours: the expanded label extends beyond the
    /// cell, and items of the next row were added to the hierarchy later and would be
    /// drawn on top of it. Done once on entering rename — before taking focus, because
    /// re-inserting the view into the hierarchy would reset first responder.
    private func raiseAboveNeighbours() {
        guard let superview = view.superview else { return }
        superview.addSubview(view, positioned: .above, relativeTo: nil)
    }

    func configure(with fileItem: FileItem, zoom: CGFloat, isCut: Bool) {
        _ = view  // lazy view loading (loadViewIfNeeded is only available from 14.0)
        label.delegate = coordinator  // commit/cancel of inline rename is handled by the Coordinator
        currentURL = fileItem.url
        let thumb = 48 * zoom
        NSLayoutConstraint.deactivate(iconSizeConstraints)
        iconSizeConstraints = [
            icon.widthAnchor.constraint(equalToConstant: thumb),
            icon.heightAnchor.constraint(equalToConstant: thumb),
        ]
        NSLayoutConstraint.activate(iconSizeConstraints)

        // Media with a thumbnail already available — set it right away (otherwise the
        // generic icon flashes on every reconfigure/reload, e.g. on ⌘X/paste).
        if fileItem.isPreviewableMedia, let ready = ThumbnailCache.shared.cached(for: fileItem.url) {
            icon.image = ready
        } else {
            icon.image = fileItem.icon
        }
        label.stringValue = fileItem.name
        let labelFont = NSFont.systemFont(ofSize: 11 * zoom)
        label.font = labelFont
        labelHeightConstraint?.constant = Self.twoLineHeight(for: labelFont)
        let palette = Theme.current
        label.textColor = fileItem.isHidden ? palette.secondaryLabel : palette.label
        // The highlight color is set here rather than in loadView: configure is also
        // called on a theme change (see themeGeneration in updateNSView), while
        // loadView runs once per cell.
        selectionBackground.layer?.backgroundColor = Self.selectionColor.cgColor
        view.alphaValue = isCut ? 0.5 : 1
        label.toolTip = fileItem.name

        // A collection cell is a single element for VoiceOver: without this it saw only
        // a nameless group with a nested text field and announced neither the item type
        // nor that it's a link. (In List the role and name come from NSTableCellView
        // itself.)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(fileItem.name)
        let kind = fileItem.isNavigableFolder ? "Folder" : fileItem.kind
        view.setAccessibilityValueDescription(fileItem.isSymbolicLink ? "\(kind), alias" : kind)

        updateBadge(isSymlink: fileItem.isSymbolicLink, size: max(12, thumb * 0.3))

        // Load the thumbnail asynchronously only if it isn't cached yet (otherwise it was
        // already set synchronously above) — guarding against cell reuse.
        thumbnailTask?.cancel()
        if fileItem.isPreviewableMedia, ThumbnailCache.shared.cached(for: fileItem.url) == nil {
            let url = fileItem.url
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            thumbnailTask = Task { [weak self] in
                let image = await ThumbnailCache.shared.thumbnail(for: url, size: CGSize(width: thumb, height: thumb), scale: scale)
                guard let self, self.currentURL == url, let image else { return }
                self.icon.image = image
            }
        }
    }

    private func updateBadge(isSymlink: Bool, size: CGFloat) {
        if !isSymlink { badge?.isHidden = true; return }
        let badgeView: NSImageView
        if let existing = badge { badgeView = existing } else {
            badgeView = NSImageView()
            badgeView.unregisterDraggedTypes()   // see the comment at icon
            badgeView.wantsLayer = true
            badgeView.translatesAutoresizingMaskIntoConstraints = false
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .bold)
            badgeView.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            badgeView.contentTintColor = .white
            badgeView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            view.addSubview(badgeView)
            NSLayoutConstraint.activate([
                badgeView.widthAnchor.constraint(equalToConstant: size),
                badgeView.heightAnchor.constraint(equalToConstant: size),
                badgeView.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
                badgeView.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            ])
            badgeView.layer?.cornerRadius = size / 2
            badge = badgeView
        }
        badgeView.isHidden = false
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    /// WHILE a rubber-band is being dragged NSCollectionView doesn't touch isSelected
    /// (it's committed on mouseUp), but marks the swept cells via highlightState
    /// (.forSelection / .forDeselection). Without reacting to it the highlight
    /// wouldn't change live during a rubber-band selection — only on release. Both are
    /// taken into account.
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelectionAppearance() }
    }

    private func updateSelectionAppearance() {
        let highlighted: Bool
        switch highlightState {
        // .asDropTarget — the cell is the drop target (the folder under the cursor
        // during a drag): gives the same highlight as selection, so it's clear where the
        // files will land.
        case .forSelection, .asDropTarget: highlighted = true
        case .forDeselection: highlighted = false
        default: highlighted = isSelected
        }
        selectionBackground.isHidden = !highlighted
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        label.isEditable = false
        selectionBackground.isHidden = true
    }

    func beginEditing() {
        // The text field wraps lines the same way the display does: without this the
        // editor put a long name on ONE line and scrolled it sideways — the cell's look
        // changed beyond recognition during rename. .byWordWrapping (rather than the
        // display's truncating mode) is what allows the editor to wrap at all; a long
        // word without spaces it wraps by characters by itself.
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.usesSingleLineMode = false
        // Zero means no limit: while editing the whole name should be visible, and
        // the box height is chosen by updateEditingLabelHeight.
        label.maximumNumberOfLines = 0
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = Theme.current.fieldBackground
        raiseAboveNeighbours()
        updateEditingLabelHeight()
        view.window?.makeFirstResponder(label)
        // Select the base name without the extension (as Finder does), for
        // files.
        if let editor = label.currentEditor() {
            let name = label.stringValue as NSString
            let ext = name.pathExtension
            if !ext.isEmpty, name.length - ext.count - 1 > 0 {
                editor.selectedRange = NSRange(location: 0, length: name.length - ext.count - 1)
            }
        }
    }
}

private extension NSView {
    /// The nearest NSCollectionViewItem whose view contains this subview (for the field's
    /// delegate).
    var enclosingCollectionViewItem: NSCollectionViewItem? {
        var responder: NSResponder? = self
        while let r = responder {
            if let item = r as? NSCollectionViewItem { return item }
            responder = r.nextResponder
        }
        return nil
    }
}
