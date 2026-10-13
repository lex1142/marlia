import SwiftUI

/// The sidebar as a separate SwiftUI view — hosted in the sidebar item of
/// `MarliaSplitViewController` (it used to be the left column of a SwiftUI
/// `NavigationSplitView`, which broke the sidebar's width/resizing inside an AppKit window).
/// Its parameters are derived from AppState.
struct SidebarHostView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        SidebarView(
            favorites: appState.favorites,
            currentDirectoryURL: appState.activeDirectoryURL,
            // After navigating from the sidebar, always return keyboard focus to the
            // active pane — the arrows should move through files, not the sidebar.
            onNavigate: { url in appState.activePane.navigate(to: url); appState.focusActivePane() },
            onAirDrop: { appState.airDropSelection() },
            canAirDrop: appState.activeHasSelection,
            onShowRecents: { appState.activePane.showRecents(); appState.focusActivePane() },
            isRecentsActive: appState.activeRecentsMode,
            isConnectPresented: $appState.isConnectingToServer
        )
    }
}

/// The window content: both panes + the HUD of active operations + all sheets/alerts. Hosted in
/// the main item of `MarliaSplitViewController`. The toolbar and window title are set by AppKit
/// (`MarliaWindowController`); the sidebar is a separate split item (`SidebarHostView`).
///
/// IMPORTANT: we don't hold an @ObservedObject on the panes themselves — the title/sidebar use
/// only three derived, de-duplicated values on AppState
/// (activeDirectoryURL/activeHasSelection/activeRecentsMode); otherwise an arrow-key selection
/// step would redraw the whole window and both panes.
struct PanesRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var workspace = WorkspaceStore.shared
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        content
            .environmentObject(appState)
            // The theme accent for SwiftUI system controls: the "hidden files"/regexp
            // toggles, checkboxes in sheets, the ProgressView in the operations HUD. Set at
            // the content root rather than in each pane — that way the HUD and the sheets
            // get it too (they inherit the environment). The view-mode switcher isn't
            // covered — it draws itself.
            .themedTint(theme.palette)
    }

    private var content: some View {
        paneContent
            .background(QuickLookKeyCatcher(appState: appState))
            .overlay(alignment: .bottomTrailing) {
                if !appState.activeOperations.isEmpty { operationsOverlay }
            }
            .sheet(item: $appState.pendingBatchRename) { pending in
                BatchRenameView(
                    items: pending.items,
                    // Only names that DON'T take part in the rename are checked
                    // for being taken: a name freed by another selected file isn't
                    // a conflict — the rename runs in two phases.
                    existingNames: Set(pending.pane.items.map(\.name))
                        .subtracting(pending.items.map(\.name))
                ) { plan in
                    appState.applyBatchRename(plan, in: pending.pane)
                } onCancel: {
                    appState.pendingBatchRename = nil
                }
            }
            .sheet(isPresented: $appState.isSelectingByPattern) {
                NewItemSheet(
                    title: "Select by Pattern",
                    prompt: "Pattern (for example *.jpg)",
                    defaultName: "*"
                ) { pattern in
                    appState.applyPatternSelection(pattern)
                } onCancel: {
                    appState.isSelectingByPattern = false
                }
            }
            .sheet(item: $appState.activeConflict) { conflict in
                ConflictResolutionView(conflict: conflict) { action, applyToAll in
                    appState.resolveConflict(action, applyToAll: applyToAll)
                }
            }
            .alert(item: $appState.pendingPermanentDelete) { pending in
                let names = pending.items.map(\.name).joined(separator: ", ")
                return Alert(
                    title: Text(pending.items.count == 1 ? "Delete “\(pending.items[0].name)” Immediately?" : "Delete \(pending.items.count) Items Immediately?"),
                    message: Text("\(names)\n\nThis item will be deleted immediately. You can't undo this action."),
                    primaryButton: .destructive(Text("Delete")) { appState.confirmPermanentDelete() },
                    secondaryButton: .cancel { appState.pendingPermanentDelete = nil }
                )
            }
            .sheet(item: $appState.pendingArchiveCreation) { pending in
                CreateArchiveView(
                    itemCount: pending.items.count,
                    defaultName: pending.items.count == 1 ? pending.items[0].name : "Archive"
                ) { name, format, password in
                    appState.createArchive(name: name, format: format, password: password)
                } onCancel: {
                    appState.pendingArchiveCreation = nil
                }
            }
            .alert(
                "Password Required",
                isPresented: Binding(
                    get: { appState.pendingArchiveExtraction != nil },
                    set: { if !$0 { appState.pendingArchiveExtraction = nil } }
                )
            ) {
                SecureField("Password", text: $appState.archiveExtractionPassword)
                Button("Cancel", role: .cancel) { appState.pendingArchiveExtraction = nil }
                Button("Extract") { appState.retryArchiveExtraction() }
            } message: {
                Text("“\(appState.pendingArchiveExtraction?.item.name ?? "")” is password-protected.")
            }
            .alert(
                "New Workspace",
                isPresented: Binding(
                    get: { workspace.pendingNewWorkspaceItems != nil },
                    set: { if !$0 { workspace.pendingNewWorkspaceItems = nil } }
                )
            ) {
                TextField("Workspace Name", text: $workspace.newWorkspaceName)
                Button("Cancel", role: .cancel) { workspace.pendingNewWorkspaceItems = nil }
                Button("Create") { workspace.confirmCreateWorkspace() }
            }
            .alert(
                "Rename Workspace",
                isPresented: Binding(
                    get: { workspace.renamingWorkspace != nil },
                    set: { if !$0 { workspace.renamingWorkspace = nil } }
                )
            ) {
                TextField("Workspace Name", text: $workspace.renameWorkspaceName)
                Button("Cancel", role: .cancel) { workspace.renamingWorkspace = nil }
                Button("Rename") { workspace.confirmRename() }
            }
            .alert(
                "Already in Workspace",
                isPresented: Binding(
                    get: { workspace.duplicateAlertMessage != nil },
                    set: { if !$0 { workspace.duplicateAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { workspace.duplicateAlertMessage = nil }
            } message: {
                Text(workspace.duplicateAlertMessage ?? "")
            }
    }

    /// The HUD in the window corner listing active operations (copy/move/archives).
    private var operationsOverlay: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(appState.activeOperations) { op in
                OperationProgressRow(op: op)
            }
        }
        .padding(14)
    }

    private var paneContent: some View {
        HSplitView {
            PaneView(model: appState.leftPane, side: .left, favorites: appState.favorites)
            // Collapse to zero width instead of removing from the tree — switching the
            // container's very shape (HSplitView with two children <-> a single View) caused a
            // multi-second lag from recreating the Table inside AppKit (see showSecondPane).
            PaneView(model: appState.rightPane, side: .right, favorites: appState.favorites)
                .frame(width: appState.showSecondPane ? nil : 0)
                .clipped()
        }
    }
}
