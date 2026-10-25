import SwiftUI
import UniformTypeIdentifiers

struct PaneView: View {
    @ObservedObject var model: PaneViewModel
    let side: AppState.PaneSide
    @EnvironmentObject var appState: AppState
    /// FavoritesStore is nested in AppState as a plain stored property (not @Published)
    /// — its own changes don't bubble up through AppState.objectWillChange, so
    /// @EnvironmentObject var appState by itself doesn't update when favorites.items
    /// changes (the star in the path bar didn't repaint, and a second click always went
    /// to add() again rather than remove(), because of a stale computed value in a view
    /// that hadn't redrawn). An explicit @ObservedObject on the FavoritesStore itself
    /// solves this the same way the Sidebar already works.
    @ObservedObject var favorites: FavoritesStore
    /// The app-wide file clipboard: the pane subscribes to it itself, because dimming
    /// of cut items has to update in ALL windows and tabs, not only where ⌘X was
    /// pressed (see FileClipboard).
    @ObservedObject var clipboard = FileClipboard.shared
    /// The theme is app-wide too. The subscription is needed for redrawing: a theme change
    /// must repaint the pane immediately, including the AppKit modes (they receive
    /// theme.generation, see themeGeneration in
    /// FileTableView/FileIconsView/ColumnTableView).
    @ObservedObject var theme = ThemeStore.shared

    /// The item currently being renamed inline (Icons/Columns: Text(item.name) is
    /// replaced with a TextField while renamingItem?.id == item.id). List mode manages
    /// its own editing field inside FileNSTableView (native AppKit inline editing, see
    /// FileTableView.swift) — it doesn't use renamingItem.
    @State var renamingItem: FileItem?
    @State var newName = ""
    @FocusState var renameFieldFocused: Bool
    /// A bridge to "start inline rename in the table" from outside the AppKit world
    /// — its only consumer is the "Rename…" context-menu item (clicking a name in
    /// the table itself talks to FileNSTableView directly, without this bridge). See
    /// editRequestID in FileTableView.swift.
    @State private var listEditRequestID: FileItem.ID?
    /// Like listEditRequestID, but for Icons mode (native AppKit as well — see
    /// FileIconsView): a bridge to "start inline rename" from the "Rename…"
    /// context-menu item.
    @State private var iconEditRequestID: FileItem.ID?
    /// Like listEditRequestID, but for Columns mode (the native ColumnTableView).
    @State var columnEditRequestID: FileItem.ID?
    @State var isEditingPath = false
    @State private var pathInput = ""
    @FocusState private var pathFieldFocused: Bool
    /// "Take focus into the field" counters for the search and filter bars. @FocusState
    /// doesn't work here — see FocusableTextField in PaneInteractionViews.swift.
    @State private var searchFocusTrigger = 0
    @State private var filterFocusTrigger = 0
    /// Grows when FileTableView (List mode) must force first responder back into
    /// the table — see focusRequestTrigger in FileTableView.swift.
    @State private var tableFocusTrigger = 0
    /// Grows on every item click in Icons/Columns — a reason to re-grab first responder
    /// (see focusRequestTrigger in FileIconsView/ColumnTableView), separate from isActive:
    /// clicking an already-active pane doesn't change isActive, but focus still has to come
    /// back.
    @State var keyFocusTrigger = 0
    @State private var pendingRenameWorkItem: DispatchWorkItem?
    /// Frames of the columns themselves (not rows) in "columnsContent"
    /// coordinates — for auto-scrolling to the active column
    /// (scrollToActiveColumn).
    @State var columnFrames: [URL: CGRect] = [:]
    /// The scrollToVisible driver of the Columns' horizontal ScrollView (see
    /// ColumnsScrollAnchor).
    @State var columnsScrollDriver = IconScrollDriver()
    /// Set when we need to scroll to a column whose frame isn't measured yet (just added)
    /// — .onPreferenceChange(ColumnFramesKey) finishes the scroll.
    @State var pendingColumnScroll: URL?
    /// The chain of columns from the disk root to the pane's current directory, cached
    /// in @State: recomputing it with disk reads on every click (selection) is what
    /// made Columns slow. Parent columns are re-read only when currentURL/showHidden
    /// change, while the last one simply mirrors model.items.
    @State var columnChain: [ColumnEntry] = []
    /// The preview column to the right of the active one: the contents of the folder
    /// selected in the active column, shown WITHOUT entering it (currentURL doesn't
    /// change). nil if a file, nothing or several items are selected. Not part of
    /// columnChain (so the last-column invariant isn't broken) — it's joined with the
    /// chain only for rendering (displayedColumns).
    @State var previewColumn: ColumnEntry?
    /// The cancellable preview-loading task — debounce + background disk read (see
    /// updatePreviewColumn). Kept so a newer selection change cancels a stale one.
    @State var previewLoadTask: Task<Void, Never>?
    /// Column widths (Columns mode) set by dragging a border. By column id; columns
    /// without one use columnDefaultWidth. Lives in @State (the session), while the last
    /// width is saved as the default (columnDefaultWidth) to survive a restart.
    @State var columnWidths: [URL: CGFloat] = [:]
    @AppStorage("Marlia.columnWidth") var columnDefaultWidth: Double = 220
    /// Visibility of List-mode columns — controlled from the "Show View Options" popover
    /// (Name is always visible). Global settings (@AppStorage), like Finder's "Use as
    /// Defaults". By default Size/Kind/Date Modified are visible (as before); the rest are
    /// hidden.
    @AppStorage("Marlia.col.modified") var showModifiedColumn: Bool = true
    @AppStorage("Marlia.col.created") var showCreatedColumn: Bool = false
    @AppStorage("Marlia.col.lastOpened") var showLastOpenedColumn: Bool = false
    @AppStorage("Marlia.col.dateAdded") var showDateAddedColumn: Bool = false
    @AppStorage("Marlia.col.size") var showSizeColumn: Bool = true
    @AppStorage("Marlia.col.kind") var showKindColumn: Bool = true
    @AppStorage("Marlia.col.tags") var showTagsColumn: Bool = false

