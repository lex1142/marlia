import SwiftUI

/// The "Get Info" window — opened from the context menu or with ⌘I, one window per file
/// (several can be open at once, as in Finder). The content itself lives in
/// ItemDetailsView: the info panel shows the same view, and two diverging copies of the
/// same rows would be an open invitation for them to drift apart.
struct GetInfoView: View {
    let url: URL

    var body: some View {
        ScrollView {
            ItemDetailsView(url: url, thumbnailSize: 128, showsPath: true)
            // Only in the Get Info window: the info panel is for looking, not editing.
            PermissionsSection(url: url)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 340)
    }
}

/// Details of one item: preview, name, kind, size, location, dates, lock.
struct ItemDetailsView: View {
    let url: URL
    var thumbnailSize: CGFloat = 128
    var showsPath: Bool = true

    @State private var item: FileItem?
    @State private var size: Int64?
    @State private var isCalculatingSize = false
    @State private var createdDate: Date?
    @State private var isLocked = false

    var body: some View {
        Group {
            if let item {
                content(for: item)
            } else {
                Text("Item not found")
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        // task(id:), not onAppear: in the info panel ONE instance of this view is
        // reused for different files, and onAppear fires for it only once — the panel
        // would keep showing the first file it opened. (.id(url) inside the body
        // doesn't help here: it changes the subtree's identity but doesn't reset the
        // view's own @State.)
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private func content(for item: FileItem) -> some View {
        VStack(spacing: 14) {
            // 0 — no thumbnail: the info panel shows a live preview above instead.
            if thumbnailSize > 0 {
                ThumbnailImage(item: item, displaySize: thumbnailSize)
            }

            Text(item.name)
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                infoRow("Kind", item.kind)
                infoRow("Size", sizeDescription)
                infoRow("Where", url.deletingLastPathComponent().path)
                if let createdDate {
                    infoRow("Created", createdDate.formatted(.dateTime.day().month().year().hour().minute()))
                }
                infoRow("Modified", item.modified.formatted(.dateTime.day().month().year().hour().minute()))

                GridRow {
                    Text("Locked")
                    Toggle("", isOn: $isLocked)
                        .labelsHidden()
                        .onChange(of: isLocked) { setLocked($0) }
                }
            }
            .font(.callout)

            if showsPath {
                Divider()

                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(20)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var sizeDescription: String {
        guard let item, !item.isNavigableFolder else {
            if isCalculatingSize { return "Calculating…" }
            if let size { return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }

    /// Await the subtree walk right here rather than in a separate Task: that way
    /// task(id:) itself cancels it when the file changes. The count used to live a life
    /// of its own, and with a fast-changing selection the result for the previous folder
    /// could arrive later and overwrite the current one.
    private func load() async {
        item = FileItem(url: url)
        createdDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        isLocked = (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable ?? false
        size = nil
        isCalculatingSize = false

        guard let item, item.isNavigableFolder else { return }
        isCalculatingSize = true
        let total = await Self.folderSize(at: url)
        guard !Task.isCancelled else { return }
        size = total
        isCalculatingSize = false
    }

    private static func folderSize(at url: URL) async -> Int64 {
        await Task.detached {
            var total: Int64 = 0
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                if Task.isCancelled { break }
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }.value
    }

    private func setLocked(_ locked: Bool) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try? mutableURL.setResourceValues(values)
    }
}

/// Get Info ▸ Permissions: read/write/execute for owner, group and everyone, as
/// checkboxes, plus Apply to Enclosed Items for folders (the bit math and the recursive
/// mode are in Models/Permissions.swift). A change the user isn't allowed to make is
/// retried behind the administrator password, the same path file operations use.
/// Ownership is shown, not edited: changing it always needs root, and getting it wrong
/// locks people out of their own files.
struct PermissionsSection: View {
    let url: URL
    @State private var info: Permissions.Info?
    @State private var message: String?
    @State private var confirmingEnclosed = false

    var body: some View {
        // Not a bare Group: with nothing loaded yet it would be empty, and SwiftUI drops
        // modifiers on an empty view — .task never ran, so nothing ever loaded.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let info {
                content(info)
            }
        }
        .task(id: url) { reload() }
    }

    private func content(_ info: Permissions.Info) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Permissions").font(.headline)
                Spacer()
                Text(Permissions.string(info.mode))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Read").font(.caption).foregroundStyle(.secondary)
                    Text("Write").font(.caption).foregroundStyle(.secondary)
                    // For a folder the execute bit means "may open it".
                    Text(info.isFolder ? "Open" : "Execute").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Permissions.Who.allCases) { who in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title(who))
                            if who != .everyone {
                                Text(who == .owner ? info.owner : info.group)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Permissions.Access.allCases) { access in
                            Toggle("", isOn: binding(info, who, access))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .font(.callout)
            if info.isFolder {
                Button("Apply to Enclosed Items…") { confirmingEnclosed = true }
                    .help("Give everything inside this folder the same read/write access; subfolders can be opened, files keep their own execute setting")
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Apply these permissions to everything inside “\(url.lastPathComponent)”?", isPresented: $confirmingEnclosed) {
            Button("Apply") { applyToEnclosed(info) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every file and folder inside gets \(Permissions.enclosedItemsMode(for: info.mode)). Files that are executable stay executable; others don't become so. This can't be undone with ⌘Z.")
        }
    }

    private func title(_ who: Permissions.Who) -> String {
        switch who { case .owner: return "Owner"; case .group: return "Group"; case .everyone: return "Everyone" }
    }

    private func binding(_ info: Permissions.Info, _ who: Permissions.Who, _ access: Permissions.Access) -> Binding<Bool> {
        Binding(
            get: { Permissions.has(info.mode, who, access) },
            set: { on in apply(Permissions.setting(info.mode, who, access, on)) }
        )
    }

    private func reload() {
        info = Permissions.read(url)
    }

    @MainActor
    private func apply(_ mode: UInt16) {
        message = nil
        do {
            try Permissions.write(mode, to: url)
        } catch where FileOperationService.isPermissionError(error) {
            let path = url.resolvingSymlinksInPath().path
            switch FileOperationService.runWithAdministratorPrivileges(["/bin/chmod", String(mode, radix: 8), path]) {
            case .success, .cancelled: break
            case .failed(let text): message = text
            }
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    @MainActor
    private func applyToEnclosed(_ info: Permissions.Info) {
        message = nil
        let mode = Permissions.enclosedItemsMode(for: info.mode)
        if let error = Permissions.applyToEnclosed(url, mode: mode) {
            // chmod -R carries on past items it may not change; offer to redo it as admin.
            let alert = NSAlert()
            alert.messageText = "Some items couldn't be changed"
            alert.informativeText = error.count > 600 ? String(error.prefix(600)) + "…" : error
            alert.addButton(withTitle: "Try as Administrator")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let path = url.resolvingSymlinksInPath().path
                if case .failed(let text) = FileOperationService.runWithAdministratorPrivileges(["/bin/chmod", "-R", mode, path]) {
                    message = text
                }
            }
        }
        reload()
    }
}
