import SwiftUI
import AppKit

/// The sidebar: favorites, mounted drives. Clicking any item takes the active
/// pane there.
struct SidebarView: View {
    @ObservedObject var favorites: FavoritesStore
    /// The active pane's current directory is the source of truth for the sidebar
    /// row highlight (see sidebarSelection below), not a separate click state: a row
    /// stays highlighted while the pane is actually in that directory, and clears
    /// itself as soon as the user leaves by any other means (clicking a file,
    /// breadcrumbs, typing a path, etc.), not only via an explicit Remove/navigation
    /// through the sidebar.
    let currentDirectoryURL: URL
    let onNavigate: (URL) -> Void
    let onAirDrop: () -> Void
    /// Whether there's anything to send via AirDrop (at least one file is selected in the
    /// active pane) — otherwise the AirDrop item is inactive (grey) rather than silently
    /// doing nothing.
    let canAirDrop: Bool
    /// Show the virtual "Recents" view (recent files) in the active pane.
    let onShowRecents: () -> Void
    /// Whether the active pane is currently in Recents mode — then highlight the Recents
    /// row rather than currentURL (otherwise the previous folder stays selected, and
    /// clicking it again in the List doesn't count as a selection change → navigation
    /// doesn't fire).
    let isRecentsActive: Bool

    /// The tag of the Recents row in the List selection. Not a file URL — it can't
    /// collide with any real row; selecting this tag means "show Recents".
    private static let recentsSentinel = URL(string: "marlia:recents")!

    /// Whether the "Connect to Server" sheet is shown. A binding rather than @State: the
    /// same sheet is raised by Go ▸ Connect to Server… in the menu bar, while the sheet
    /// lives here — there's no need for a second copy in the window just for the menu.
    @Binding var isConnectPresented: Bool

    @StateObject private var volumes = VolumesStore()
    @ObservedObject private var workspace = WorkspaceStore.shared
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showWorkspacesInfo = false
    /// Whether to show the "Recents" item — toggled from the View menu (a shared
    /// @AppStorage key).
    @AppStorage("Marlia.showRecentsInSidebar") private var showRecentsInSidebar = true


    /// A real List row selection (not just a Button on every row) — required for
    /// Favorites drag-reordering (.onMove) to work at all: confirmed empirically (a
    /// separate test app) that a Button/.onTapGesture on row content blocks the List's
    /// reorder-gesture recognition, while a row with no gesture at all doesn't — but
    /// then the click has to be handled through the native List selection instead of a
    /// gesture of our own. The getter of this computed Binding returns the active pane's
    /// directoryURL directly — the List highlights the row whose .tag(url) matches (or
    /// none, if the user isn't in Favorites/Drives/Workspaces); the setter reacts to the
    /// user clicking a row and simply requests navigation rather than storing state of
    /// its own.
    private var sidebarSelection: Binding<URL?> {
        Binding(
            get: { isRecentsActive ? Self.recentsSentinel : currentDirectoryURL },
            set: { newValue in
                guard let url = newValue else { return }
                if url == Self.recentsSentinel {
                    onShowRecents()
                } else {
                    onNavigate(url)
                }
            }
        )
    }

