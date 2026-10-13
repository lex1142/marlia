import SwiftUI

/// A short guide to the app's features, opened from the Help menu (⌘?).
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Marlia User Guide")
                    .font(.largeTitle.bold())

                section("Windows & Tabs") {
                    bullet("⌘T or the “+” button — open a new tab. Tabs share one title bar, like Safari.")
                    bullet("⌘W — close the current tab/window.")
                    bullet("Open tabs, their folders, and view modes are remembered between launches.")
                }

                section("Two Panes") {
                    bullet("Each window has a left and right pane; the active one is marked with a colored bar on top.")
                    bullet("Click anywhere in a pane (or an item in it) to make it active.")
                }

                section("Browsing") {
                    bullet("◀ ▶ — back/forward, ▲ — up one level, Delete/Backspace — also goes up one level.")
                    bullet("Click the path text to type a path directly (supports “~”). Return to go, Esc to cancel.")
                    bullet("Sidebar: AirDrop, Favorites (★ button in the path bar, or right-click a folder; drag to reorder), and mounted Drives (⏏ to eject).")
                }

                section("View Modes") {
                    bullet("List, Icons, Columns — switch via the segmented control next to the path.")
                    bullet("List view: click a column header to sort by it, click again to reverse order.")
                    bullet("Icons view shows real thumbnails for images and video.")
                    bullet("Columns view (Finder-style): a single click on a folder selects it and previews its contents in the column to the right, without entering it. Double-click, Return, or → to go inside; ← to go back to the parent column. ↑/↓ move within a column.")
                    bullet("⌘+ / ⌘− / ⌘0 — zoom items in/out/reset, independently per pane, in any view mode.")
                }

                section("Selecting Files") {
                    bullet("Click an item to select it, ⌘A to select everything in the current folder.")
                    bullet("⌘-click to add/remove an item, ⇧-click to extend a range.")
                    bullet("Icons and Columns views: drag over empty space to draw a selection rectangle over multiple items; in Columns you can also drag across rows to select a range.")
                }

                section("File Operations") {
                    bullet("⌘C / ⌘X / ⌘V — copy / cut / paste (interoperates with Finder's clipboard).")
                    bullet("F5 — copy selection to the other pane, F6 — move it to the other pane.")
                    bullet("⌘⌫ — move to Trash, ⌥⌘⌫ — delete immediately (cannot be undone).")
                    bullet("⌘D — duplicate, ⇧⌘N — new folder, ⌥⇧⌘N — new file.")
                    bullet("Rename: click the name of an already-selected item (Return/double-click opens files and enters folders instead).")
                    bullet("Drag and drop files between panes, tabs, separate windows, and Finder.")
                    bullet("If a name already exists at the destination, a dialog offers Replace, Skip, or Keep Both, with an “apply to all” option for batches.")
                }

                section("Undo & Redo") {
                    bullet("⌘Z — undo the last operation, ⇧⌘Z — redo it.")
                    bullet("Covers copy, move, rename, trash, and new folder. Permanent delete is not undoable.")
                }

                section("Search") {
                    bullet("⌘F — show the search bar for the active pane.")
                    bullet("Searches recursively from the current folder. Toggle “.*” to match a regular expression instead of plain text.")
                }

                section("Workspaces") {
                    bullet("A place in the sidebar to gather files and folders from anywhere without moving or copying them — only a reference is kept.")
                    bullet("Add items via right-click → Add to Workspace, the ⇧⌘↩ shortcut, or by dragging files onto the Workspaces section in the sidebar.")
                    bullet("You can have multiple workspaces; right-click one to Rename or Delete it (deleting only removes the references, never the original files).")
                    bullet("Removing an item from a workspace (e.g. moving it to Trash from inside) only removes the reference — the original file is untouched.")
                    bullet("Opening a folder that was added to a workspace navigates to its real location, leaving the workspace.")
                }

                section("Sharing & Tools") {
                    bullet("Right-click a file → AirDrop…, or use the AirDrop entry in the sidebar, to send files to nearby devices.")
                    bullet("Right-click → Open Terminal Here to open Terminal.app in that folder.")
                }

                section("Keyboard Shortcuts") {
                    shortcutTable
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 620, height: 560)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.bold())
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
    }

    private var shortcutTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            shortcutRow("⌘T", "New tab")
            shortcutRow("⌘W", "Close tab/window")
            shortcutRow("⌘C / ⌘X / ⌘V", "Copy / Cut / Paste")
            shortcutRow("⌘A", "Select all")
            shortcutRow("⌘D", "Duplicate")
            shortcutRow("Tab", "Switch active pane (two-pane mode)")
            shortcutRow("⇧⌘↩", "Add selection to Workspace")
            shortcutRow("F5 / F6", "Copy / Move to other pane")
            shortcutRow("⌘⌫ / ⌥⌘⌫", "Trash / Delete immediately")
            shortcutRow("⇧⌘N / ⌥⇧⌘N", "New folder / New file")
            shortcutRow("⌘R", "Refresh")
            shortcutRow("⌘F", "Find")
            shortcutRow("⌘Z / ⇧⌘Z", "Undo / Redo")
            shortcutRow("⌘+ / ⌘− / ⌘0", "Zoom in / out / reset")
            shortcutRow("Delete / ⌫", "Go up one level")
            shortcutRow("Space", "Quick Look preview")
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).font(.system(.body, design: .monospaced))
            Text(action)
        }
    }
}