    private var isActive: Bool { appState.activeSide == side }

    /// As in Finder: a (non-double) click on the already sole-selected item puts it into
    /// inline rename instead of just reselecting it. This used to show an .alert() popup
    /// with a TextField — replaced with in-place inline editing (everywhere, including
    /// List mode — see FileTableView.swift), because .alert() + TextField unreliably
    /// refreshed the displayed value when reopened for THE SAME file (SwiftUI didn't see
    /// a change in @State if the string didn't change) — moving to genuine in-place
    /// AppKit inline editing/SwiftUI TextField removes this class of bugs entirely
    /// rather than masking it with yet another delay.
    private func beginRename(_ item: FileItem) {
        switch model.viewMode {
        case .list:
            listEditRequestID = item.id
        case .icons:
            iconEditRequestID = item.id
        case .columns:
            columnEditRequestID = item.id
        }
    }

    func commitRename() {
        if let item = renamingItem, !newName.isEmpty, newName != item.name {
            appState.rename(item: item, to: newName, in: model)
        }
        renamingItem = nil
    }

    func cancelRename() {
        renamingItem = nil
    }

    /// Click-to-rename must not start right on the first click — otherwise a
    /// double-click on an already-selected item would read as a single click (the
    /// rename would start before the second click arrives). So it's deferred by
    /// doubleClickInterval and cancelled if a second click comes.
    func scheduleRename(for item: FileItem) {
        pendingRenameWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in beginRename(item) }
        pendingRenameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    func cancelPendingRename() {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
                .themedBackground(theme.palette.chromeBackground)
            Divider()
            if model.isSearchBarVisible {
                searchBar
                    .onAppear { searchFocusTrigger += 1 }
                    .themedBackground(theme.palette.chromeBackground)
                Divider()
            }
            if model.isFilterBarVisible {
                filterBar
                    .onAppear { filterFocusTrigger += 1 }
                    .themedBackground(theme.palette.chromeBackground)
                Divider()
            }
            content
                .themedBackground(theme.palette.paneBackground)
            Divider()
            statusBar
                .themedBackground(theme.palette.chromeBackground)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isActive ? Color(nsColor: theme.palette.accent) : .clear)
                .frame(height: 2)
        }
        .onTapGesture { appState.activate(side) }
        .onChange(of: isActive) { active in
            // The pane became active (Tab / click / any route) — explicitly ask the
            // current mode to take keyboard focus by bumping the focus triggers
            // (keyFocusTrigger for Icons/Columns, tableFocusTrigger for List). Relying on
            // the NSViews themselves reacting to becoming active turned out to be
            // unreliable for Tab. Only on the false→true transition, so focus isn't taken
            // away from inline rename/search.
            if active {
                keyFocusTrigger += 1
                tableFocusTrigger += 1
            }
        }
        // An explicit "focus the active pane" request (after a window/tab is created —
        // otherwise the AppKit split leaves first responder on the sidebar, and the arrows
        // navigate it rather than the files). The initial value (0) doesn't count — only real
        // bumps.
        .onChange(of: appState.paneFocusNonce) { _ in
            if isActive {
                keyFocusTrigger += 1
                tableFocusTrigger += 1
            }
        }
        // A rename requested from the menu bar: only this view can rename (it knows the
        // view mode), so the model just passes on the request and we clear it.
        .onChange(of: model.renameRequest) { id in
            guard let id, let item = model.items.first(where: { $0.id == id }) else { return }
            model.renameRequest = nil
            beginRename(item)
        }
        // A sheet rather than .alert+TextField: the alert's field didn't refresh on a
        // repeated call (the value "formally doesn't change" — the same problem that
        // drove rename to inline; resetting/reassigning didn't help). The sheet is
        // recreated every time it's shown, so the @State in NewItemSheet always starts
        // with the default name.
        .sheet(isPresented: $model.isCreatingFolder) {
            NewItemSheet(title: "New Folder", prompt: "Folder Name", defaultName: "New Folder") { name in
                // Close the sheet first: creating can raise an alert (no permission, error),
                // which shouldn't pop up on top of a sheet that is still open.
                model.isCreatingFolder = false
                DispatchQueue.main.async { appState.createFolder(named: name, in: model) }
            } onCancel: {
                model.isCreatingFolder = false
            }
        }
        .sheet(isPresented: $model.isCreatingFile) {
            NewItemSheet(title: "New File", prompt: "File Name", defaultName: "New File") { name in
                // Close the sheet first: creating can raise an alert (no permission, error),
                // which shouldn't pop up on top of a sheet that is still open.
                model.isCreatingFile = false
                DispatchQueue.main.async { appState.createFile(named: name, in: model) }
            } onCancel: {
                model.isCreatingFile = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.viewMode {
        case .list: fileTable
        case .icons: fileIcons
        case .columns: fileColumns
        }
    }

    // MARK: Path and navigation bar

    private var pathBar: some View {
        let isCurrentFolderFavorite = favorites.items.contains(model.currentURL)
        return HStack(spacing: 6) {
            // .help() sets a tooltip but NOT the element's name for VoiceOver: an
            // icon-only button has no name and is read as unnamed. So every icon
            // button here also has an accessibilityLabel.
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp)
                .help("Enclosing Folder")
                .accessibilityLabel("Enclosing Folder")

            if model.recentsMode {
                Label("Recents", systemImage: "clock")
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isEditingPath {
                TextField("Path", text: $pathInput)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($pathFieldFocused)
                    .onSubmit { submitPathEdit() }
                    .onExitCommand { isEditingPath = false }
                    .onAppear { pathFieldFocused = true }
                    .onChange(of: pathFieldFocused) { focused in
                        if !focused { isEditingPath = false }
                    }
            } else {
                breadcrumbPath
            }

            viewModePicker

            Button {
                openInTerminal(model.currentURL)
            } label: {
                Image(systemName: "terminal")
            }
            .help("Open in Terminal")
            .accessibilityLabel("Open in Terminal")

            Toggle(isOn: $model.showHidden) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .help("Show hidden files")
            .accessibilityLabel("Show hidden files")

            Button {
                if isCurrentFolderFavorite {
                    favorites.remove(model.currentURL)
                } else {
                    favorites.add(model.currentURL)
                }
            } label: {
                Image(systemName: isCurrentFolderFavorite ? "star.fill" : "star")
            }
            .help(isCurrentFolderFavorite ? "Remove current folder from Favorites" : "Add current folder to Favorites")
            .accessibilityLabel(isCurrentFolderFavorite ? "Remove from Favorites" : "Add to Favorites")

            Button {
                model.isSearchBarVisible.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Search in current directory (⌘F)")
            .accessibilityLabel("Search")
        }
        .buttonStyle(.borderless)
        .padding(6)
    }

    /// The view-mode switcher. The native segmented Picker paints the selected segment with
    /// the ACCENT COLOR FROM THE USER'S SYSTEM SETTINGS (pink, green — whatever was chosen)
    /// and doesn't obey the theme palette: it has no "segment color" property, and .tint has
    /// no effect on it. So for themes with their own palette we draw the switcher ourselves
    /// — three buttons with a fill under the selected one. The System theme gets the
    /// untouched native Picker: the same rule as for backgrounds (see ThemePalette.system).
    @ViewBuilder
    private var viewModePicker: some View {
        if theme.palette.isCustom {
            themedViewModePicker
        } else {
            Picker("View", selection: $model.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.symbolName)
                        .help(mode.help)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Display mode")
            .accessibilityLabel("Display mode")
        }
    }

    private var themedViewModePicker: some View {
        let palette = theme.palette
        return HStack(spacing: 2) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                let isSelected = model.viewMode == mode
                Button {
                    model.viewMode = mode
                } label: {
                    Image(systemName: mode.symbolName)
                        .frame(width: 30, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected ? Color(nsColor: palette.accent) : .clear)
                        )
                        // The icon color on the fill is chosen from the accent's luminance (see
                        // onAccent): light-purple Dracula needs a dark one, Solarized blue a light
                        // one.
                        .foregroundStyle(Color(nsColor: isSelected ? palette.onAccent : palette.label))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.help)
                .accessibilityLabel(mode.help)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: palette.paneBackground ?? .textBackgroundColor))
        )
        .frame(width: 110)
    }

    /// The path from the root to the current directory — each segment is a separate
    /// navigation button.
    private var pathSegments: [(name: String, url: URL)] {
        let workspacesRoot = WorkspaceStore.root.standardizedFileURL.path
        var result: [(name: String, url: URL)] = []
        var url = model.currentURL
        while url.pathComponents.count > 1 {
            // Inside iCloud Drive the crumbs start at "iCloud Drive", as in Finder, rather
            // than at /Users/…/Library/Mobile Documents/com~apple~CloudDocs.
            if ICloudDrive.isRoot(url) {
                result.append((name: ICloudDrive.name, url: url))
                return result.reversed()
            }
            result.append((name: url.lastPathComponent, url: url))
            // Inside the managed Workspaces folder, the long internal path leading to
            // it (~/Library/Application Support/...) isn't shown — the breadcrumbs
            // start right at the workspace's own name.
            if url.deletingLastPathComponent().standardizedFileURL.path == workspacesRoot {
                return result.reversed()
            }
            url = url.deletingLastPathComponent()
        }
        result.append((name: "/", url: url))
        return result.reversed()
    }

    /// Breadcrumbs: clicking a segment goes to that folder (including the root),
    /// while clicking the remaining empty space in the bar — as before — enables
    /// manual path editing (see .onTapGesture below and isEditingPath).
    private var breadcrumbPath: some View {
        HStack(spacing: 2) {
            let segments = pathSegments
            ForEach(Array(segments.enumerated()), id: \.element.url) { index, segment in
                // No separator right after the root "/" (it is one itself), but one after a
                // trimmed first crumb — a workspace or iCloud Drive.
                if index > 0 && segments[index - 1].name != "/" {
                    Text("/").foregroundStyle(.secondary)
                }
                Button {
                    appState.activate(side)
                    isEditingPath = false
                    model.navigate(to: segment.url)
                } label: {
                    Text(segment.name)
                }
                .buttonStyle(.plain)
                .help(segment.url.path)
            }
            Spacer(minLength: 8)
        }
        .lineLimit(1)
        .font(.system(.body, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.activate(side)
            pathInput = model.currentURL.path
            isEditingPath = true
        }
        .help("Click a folder to navigate there, or click empty space to type a path")
    }

    // MARK: Search

    /// Filtering the current list. Deliberately a separate bar rather than a mode inside
    /// search: search goes to the disk and changes the pane's contents, the filter is
    /// instant and reversible, and mixing them in one field would make it unclear what
    /// exactly is going to happen. Esc closes the filter first, then search. Returns
    /// false if there's nothing to close — then the view mode handles the key its own
    /// way.
    func handleEscape() -> Bool {
        if model.isFilterBarVisible { model.isFilterBarVisible = false; return true }
        if model.isSearchBarVisible { model.isSearchBarVisible = false; return true }
        return false
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            FocusableTextField(
                text: $model.filterQuery,
                placeholder: "Filter these items…",
                focusTrigger: filterFocusTrigger,
                onCancel: { model.isFilterBarVisible = false }
            )

            if !model.filterQuery.isEmpty {
                Text("\(model.items.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                model.isFilterBarVisible = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close filter")
            .accessibilityLabel("Close filter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            FocusableTextField(
                text: $model.searchQuery,
                placeholder: "Search in “\(model.currentURL.lastPathComponent)”…",
                focusTrigger: searchFocusTrigger,
                onSubmit: { model.performSearch() },
                onCancel: { model.isSearchBarVisible = false }
            )
            .onChange(of: model.searchQuery) { _ in model.scheduleSearch() }

            Toggle(".*", isOn: $model.useRegexSearch)
                .toggleStyle(.button)
                .help("Use regular expression")
                .accessibilityLabel("Use regular expression")

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                model.isSearchBarVisible = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close search")
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func submitPathEdit() {
        let expanded = (pathInput.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            model.errorMessage = "Folder not found: \(pathInput)"
            return
        }
        model.navigate(to: URL(fileURLWithPath: expanded).resolvingSymlinksInPath())
        isEditingPath = false
    }

    // MARK: List mode

    /// Replaces SwiftUI's Table with our own AppKit NSTableView (see FileTableView.swift) —
    /// dragging from any point of an already-selected row is required, not just from the
    /// small icon, which is fundamentally impossible with SwiftUI Table + .onDrag (see the
    /// history there). A side bonus: a click on empty space now activates the pane too —
    /// this used to be a "known limitation", since SwiftUI Table swallowed such a click
    /// entirely, while now we handle mouseDown ourselves (see onActivate below).
    private var fileTable: some View {
        FileTableView(
            items: model.items,
            selection: $model.selection,
            sortOrder: $model.sortOrder,
            visibleColumns: visibleColumns,
            zoomLevel: model.zoomLevel,
            currentDirectoryURL: model.currentURL,
            isCut: { appState.isCut($0) },
            cutURLs: clipboard.isCutPending ? clipboard.urls : [],
            themeGeneration: theme.generation,
            onActivate: {
                appState.activate(side)
                isEditingPath = false
            },
            onOpen: { item in
                appState.activate(side)
                cancelPendingRename()
                model.open(item)
            },
            onRenameCommit: { item, newName in
                guard !newName.isEmpty, newName != item.name else { return }
                appState.rename(item: item, to: newName, in: model)
            },
            onGoUp: { model.goUp() },
            onSwitchPane: { switchActivePaneIfPossible() },
            onEscape: { handleEscape() },
            onFocusPane: { toRight in
                // ← / → in List: activate the left/right pane. Only when both are visible
                // (otherwise there's nothing to switch). activate de-duplicates, so an
                // arrow toward the already-active side is a no-op.
                guard appState.showSecondPane else { return }
                let target: AppState.PaneSide = toRight ? .right : .left
                appState.activate(target)
                // Keyboard focus without a selection is useless: the pane highlights nothing
                // by itself, and the user has to press ↓ just to get to the first item. If
                // nothing is selected in the target pane, select the first item.
                let pane = target == .left ? appState.leftPane : appState.rightPane
                if pane.selection.isEmpty, let first = pane.items.first {
                    pane.selection = [first.id]
                }
            },
            buildContextMenu: { items in contextNSMenu(for: items) },
            onDrop: { urls, destination in acceptTableDrop(urls: urls, destination: destination) },
            focusRequestTrigger: tableFocusTrigger,
            editRequestID: listEditRequestID,
            onEditRequestHandled: { listEditRequestID = nil }
        )
        .onChange(of: model.selection) { _ in
            // The selection changed to something else — a deferred rename from a
            // previous click on a name is no longer relevant (otherwise it could pop
            // up on an item the user stopped selecting long ago).
            cancelPendingRename()
        }
        // Closing the search (× / ⌘F again / clicking the magnifier again)
        // removes the TextField from the hierarchy, but first responder doesn't
        // move anywhere by itself — without this, keyboard navigation in the
        // table stopped working until an item was clicked by hand.
        .onChange(of: model.isSearchBarVisible) { visible in
            if !visible { tableFocusTrigger += 1 }
        }
        .onChange(of: model.isFilterBarVisible) { visible in
            if !visible { tableFocusTrigger += 1 }
        }
    }

    /// Visible table columns (Name always). Assembled from the @AppStorage
    /// toggles.
    private var visibleColumns: Set<FileTableColumn> {
        var cols: Set<FileTableColumn> = [.name]
        if showModifiedColumn { cols.insert(.modified) }
        if showCreatedColumn { cols.insert(.created) }
        if showLastOpenedColumn { cols.insert(.lastOpened) }
        if showDateAddedColumn { cols.insert(.dateAdded) }
        if showSizeColumn { cols.insert(.size) }
        if showKindColumn { cols.insert(.kind) }
        if showTagsColumn { cols.insert(.tags) }
        return cols
    }

    private func isColumnVisible(_ column: FileTableColumn) -> Bool {
        switch column {
        case .modified: return showModifiedColumn
        case .created: return showCreatedColumn
        case .lastOpened: return showLastOpenedColumn
        case .dateAdded: return showDateAddedColumn
        case .size: return showSizeColumn
        case .kind: return showKindColumn
        case .tags: return showTagsColumn
        case .name: return true // Name can't be hidden
        }
    }

    private func toggleColumn(_ column: FileTableColumn) {
        switch column {
        case .modified: showModifiedColumn.toggle()
        case .created: showCreatedColumn.toggle()
        case .lastOpened: showLastOpenedColumn.toggle()
        case .dateAdded: showDateAddedColumn.toggle()
        case .size: showSizeColumn.toggle()
        case .kind: showKindColumn.toggle()
        case .tags: showTagsColumn.toggle()
        case .name: break
        }
    }

    /// Like acceptDrop(_:destination:), but for FileTableView: there the drop already
    /// provides a ready list of URLs synchronously (via NSPasteboard) rather than one
    /// asynchronous NSItemProvider per file — so several files dragged in from outside
    /// go in one transfer() call rather than N separate ones (a single undo/conflict
    /// dialog for the whole drop rather than one per file).
    @discardableResult
    func acceptTableDrop(urls: [URL], destination: URL) -> Bool {
        let items = urls.compactMap(FileItem.init)
        guard !items.isEmpty else { return false }
        appState.transfer(items: items, to: destination, mode: .move) {
            model.reload()
        }
        return true
    }

    // MARK: Icons mode

    /// Icons mode is a native NSCollectionView (see FileIconsView). It used to be a
    /// SwiftUI LazyVGrid; it moved to AppKit for the same reason as List: SwiftUI
    /// re-evaluated every cell on each selection step (measured), and navigation felt
    /// like jelly.
    private var fileIcons: some View {
        FileIconsView(
            items: model.items,
            selection: $model.selection,
            zoomLevel: model.zoomLevel,
            currentDirectoryURL: model.currentURL,
            isCut: { appState.isCut($0) },
            cutURLs: clipboard.isCutPending ? clipboard.urls : [],
            themeGeneration: theme.generation,
            onActivate: {
                appState.activate(side)
                isEditingPath = false
            },
            onOpen: { item in
                appState.activate(side)
                model.open(item)
            },
            onRenameCommit: { item, newName in
                guard !newName.isEmpty, newName != item.name else { return }
                appState.rename(item: item, to: newName, in: model)
            },
            onGoUp: { model.goUp() },
            onSwitchPane: { switchActivePaneIfPossible() },
            onEscape: { handleEscape() },
            buildContextMenu: { items in contextNSMenu(for: items) },
            onDrop: { urls, destination in acceptTableDrop(urls: urls, destination: destination) },
            focusRequestTrigger: keyFocusTrigger,
            editRequestID: iconEditRequestID,
            onEditRequestHandled: { iconEditRequestID = nil }
        )
        .onChange(of: model.isSearchBarVisible) { visible in
            if !visible { keyFocusTrigger += 1 }
        }
        .onChange(of: model.isFilterBarVisible) { visible in
            if !visible { keyFocusTrigger += 1 }
        }
    }

    // MARK: Columns mode — see PaneView+Columns.swift

    func openSelected() {
        guard let id = model.selection.first, let item = model.items.first(where: { $0.id == id }) else { return }
        model.open(item)
    }

    /// → in Columns: enters the selected folder (including an EMPTY one — then an
    /// empty column opens on the right, showing the folder is empty) and, if there's
    /// anything inside, selects the first item so there's focus and ↑/↓ continue from
    /// there. On a file — a no-op.
    func enterSelectedFolder() {
        guard let id = model.selection.first,
              let item = model.items.first(where: { $0.id == id }),
              item.isNavigableFolder else { return }
        let resolved = item.url.resolvingSymlinksInPath()
        // An empty folder is NOT opened with →: its (empty) contents are already
        // shown by the preview column on selection, and entering would leave focus in
        // an empty column (there's nowhere to move inside). Entering an empty folder
        // to work in it is done by double-click.
        let contents = FileItem.loadItems(in: resolved, includeHidden: model.showHidden)
        guard !contents.isEmpty else { return }
        model.navigate(to: resolved)
        if let first = model.items.first { model.selection = [first.id] }
        keyFocusTrigger += 1  // the new active column has to take first responder (for ↑↓)
    }

    /// ← in Columns: goes up to the parent column and selects in it the folder we just
    /// left (symmetric to enterSelectedFolder) — otherwise goUp clears the selection and
    /// the parent column is left without focus. Auto-scroll to the parent column goes
    /// through onChange(currentURL) → scrollToActiveColumn (a minimal shift).
    func goToParentColumn() {
        guard model.canGoUp else { return }
        let leaving = model.currentURL.resolvingSymlinksInPath().standardizedFileURL
        let leavingItems = model.items // the contents of the folder being left are already loaded
        model.goUp()
        guard let item = model.items.first(where: {
            $0.url.resolvingSymlinksInPath().standardizedFileURL == leaving
        }) else { return }
        model.selection = [item.id]
        keyFocusTrigger += 1  // the parent column (now active) takes first responder
        // Show the contents of the folder we left as a preview RIGHT AWAY, from data we
        // already have — no async load and no column flicker. The id is computed the same
        // way as in updatePreviewColumn (item.url.resolvingSymlinksInPath()), so that it
        // then sees the same id and does NOT re-read the folder.
        setPreview(ColumnEntry(id: item.url.resolvingSymlinksInPath(), items: leavingItems, selectedChildURL: nil))
    }

    /// Tab switches the active pane only while both panes are visible — in
    /// single-pane mode there's nothing to switch, so simply do nothing (the key
    /// still counts as "handled" so it doesn't fall through to the default
    /// tabbing across the window's controls).
    func switchActivePaneIfPossible() {
        guard appState.showSecondPane else { return }
        appState.toggleActivePane()
    }

    // MARK: Context menu (shared by all view modes)

    /// The context menu as a native NSMenu (rather than SwiftUI + NSHostingMenu, which
    /// required macOS 14.4 at minimum). Rebuilt from scratch on every right-click —
    /// state (sort/tag/column checkmarks) is computed right here, no live updates
    /// needed. Items are ClosureMenuItems (closure actions). One source for all three
    /// modes and for the empty area (items is empty).
    func contextNSMenu(for items: [FileItem]) -> NSMenu {
        let menu = newMenu()
        if let first = items.first {
            menu.addItem(menuItem("Open", "arrow.up.forward.app") { model.open(first) })
            menu.addItem(menuItem("Quick Look", "eye") { QuickLookCoordinator.shared.toggle(urls: items.map(\.url)) })
            if items.count == 1, !first.isNavigableFolder {
                // Resolved: like the other Launch Services calls, these don't follow a
                // symlink, and a link's own type isn't the type of the file it points at.
                let target = first.url.resolvingSymlinksInPath()
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: target)
                // Finder order: the default app first, marked "(default)", then the rest.
                var apps = NSWorkspace.shared.urlsForApplications(toOpen: target)
                if let defaultApp {
                    apps.removeAll { $0.standardizedFileURL == defaultApp.standardizedFileURL }
                    apps.insert(defaultApp, at: 0)
                }
                let openWith = newMenu()
                for appURL in apps {
                    var title = FileManager.default.displayName(atPath: appURL.path)
                    if appURL == defaultApp { title += " (default)" }
                    let item = ClosureMenuItem(title: title) {
                        NSWorkspace.shared.open([first.url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    openWith.addItem(item)
                    if appURL == defaultApp, apps.count > 1 { openWith.addItem(.separator()) }
                }
                if !apps.isEmpty { openWith.addItem(.separator()) }
                openWith.addItem(menuItem("Other…", "ellipsis.circle") { openWithOtherApplication(first.url) })
                addSubmenu(menu, "Open With", "square.grid.2x2", openWith)
            }
            menu.addItem(menuItem("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) })
            menu.addItem(menuItem("AirDrop…", "wifi") { appState.airDrop(items) })
            if items.count == 1, first.isNavigableFolder {
                menu.addItem(menuItem("Add to Favorites", "star") { favorites.add(first.url) })
            }
            let workspaceMenu = newMenu()
            for ws in WorkspaceStore.shared.workspaces {
                workspaceMenu.addItem(menuItem(ws.lastPathComponent, "folder") { WorkspaceStore.shared.add(items, to: ws) })
            }
            if !WorkspaceStore.shared.workspaces.isEmpty { workspaceMenu.addItem(.separator()) }
            workspaceMenu.addItem(menuItem("New Workspace…", "plus.circle") { WorkspaceStore.shared.beginCreatingWorkspace(for: items) })
            addSubmenu(menu, "Add to Workspace", "square.stack.3d.up", workspaceMenu)

            let tagMenu = newMenu()
            for tag in Self.tagColors {
                tagMenu.addItem(tagNSMenuItem(tag, for: items, reference: first))
            }
            tagMenu.addItem(.separator())
            tagMenu.addItem(menuItem("Clear Tags", "tag.slash") { for item in items { setTags([], on: item) } })
            addSubmenu(menu, "Tags", "tag", tagMenu)

            menu.addItem(.separator())
            menu.addItem(menuItem("Copy", "doc.on.doc") { appState.copySelection(items) })
            menu.addItem(menuItem("Cut", "scissors") { appState.cutSelection(items) })
            menu.addItem(menuItem("Duplicate", "plus.square.on.square") { appState.duplicate(items: items, in: model) })
            menu.addItem(menuItem("Compress…", "archivebox") { appState.compress(items: items, in: model) })
            menu.addItem(.separator())
            menu.addItem(menuItem("Rename", "pencil") { beginRename(first) })
            // Batch rename only when there's something to batch: for a single file inline
            // rename is faster and already at hand one line above.
            if items.count > 1 {
                menu.addItem(menuItem("Rename Multiple…", "textformat.abc") {
                    appState.activate(side)
                    model.selection = Set(items.map(\.id))
                    appState.beginBatchRename()
                })
            }
            menu.addItem(menuItem("Copy Path", "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(first.url.path, forType: .string)
            })
            if items.count == 1 {
                menu.addItem(menuItem("Get Info", "info.circle") { AppWindowManager.shared.openGetInfo(first.url) })
                if ArchiveFormat(url: first.url) != nil {
                    menu.addItem(menuItem("Extract", "arrow.up.left.and.arrow.down.right") { appState.extractArchive(item: first, in: model) })
                    menu.addItem(menuItem("View Contents", "list.bullet") { AppWindowManager.shared.openArchiveContents(first.url) })
                }
                menu.addItem(menuItem("Open in Terminal", "terminal") {
                    openInTerminal(first.isNavigableFolder ? first.url : first.url.deletingLastPathComponent())
                })
            }
            menu.addItem(.separator())
            if WorkspaceStore.isWorkspaceFolder(model.currentURL) {
                // Inside a workspace the items are symlinks; deleting removes only the link
                // (the original is intact), so the action is named honestly. One item is
                // enough: Trash and Delete would do the same thing here — remove the link.
                // Trash leaves the link in the Trash (recoverable) and doesn't touch the
                // original.
                menu.addItem(menuItem("Remove from Workspace", "minus.circle") { appState.trash(items: items, from: model) })
            } else {
                menu.addItem(menuItem("Move to Trash", "trash") { appState.trash(items: items, from: model) })
                menu.addItem(menuItem("Delete Immediately…", "trash.slash") { appState.deletePermanently(items: items, from: model) })
            }
        } else {
            menu.addItem(menuItem("Paste", "doc.on.clipboard") { appState.paste(into: model) })
            menu.addItem(.separator())

            // The sort/group/column submenus deliberately have NO icons: they're choice
            // lists where the value is carried by the checkmark (state = .on), and
            // there's no meaningful icon for "Date Modified" versus "Date Created"
            // anyway — the result would be a row of identical pictures distracting from
            // the one thing that matters there.
            let sortMenu = newMenu()
            for field in SortField.allCases {
                let item = ClosureMenuItem(title: field.label) { setSort(field) }
                item.state = isActiveSort(field) ? .on : .off
                sortMenu.addItem(item)
            }
            addSubmenu(menu, "Sort By", "arrow.up.arrow.down", sortMenu)

            let groupMenu = newMenu()
            for field in GroupField.allCases {
                let item = ClosureMenuItem(title: field.label) { model.groupBy = field }
                item.state = model.groupBy == field ? .on : .off
                groupMenu.addItem(item)
            }
            addSubmenu(menu, "Group By", "list.bullet.indent", groupMenu)

            if model.viewMode == .list {
                let columnsMenu = newMenu()
                for column in FileTableColumn.optional {
                    let item = ClosureMenuItem(title: column.title) { toggleColumn(column) }
                    item.state = isColumnVisible(column) ? .on : .off
                    columnsMenu.addItem(item)
                }
                addSubmenu(menu, "Show Columns", "tablecells", columnsMenu)
            }

            menu.addItem(.separator())
            // async: the item fires inside AppKit menu tracking; presenting the sheet
            // is scheduled for the next main-runloop tick, once tracking has
            // finished.
            menu.addItem(menuItem("New Folder", "folder.badge.plus") {
                DispatchQueue.main.async { model.isCreatingFolder = true }
            })
            menu.addItem(menuItem("New File", "doc.badge.plus") {
                DispatchQueue.main.async { model.isCreatingFile = true }
            })
            menu.addItem(menuItem("Open in Terminal", "terminal") { openInTerminal(model.currentURL) })
            menu.addItem(menuItem("Refresh", "arrow.clockwise") { model.reload() })
        }
        return menu
    }

    /// Open With ▸ Other…: pick any application, Finder-style. The "Always Open With"
    /// checkbox also makes it the system default for this file's content type (the
    /// same Launch Services setting as Finder's Get Info ▸ "Change All…"), so it
    /// applies to every file of that type, not just this one.
    private func openWithOtherApplication(_ url: URL) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Choose an application to open “\(url.lastPathComponent)”."
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Without this an .app is browsed into like a folder instead of chosen.
        panel.treatsFilePackagesAsDirectories = false

        let alwaysCheckbox = NSButton(checkboxWithTitle: "Always Open With", target: nil, action: nil)
        alwaysCheckbox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: alwaysCheckbox.frame.width + 40, height: alwaysCheckbox.frame.height + 16))
        alwaysCheckbox.frame.origin = NSPoint(x: 20, y: 8)
        accessory.addSubview(alwaysCheckbox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        if alwaysCheckbox.state == .on,
           let type = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentTypeKey]).contentType {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                guard let error else { return }
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// An NSMenu with autoenablesItems = false — ClosureMenuItems are their own
    /// target; auto-validation (which could disable them) is turned off.
    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    /// A menu item with an icon. EVERY item has an icon, and not for looks: AppKit
    /// reserves space for an image only in rows that have one, so a menu where only some
    /// items have icons looks misaligned — the titles start at two different indents.
    /// Hence the rule: either all items in a menu have icons, or none do.
    private func menuItem(_ title: String, _ symbol: String, action: @escaping () -> Void) -> ClosureMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        item.image = Self.menuSymbol(symbol)
        return item
    }

    /// An SF Symbol sized for a menu row. isTemplate — so the system recolors it itself
    /// for the theme and for the selected-row highlight (a color image would be left as
    /// is and become unreadable on the blue highlight). The symbol may be missing on
    /// macOS 13 — then nil, and the item simply has no icon.
    private static func menuSymbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func addSubmenu(_ menu: NSMenu, _ title: String, _ symbol: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = Self.menuSymbol(symbol)
        item.submenu = submenu
        menu.addItem(item)
    }

    // MARK: Finder color tags (com.apple.metadata / URLResourceValues.tagNames)

    private static let tagColors: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]

    /// SwiftUI renders SF Symbols inside a context menu as a template icon — AppKit
    /// recolors it to the system's mono color, and .foregroundStyle is ignored. A
    /// bitmap NSImage with isTemplate = false isn't affected and keeps its color.
    private static func colorDotImage(_ color: NSColor, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func currentTags(for url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    private func setTags(_ tags: [String], on item: FileItem) {
        // Via the NSURL API rather than URLResourceValues.tagNames: the latter's setter is
        // marked @available(macOS 26+) in the fresh SDK, which broke builds with the 14
        // deployment target (and CI on macos-14). The Obj-C bridge
        // setResourceValue(_:forKey:) carries no such restriction and works from macOS
        // 10.6.
        try? (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// The color dot is an image, the "applied" checkmark the native state (.on).
    /// The checkbox goes by the first (reference) item — with different tag sets
    /// across several selected items it's an approximation, not an exact
    /// calculation.
    private func tagNSMenuItem(_ tag: (name: String, color: NSColor), for items: [FileItem], reference: FileItem) -> NSMenuItem {
        let isTagged = currentTags(for: reference.url).contains(tag.name)
        let item = ClosureMenuItem(title: tag.name) {
            for fileItem in items {
                var tags = currentTags(for: fileItem.url)
                if isTagged {
                    tags.removeAll { $0 == tag.name }
                } else if !tags.contains(tag.name) {
                    tags.append(tag.name)
                }
                setTags(tags, on: fileItem)
            }
        }
        item.image = Self.colorDotImage(tag.color)
        item.state = isTagged ? .on : .off
        return item
    }

    /// The sort and its current field live in PaneViewModel (SortField too) —
    /// otherwise the same thing would have to be duplicated for View ▸ Sort By in
    /// the menu bar.
    private func setSort(_ field: SortField) { model.setSort(field) }

    private func isActiveSort(_ field: SortField) -> Bool { model.activeSortField == field }

    private func openInTerminal(_ url: URL) { AppState.openInTerminal(url) }

    // MARK: Drag-and-drop (between panes, windows and tabs — goes through the system pasteboard)

    /// The outer SwiftUI .onDrop of the Columns container (a drop not over a specific row
    /// — into the current directory itself). Rows/columns drop through the native
    /// ColumnTableView; this is the fallback for the empty area around them.
    ///
    /// Returns true if at least one provider could be read as a file URL — used as the
    /// return value of onDrop so SwiftUI shows the correct cursor/target highlight.
    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider], destination: URL) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let item = FileItem(url: url) else { return }
                DispatchQueue.main.async {
                    appState.transfer(items: [item], to: destination, mode: .move) {
                        model.reload()
                    }
                }
            }
        }
        return true
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Color(nsColor: theme.palette.error))
            } else {
                Text("\(model.items.count) items")
                if !model.selection.isEmpty {
                    // Folder sizes aren't included in the total — that needs a
                    // subtree walk. This is stated explicitly, otherwise the number
                    // would simply look wrong.
                    let size = ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file)
                    let suffix = model.selectionContainsFolders ? " (folders not counted)" : ""
                    Text("· selected: \(model.selection.count) · \(size)\(suffix)")
                }
            }
            Spacer()
            if let free = model.freeSpace {
                Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// The sheet for creating a new item (folder/file). Replaced .alert+TextField, whose
/// field didn't refresh on a repeated call (see the history of rename moving to inline).
/// The sheet is recreated every time it's shown, so the @State name always starts from
/// the default.
struct NewItemSheet: View {
    let title: String
    let prompt: String
    @State private var name: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    init(title: String, prompt: String, defaultName: String,
         onCreate: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.prompt = prompt
        _name = State(initialValue: defaultName)
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(prompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}
