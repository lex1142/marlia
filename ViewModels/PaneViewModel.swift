import Foundation
import Combine

/// The state of one pane: current directory, items, selection, history.
@MainActor
final class PaneViewModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var currentURL: URL
    /// What's visible in the pane: the full listing minus the filter string. All three
    /// view modes read exactly this, so filtering works in all of them at once and none
    /// of them knows about it.
    @Published private(set) var items: [FileItem] = []
    /// The full listing as read. Kept apart from `items` because the filter
    /// must clear instantly, without re-reading the disk.
    private var allItems: [FileItem] = []
    /// The virtual "Recents" view (recent files, as in Finder): items come from
    /// RecentsStore rather than currentURL; currentURL doesn't change meanwhile
    /// (the last real folder — so the watcher/session/operations don't break). Any
    /// navigation (clicking a folder, ↑/←, the sidebar, typing a path) leaves the
    /// mode.
    @Published private(set) var recentsMode = false
    @Published var selection = Set<FileItem.ID>()
    @Published var showHidden = false { didSet { isSearching ? performSearch() : reload() } }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name, order: .forward)] {
        didSet {
            applySort()
            rememberSortForCurrentDirectory()
        }
    }
    @Published var viewMode: ViewMode = .list
    @Published private(set) var zoomLevel: CGFloat = 1.0
    @Published var errorMessage: String?

    /// Closing the search (the ×, ⌘F again, clicking the magnifier again — any route)
    /// must reset the query and bring back the normal directory listing, rather than
    /// leaving the previous search's results hanging in model.items after the bar is
    /// gone.
    @Published var isSearchBarVisible = false {
        didSet {
            if oldValue, !isSearchBarVisible {
                cancelSearch()
            }
        }
    }
    @Published var searchQuery = ""
    @Published var useRegexSearch = false

    /// The filter bar is NOT search. Search (above) walks the disk recursively and
    /// replaces the pane's contents with its results; the filter instantly narrows what
    /// has already been read and clears without touching the file system. So they have
    /// separate state and can be open at the same time: the filter narrows search
    /// results just the same.
    @Published var filterQuery = "" { didSet { guard oldValue != filterQuery else { return }; applyFilter() } }
    @Published var isFilterBarVisible = false {
        didSet {
            // Closing the bar clears the filter — otherwise the list would stay
            // trimmed without a single visible sign of why files had "disappeared"
            // from the folder.
            if oldValue, !isFilterBarVisible { filterQuery = "" }
        }
    }

    /// Free space on the current directory's volume. Updated together with the
    /// listing.
    @Published private(set) var freeSpace: Int64?
    /// true while the disk walk itself is running; false again once the results are in items.
    @Published private(set) var isSearching = false

    /// Whether search results are currently shown instead of the directory listing. This
    /// (rather than isSearching, which lives only for the duration of the walk) is what
    /// marks "items holds search results" — it decides whether reload() may overwrite
    /// them.
    var isShowingSearchResults: Bool {
        isSearchBarVisible && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A request to "start inline rename of this item" from OUTSIDE the view (the
    /// Rename item in the menu bar). Only PaneView can rename — it knows about the
    /// view modes — so this is just a request the view picks up and resets.
    @Published var renameRequest: FileItem.ID?
    @Published var isCreatingFolder = false
    @Published var newFolderName = "New Folder"
    @Published var isCreatingFile = false
    @Published var newFileName = "New File"

    @Published var groupBy: GroupField = .none { didSet { applySort() } }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    private var watcherDebounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }

    var selectedItems: [FileItem] { items.filter { selection.contains($0.id) } }

    /// Total size of the selection for the status bar. Folders aren't counted: their
    /// real weight needs a subtree walk, which is Get Info's job with its asynchronous
    /// count.
    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + ($1.isNavigableFolder ? 0 : $1.size) }
    }

    var selectionContainsFolders: Bool { selectedItems.contains(where: \.isNavigableFolder) }

    // MARK: Select by pattern

    /// What to do with what's already selected when selecting by pattern.
    enum PatternSelectionMode { case replace, add, subtract }

    /// Pattern selection in the style of two-pane managers: `*.jpg`, `report_??.pdf`.
    ///
    /// A pattern without a single wildcard is wrapped in asterisks and works as
    /// "contains": typing `jpg` and getting nothing is exactly the behavior that makes
    /// people stop using such dialogs.
    func selectMatching(pattern: String, mode: PatternSelectionMode = .replace) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let glob = trimmed.contains("*") || trimmed.contains("?") ? trimmed : "*\(trimmed)*"
        // NSPredicate's LIKE is a glob (* and ?), not a regular expression; we already have
        // regexes in search, and mixing two syntaxes in one field isn't worth it.
        let predicate = NSPredicate(format: "SELF LIKE[c] %@", glob)
        let matched = Set(items.filter { predicate.evaluate(with: $0.name) }.map(\.id))
        guard !matched.isEmpty || mode != .replace else { return }
        switch mode {
        case .replace: selection = matched
        case .add: selection.formUnion(matched)
        case .subtract: selection.subtract(matched)
        }
    }

    /// Inversion works on the visible list: with an active filter, "invert" only
    /// makes sense within what the person can see.
    func invertSelection() {
        selection = Set(items.map(\.id)).subtracting(selection)
    }

    /// Set while the sort is applied not by the user but by restoring from
    /// SortPreferencesStore — otherwise didSet would immediately write it back
    /// to disk.
    private var isApplyingStoredSort = false

    init(url: URL) {
        currentURL = url
        applyStoredSort(for: url)
        reload()
        startWatching()
    }

    /// Applies the sort remembered for this directory. If nothing was remembered for
    /// it, nothing is touched: the pane arrives in such a folder with its current
    /// sort, just as before this memory existed.
    private func applyStoredSort(for url: URL) {
        guard let stored = SortPreferencesStore.shared.sort(for: url) else { return }
        let comparator = stored.field.comparator(ascending: stored.ascending)
        guard sortOrder.first?.keyPath != comparator.keyPath || sortOrder.first?.order != comparator.order else { return }
        isApplyingStoredSort = true
        sortOrder = [comparator]
        isApplyingStoredSort = false
    }

    /// Remembers the chosen sort for the current directory. Not in Recents mode:
    /// currentURL there points to the last real folder, and its sort has nothing to do
    /// with the list of recent files.
    private func rememberSortForCurrentDirectory() {
        guard !isApplyingStoredSort, !recentsMode,
              let field = activeSortField, let order = sortOrder.first?.order else { return }
        SortPreferencesStore.shared.record(field: field, ascending: order == .forward, for: currentURL)
    }

    // MARK: Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        // In the virtual "Recents" mode currentURL stays the same (the last real
        // folder), so navigating even to that same folder has to work — hence the gate
        // on recentsMode.
        guard url != currentURL || recentsMode else { return }
        recentsMode = false
        if recordHistory {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = url
        selection.removeAll()
        // The bar stays open but its text is reset: a filter carried into a new folder
        // would show an almost empty list there for no obvious reason.
        if !filterQuery.isEmpty { filterQuery = "" }
        resetSearchState()
        // The new directory's sort is applied BEFORE reload(), otherwise the
        // list would first render in the old order and then immediately
        // rearrange.
        applyStoredSort(for: url)
        reload()
        startWatching()
    }

    func open(_ item: FileItem) {
        if item.isNavigableFolder {
            // resolvingSymlinksInPath is a no-op for ordinary paths; for a symlink (Workspace)
            // without it contentsOfDirectory on currentURL fails with ENOTDIR (see
            // FileItem.init).
            navigate(to: item.url.resolvingSymlinksInPath())
        } else if DiskImageOpener.isDiskImage(item.url) {
            // Like Finder: after mounting, show the disk image's window
            // (DiskImageOpener).
            DiskImageOpener.shared.open(item.url)
            RecentsStore.shared.add(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
            RecentsStore.shared.add(item.url) // "recent files" in the sidebar (see RecentsStore)
        }
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func goBack() {
        guard let url = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        navigate(to: url, recordHistory: false)
    }

    func goForward() {
        guard let url = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        navigate(to: url, recordHistory: false)
    }

    // MARK: Loading

    /// Show the virtual "Recents" view in this pane (from the sidebar). currentURL
    /// isn't touched — it stays the last real folder for leaving the
    /// mode/operations.
    func showRecents() {
        // Columns are built from the currentURL hierarchy — they don't suit a flat list of
        // recents; show it as a List (Icons would be fine too, but List is closer to
        // Finder's Recents).
        if viewMode == .columns { viewMode = .list }
        recentsMode = true
        selection.removeAll()
        resetSearchState()
        watcher = nil // recents aren't tied to a directory — nothing to watch
        reload()
    }

    /// Recent files (from the shared RecentsStore), most recent first — without
    /// applySort, to keep that order; vanished ones are dropped.
    private func reloadRecents() {
        let files = RecentsStore.shared.items.filter { FileManager.default.fileExists(atPath: $0.path) }
        setLoaded(files.compactMap(FileItem.init))
        if errorMessage != nil { errorMessage = nil }
    }

    func reload() {
        if recentsMode { reloadRecents(); return }
        // items holds search results — a directory listing would overwrite them.
        // Explicit reasons to reload (a file operation, ⌘R) refresh the results
        // themselves. The background watcher never gets here at all, see
        // scheduleWatcherReload().
        if isShowingSearchResults { performSearch(); return }
        do {
            // Not contentsOfDirectory directly: FileItem.contentURLs is the single
            // directory-reading entry point, and Finder's merge of /Applications with
            // /System/Applications lives there (see its comment).
            let urls = try FileItem.contentURLs(in: currentURL, includeHidden: showHidden)
            var newItems = urls.compactMap(FileItem.init)
            newItems.sort(by: isBefore)
            // De-dup: the recursive FSEvents stream on currentURL often fires for changes
            // deep in the subtree that don't affect the listing itself — then newItems is
            // identical to the current one, and reassigning @Published items would cause
            // an idle redraw of the whole pane (FileItem's == compares every field:
            // name/size/date/kind). Skip it. @Published sends objectWillChange even for an
            // equal value, so errorMessage too is reset only if it was actually set —
            // otherwise every background reload triggered a re-render (an open context
            // menu/submenu flickered).
            if errorMessage != nil { errorMessage = nil }
            setLoaded(newItems)
            updateFreeSpace()
        } catch {
            setLoaded([])
            errorMessage = error.localizedDescription
        }
    }

    /// The single door through which a read listing enters the pane. The de-dup moved
    /// here from reload(): what has to be compared is what's actually visible,
    /// otherwise a change in the filtered-out part would trigger an idle redraw.
    private func setLoaded(_ newItems: [FileItem]) {
        allItems = newItems
        applyFilter()
    }

    private func applyFilter() {
        let query = filterQuery.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty
            ? allItems
            : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // The selection is deliberately NOT pruned: items hidden by the filter
        // should come back selected once the filter is cleared. And operations
        // work through selectedItems anyway, which is computed from the visible
        // list.
        if visible != items { items = visible }
    }

    /// volumeAvailableCapacityForImportantUsage is the same number Finder shows: it
    /// accounts for purgeable storage, whereas the "raw" free space is usually
    /// noticeably smaller and disagrees with what the user sees in the system.
    private func updateFreeSpace() {
        let values = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let capacity = values?.volumeAvailableCapacityForImportantUsage
        if capacity != freeSpace { freeSpace = capacity }
    }

    /// "Group By" doesn't draw separate sections with headers (Table can't do that) —
    /// instead the grouping field is inserted as the first comparator before the regular
    /// sort, so items of one group simply end up next to each other.
    private func applySort() {
        allItems.sort(by: isBefore)
        applyFilter()
    }

    /// One ordering for reload (sorting a new listing before the de-dup) and applySort
    /// (re-sorting when sortOrder/groupBy change). Folders always on top, as in Total
    /// Commander; then the grouping field (if any) as the first comparator, then sortOrder.
    private func isBefore(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isNavigableFolder != b.isNavigableFolder { return a.isNavigableFolder }
        if let groupComparator = groupBy.comparator {
            switch groupComparator.compare(a, b) {
            case .orderedSame: break
            case .orderedAscending: return true
            case .orderedDescending: return false
            }
        }
        for comparator in sortOrder {
            switch comparator.compare(a, b) {
            case .orderedSame: continue
            case .orderedAscending: return true
            case .orderedDescending: return false
            }
        }
        return false
    }

    // MARK: Search (recursive from currentURL, plain substring or regexp)

    /// Live search — called on every searchQuery change. The actual disk walk
    /// (performSearch) starts only after a short pause following the last keystroke,
    /// so a full tree walk doesn't run for every character.
    func scheduleSearch() {
        searchDebounceTask?.cancel()
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancelSearch()
            return
        }
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }

    func performSearch() {
        searchDebounceTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            cancelSearch()
            return
        }

        var regex: NSRegularExpression?
        if useRegexSearch {
            do {
                regex = try NSRegularExpression(pattern: query, options: [.caseInsensitive])
            } catch {
                errorMessage = "Invalid regular expression: \(error.localizedDescription)"
                return
            }
        }

        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        let root = currentURL
        let includeHidden = showHidden

        // Task (not .detached) inherits the MainActor — the code before/after the await
        // below runs on the MainActor without a manual hop, and the heavy disk walk goes
        // to the background only for the duration of the await itself, thanks to
        // Self.search(...), which is isolated separately.
        searchTask = Task {
            let results = await Self.search(in: root, query: query, regex: regex, includeHidden: includeHidden)
            guard !Task.isCancelled else { return }
            setLoaded(results)
            applySort()
            isSearching = false
        }
    }

    private static func search(
        in root: URL, query: String, regex: NSRegularExpression?, includeHidden: Bool
    ) async -> [FileItem] {
        await Task.detached {
            var results: [FileItem] = []
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                let matches: Bool
                if let regex {
                    matches = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                } else {
                    matches = name.localizedCaseInsensitiveContains(query)
                }
                if matches, let item = FileItem(url: url) {
                    results.append(item)
                }
            }
            return results
        }.value
    }

    /// Close the search and return to the normal directory listing (the "×" button, clearing
    /// the query).
    func cancelSearch() {
        resetSearchState()
        reload()
    }

    /// Resets the search state without a reload — used during navigation, which
    /// calls reload() itself right after anyway.
    private func resetSearchState() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        searchQuery = ""
    }

    // MARK: Item zoom (⌘+ / ⌘− / ⌘0)

    static let minZoom: CGFloat = 0.6
    static let maxZoom: CGFloat = 2.2
    private static let zoomStep: CGFloat = 0.15

    /// Sort by field — the common entry point for the context menu and the menu
    /// bar.
    func setSort(_ field: SortField) { sortOrder = [field.comparator] }

    /// Which field the pane is currently sorted by (for the menu checkmark); nil if
    /// the sort was set by something non-standard (e.g. a column-header click in the
    /// reverse direction — then the field is the same but the direction differs).
    var activeSortField: SortField? {
        guard let first = sortOrder.first else { return nil }
        return SortField.allCases.first { $0.keyPath == first.keyPath }
    }

    func zoomIn() { zoomLevel = min(zoomLevel + Self.zoomStep, Self.maxZoom) }
    func zoomOut() { zoomLevel = max(zoomLevel - Self.zoomStep, Self.minZoom) }
    func resetZoom() { zoomLevel = 1.0 }

    // MARK: Watching for changes

    private func startWatching() {
        watcherDebounceTask?.cancel()
        watcher = DirectoryWatcher(url: currentURL) { [weak self] in
            Task { @MainActor in self?.scheduleWatcherReload() }
        }
    }

    /// FSEvents arrive in bursts (and recursively — from changes deep in the subtree),
    /// so they're coalesced into a single reload after a short pause, to avoid a full
    /// disk walk on every event. Explicit operations (copy/move/rename/create) call
    /// reload() directly, bypassing the debounce, so their result shows up immediately.
    private func scheduleWatcherReload() {
        // While search results are shown, items aren't touched at all. That was the
        // "results flashed and got reset" bug: the search's recursive walk itself
        // touches files (access metadata), FSEvents fires, and the deferred reload
        // replaced the results with the current directory's listing. Restarting the
        // search from here isn't an option either — its walk would trigger FSEvents
        // again, creating a self-sustaining loop.
        guard !isShowingSearchResults else { return }
        watcherDebounceTask?.cancel()
        watcherDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }
}