    var body: some View {
        List(selection: sidebarSelection) {
            Button {
                // Not .disabled(): a disabled SwiftUI view gets no hover, so its
                // .help() (the tooltip explaining WHY the item is inactive) is never
                // shown. So the view stays enabled but grey, with a no-op action when
                // there's nothing to send — that way the hover tooltip works.
                if canAirDrop { onAirDrop() }
            } label: {
                // Dim with opacity rather than .foregroundStyle: in a List the Label icon
                // is tinted with the accent and ignores foregroundStyle (only the title
                // went grey). Opacity dims the icon and the text evenly — it looks like
                // disabled.
                Label("AirDrop", systemImage: "wifi")
                    .opacity(canAirDrop ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .help(canAirDrop ? "Send selected files via AirDrop" : "Select files in the active pane to send via AirDrop")
            .accessibilityLabel("AirDrop")

            Button {
                isConnectPresented = true
            } label: {
                Label("Connect to Server", systemImage: "network")
            }
            .buttonStyle(.plain)

            if showRecentsInSidebar {
                // A List row (not a Button) with a sentinel tag — so the List highlights
                // it natively when the pane is in Recents mode (see sidebarSelection).
                Label("Recents", systemImage: "clock")
                    .lineLimit(1)
                    .tag(Self.recentsSentinel)
            }

            Section("Favorites") {
                ForEach(favorites.items, id: \.self) { url in
                    row(url: url, systemImage: iconName(for: url))
                        .contextMenu {
                            Button("Remove from Favorites", role: .destructive) {
                                favorites.remove(url)
                            }
                        }
                }
                .onMove { source, destination in
                    favorites.move(fromOffsets: source, toOffset: destination)
                }
            }

            Section("Drives") {
                ForEach(volumes.items, id: \.self) { url in
                    driveRow(url: url)
                }
            }

            Section {
                ForEach(workspace.workspaces, id: \.self) { url in
                    workspaceRow(url: url)
                }
                if workspace.workspaces.isEmpty {
                    Text("Drag files here, or use “Add to Workspace”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    workspace.beginCreatingWorkspace()
                } label: {
                    Label("New Workspace", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            } header: {
                HStack(spacing: 4) {
                    Text("Workspaces")
                    Button {
                        showWorkspacesInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("What are Workspaces?")
                    .accessibilityLabel("What are Workspaces?")
                    .popover(isPresented: $showWorkspacesInfo, arrowEdge: .trailing) {
                        workspacesInfoPopover
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                acceptWorkspaceDrop(providers, into: nil)
            }
        }
        .listStyle(.sidebar)
        // A custom sidebar background only for palette themes: the system vibrancy
        // backdrop is hidden (scrollContentBackground), otherwise it covers our color.
        // With the System theme neither modifier is applied at all, and the sidebar stays
        // system-drawn.
        .themedSidebarBackground(theme.palette.sidebarBackground)
        // The selected sidebar row and Label icons are painted with the accent —
        // ours, not the system one (see themedTint).
        .themedTint(theme.palette)
        .sheet(isPresented: $isConnectPresented) {
            ConnectToServerView(onSuccess: { url in
                isConnectPresented = false
                volumes.refresh()
                onNavigate(url)
            }, onCancel: {
                isConnectPresented = false
            })
        }
    }

    /// A short description of the Workspaces section — shown by clicking ⓘ next to
    /// the section header.
    private var workspacesInfoPopover: some View {
        // An explicit width on each Text + lineLimit(nil): in a popover (a separate
        // window) Text otherwise fit on one line with "…" instead of wrapping.
        let textWidth: CGFloat = 320
        return VStack(alignment: .leading, spacing: 8) {
            Label("Workspaces", systemImage: "square.stack.3d.up")
                .font(.headline)
            Text("Gather links to files and folders from anywhere — without moving or copying them. Only a reference is kept, so removing an item here (Remove from Workspace) never deletes the original.")
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
            Text("Add items via right-click → Add to Workspace, ⇧⌘↩, or by dragging files onto this section. Create a workspace with “New Workspace”.")
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .padding(16)
    }

    /// A Workspace is an ordinary (app-managed) folder with symlinks inside: a click
    /// just takes the active pane into it, and from there everything works as with a
    /// regular directory.
    private func workspaceRow(url: URL) -> some View {
        row(url: url, systemImage: "folder")
            .contextMenu {
                Button("Rename…") { workspace.beginRenaming(url) }
                Button("Delete Workspace", role: .destructive) { workspace.deleteWorkspace(url) }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                acceptWorkspaceDrop(providers, into: url)
            }
    }

    /// into: nil — add to the "default"/last used workspace (creating it if needed);
    /// into: a specific workspace — add exactly there.
    private func acceptWorkspaceDrop(_ providers: [NSItemProvider], into target: URL?) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let item = FileItem(url: url) else { return }
                DispatchQueue.main.async {
                    if let target {
                        workspace.add([item], to: target)
                    } else {
                        workspace.addToDefaultWorkspace([item])
                    }
                }
            }
        }
        return true
    }

    /// As in Finder: "special" folders get their own icon instead of the plain
    /// yellow folder — recognized by name (enough for the system
    /// Desktop/Documents/...) or by matching the user's home directory.
    private func iconName(for url: URL) -> String {
        if url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            return "house"
        }
        switch url.lastPathComponent {
        case "Desktop": return "desktopcomputer"
        case "Documents": return "doc"
        case "Downloads": return "tray.and.arrow.down.fill"
        case "Movies": return "film"
        case "Music": return "music.note"
        case "Pictures": return "photo"
        case "Public": return "person.2"
        case "Applications": return "square.grid.2x2"
        case ".Trash": return "trash"
        default: return "folder"
        }
    }

    private func row(url: URL, systemImage: String) -> some View {
        Label(FileManager.default.displayName(atPath: url.path), systemImage: systemImage)
            .lineLimit(1)
            .tag(url)
    }


    private func driveRow(url: URL) -> some View {
        let network = isNetworkMount(url)
        let ejectable = isEjectable(url) || network
        return HStack {
            row(url: url, systemImage: network ? "network" : "internaldrive")

            if ejectable {
                Spacer()
                Button {
                    eject(url)
                } label: {
                    Image(systemName: network ? "xmark.circle.fill" : "eject.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help((network ? "Disconnect “\(FileManager.default.displayName(atPath: url.path))”" : "Eject “\(FileManager.default.displayName(atPath: url.path))”"))
                .accessibilityLabel(network ? "Disconnect" : "Eject")
            }
        }
        .contextMenu {
            if ejectable {
                Button(network ? "Disconnect" : "Eject") { eject(url) }
            }
        }
    }

    /// `volumeIsEjectable` alone isn't enough: external USB SSDs/HDDs report themselves as
    /// non-removable media (`Removable Media: Fixed`), and both ejectable and removable are
    /// false for them. The criterion by which Finder shows them an eject button is "the volume
    /// isn't internal".
    private func isEjectable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey
        ]) else { return false }
        if values.volumeIsRootFileSystem == true { return false }
        return values.volumeIsEjectable == true
            || values.volumeIsRemovable == true
            || values.volumeIsInternal == false
    }

    /// SMB shares connected via "Connect to Server" aren't marked isEjectable —
    /// show the disconnect button based on "the volume isn't local".
    private func isNetworkMount(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }

    /// Volumes whose ejection is already in progress (touched only from the main thread).
    /// While the system prompt for removable-volume access is up, a second click on ⏏
    /// would otherwise start a second ejection in parallel — and whichever of the two lost
    /// showed a bogus error.
    private static var ejectingPaths: Set<String> = []

    /// Ejection runs off the main thread: unmounting can take seconds. `NSWorkspace`
    /// doesn't always cope with external drives marked as non-removable (USB SSDs with
    /// `Removable Media: Fixed`), so on failure we try `diskutil eject` — as Finder does.
    /// If that fails too, the reason is shown instead of the silence there used to be.
    private func eject(_ url: URL) {
        guard Self.ejectingPaths.insert(url.path).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                failure = Self.diskutilEject(url)
            }
            let message = failure
            DispatchQueue.main.async {
                Self.ejectingPaths.remove(url.path)
                if let message {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t eject “\(FileManager.default.displayName(atPath: url.path))”"
                    alert.informativeText = message
                    alert.runModal()
                } else if NetworkMountService.isManagedMount(url) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Returns nil on success, otherwise the error text from diskutil.
    private static func diskutilEject(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : (output.isEmpty ? "diskutil eject failed" : output)
    }
}

/// Favorite folders, persisted in UserDefaults by path.
final class FavoritesStore: ObservableObject {
    @Published private(set) var items: [URL]
    private let defaultsKey = "Marlia.Favorites"

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) {
            items = saved.map(URL.init(fileURLWithPath:))
        } else {
            items = Self.defaultFavorites()
        }
    }

    func add(_ url: URL) {
        guard !items.contains(url) else { return }
        items.append(url)
        persist()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        persist()
    }

    /// Manual ordering via drag-and-drop in the sidebar (.onMove) — the same order
    /// that is then persisted and restored between launches.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: defaultsKey)
    }

    private static func defaultFavorites() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home,
            // As in Finder: the Applications row leads to the system-wide /Applications,
            // not ~/Applications (the user's personal applications folder is usually
            // empty). The position is Finder's too: right after Home, before Desktop.
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            // The user's Trash (~/.Trash) — displayName returns the localized "Trash".
            FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Recently opened files (like Finder's "Recents"; shared across the app, like
/// WorkspaceStore) — filled from PaneViewModel.open when a file is opened, shown in the
/// sidebar above Favorites. De-duplicated with move-to-front, capped, persisted in
/// UserDefaults.
final class RecentsStore: ObservableObject {
    static let shared = RecentsStore()
    @Published private(set) var items: [URL] = []
    private let defaultsKey = "Marlia.Recents"
    private let maxCount = 12

    init() {
        let saved = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).map(URL.init(fileURLWithPath:))
        // Drop paths that no longer exist (the folder was deleted/unmounted).
        items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        let u = url.standardizedFileURL
        items.removeAll { $0.standardizedFileURL == u }
        items.insert(u, at: 0)
        if items.count > maxCount { items.removeLast(items.count - maxCount) }
        persist()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: defaultsKey)
    }
}

/// The list of mounted drives, updated as volumes are mounted/unmounted.
final class VolumesStore: ObservableObject {
    @Published var items: [URL] = []
    private var tokens: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
    }

    func refresh() {
        items = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }
}
