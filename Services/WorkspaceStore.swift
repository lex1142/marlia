import Foundation

/// A "Workspace" is an app-managed folder of symbolic links to files/folders from
/// arbitrary places (the files themselves are never copied or moved). Opening a
/// workspace in a pane is plain navigation into that folder: all the existing
/// browsing/sorting/context-menu/operation logic works without a single change, because
/// FileManager resolves symlinks transparently when reading (isDirectory,
/// contentsOfDirectory etc. reflect the link's target), while operations like
/// trash/rename/move act on the link itself, not its target — so "remove from
/// workspace" by itself means "just remove the link", nothing more is needed.
///
/// An app-wide singleton (as before) — one set of workspaces regardless of how many
/// windows are open.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [URL] = []
    /// The target of a "quick" add (the shortcut, a drop without a specific
    /// target) — the most recently created/used workspace.
    @Published private(set) var lastUsedWorkspace: URL?

    /// State of the new-workspace dialog (see the alert in ContentView.swift) — the
    /// items it was requested for (may be empty — just "New Workspace").
    @Published var pendingNewWorkspaceItems: [FileItem]?
    @Published var newWorkspaceName = "Workspace"

    /// State of the rename dialog (see the alert in ContentView.swift).
    @Published var renamingWorkspace: URL?
    @Published var renameWorkspaceName = ""

    /// Message about items that were already added (by link target) — see the alert in
    /// ContentView.swift.
    @Published var duplicateAlertMessage: String?

    static let root: URL = {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Marlia/Workspaces")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// true if url is the Workspaces folder itself or anything inside it (in
    /// particular, any specific workspace folder). Used so AppState.transfer(...) can
    /// redirect a regular copy/move/drag with such a target to
    /// WorkspaceStore.add(_:to:) instead of actually copying files into the workspace.
    static func isWorkspaceFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private init() {
        refresh()
    }

    func refresh() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        workspaces = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    @discardableResult
    func createWorkspace(named name: String) -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // The name comes from a text field: "/" or ".." would take the workspace
        // folder outside Application Support (see
        // FileOperationService.isValidItemName) — so silently use the default name,
        // same as for an empty one.
        let base = FileOperationService.isValidItemName(trimmed) ? trimmed : "Workspace"
        let url = FileOperationService.uniqueURL(for: Self.root.appendingPathComponent(base))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        refresh()
        lastUsedWorkspace = url
        return url
    }

    func deleteWorkspace(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if lastUsedWorkspace == url { lastUsedWorkspace = nil }
        refresh()
    }

    func rename(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard FileOperationService.isValidItemName(trimmed) else { return }
        let destination = FileOperationService.uniqueURL(for: url.deletingLastPathComponent().appendingPathComponent(trimmed))
        try? FileManager.default.moveItem(at: url, to: destination)
        if lastUsedWorkspace == url { lastUsedWorkspace = destination }
        refresh()
    }

    /// Creates symbolic links inside the workspace folder — the originals are
    /// untouched. If this workspace already has a link to the same target, it isn't
    /// duplicated; instead a count of skipped items is accumulated for a warning
    /// afterwards (see duplicateAlertMessage).
    func add(_ items: [FileItem], to workspace: URL) {
        let existingTargets = Set(existingLinkTargets(in: workspace))
        var skipped = 0
        for item in items {
            let target = item.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !existingTargets.contains(target) else {
                skipped += 1
                continue
            }
            let linkURL = FileOperationService.uniqueURL(for: workspace.appendingPathComponent(item.name))
            try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: item.url)
        }
        lastUsedWorkspace = workspace
        if skipped > 0 {
            let name = workspace.lastPathComponent
            duplicateAlertMessage = skipped == 1
                ? "This item is already in “\(name)”."
                : "\(skipped) items are already in “\(name)”."
        }
    }

    private func existingLinkTargets(in workspace: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
    }

    /// Quick add (the ⇧⌘↩ shortcut, a drop on the section without a specific target) — into
    /// the most recently used workspace, creating a default one without asking for a name if
    /// none exist yet.
    func addToDefaultWorkspace(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let target = lastUsedWorkspace ?? workspaces.first ?? createWorkspace(named: "Workspace")
        add(items, to: target)
    }

    func beginCreatingWorkspace(for items: [FileItem] = []) {
        newWorkspaceName = "Workspace"
        pendingNewWorkspaceItems = items
    }

    func confirmCreateWorkspace() {
        guard let items = pendingNewWorkspaceItems else { return }
        let workspace = createWorkspace(named: newWorkspaceName)
        if !items.isEmpty {
            add(items, to: workspace)
        }
        pendingNewWorkspaceItems = nil
    }

    func beginRenaming(_ url: URL) {
        renamingWorkspace = url
        renameWorkspaceName = url.lastPathComponent
    }

    func confirmRename() {
        guard let url = renamingWorkspace else { return }
        rename(url, to: renameWorkspaceName)
        renamingWorkspace = nil
    }
}