/// The pane's sort field. It lives here rather than privately in PaneView because
/// there's one source and two call sites: the pane's context menu and View ▸ Sort By in
/// the menu bar (while the enum was private to the view, the sort couldn't be moved
/// into the menu bar). A String rawValue because the sort field is also saved to disk
/// (see SortPreferencesStore): the numeric order of the cases won't do for that, it
/// would shift with any reordering.
enum SortField: String, CaseIterable {
    case name, modified, created, lastOpened, dateAdded, size, kind, tags

    var label: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .lastOpened: return "Date Last Opened"
        case .dateAdded: return "Date Added"
        case .size: return "Size"
        case .kind: return "Kind"
        case .tags: return "Tags"
        }
    }

    var keyPath: PartialKeyPath<FileItem> {
        switch self {
        case .name: return \FileItem.name
        case .modified: return \FileItem.modified
        case .created: return \FileItem.created
        case .lastOpened: return \FileItem.lastOpened
        case .dateAdded: return \FileItem.dateAdded
        case .size: return \FileItem.size
        case .kind: return \FileItem.kind
        case .tags: return \FileItem.tagsDisplay
        }
    }

    /// The default direction matches habitual behavior: name/kind/tags —
    /// alphabetical, size — largest first, dates — most recent first.
    var defaultAscending: Bool {
        switch self {
        case .name, .kind, .tags: return true
        case .size, .modified, .created, .lastOpened, .dateAdded: return false
        }
    }

    var comparator: KeyPathComparator<FileItem> { comparator(ascending: defaultAscending) }

    /// The direction is set explicitly: it's chosen not only by the menu (where it's the
    /// default) but also by a column-header click in List mode, which can invert the
    /// order — and a directory's remembered sort has to be able to reproduce that too.
    func comparator(ascending: Bool) -> KeyPathComparator<FileItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return KeyPathComparator(\FileItem.name, order: order)
        case .kind: return KeyPathComparator(\FileItem.kind, order: order)
        case .tags: return KeyPathComparator(\FileItem.tagsDisplay, order: order)
        case .size: return KeyPathComparator(\FileItem.size, order: order)
        case .modified: return KeyPathComparator(\FileItem.modified, order: order)
        case .created: return KeyPathComparator(\FileItem.created, order: order)
        case .lastOpened: return KeyPathComparator(\FileItem.lastOpened, order: order)
        case .dateAdded: return KeyPathComparator(\FileItem.dateAdded, order: order)
        }
    }
}

/// The "Group By" field — doesn't show separate sections, just clusters items of one
/// group next to each other (see the comment in applySort()).
enum GroupField: String, CaseIterable {
    case none, kind, size, modified

    var label: String {
        switch self {
        case .none: return "None"
        case .kind: return "Kind"
        case .size: return "Size"
        case .modified: return "Date Modified"
        }
    }

    var comparator: KeyPathComparator<FileItem>? {
        switch self {
        case .none: return nil
        case .kind: return KeyPathComparator(\FileItem.kind, order: .forward)
        case .size: return KeyPathComparator(\FileItem.size, order: .forward)
        case .modified: return KeyPathComparator(\FileItem.modified, order: .reverse)
        }
    }
}

import AppKit
