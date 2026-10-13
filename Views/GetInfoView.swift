import SwiftUI

/// The "Get Info" window — opened from the context menu or with ⌘I, one window per file
/// (several can be open at once, as in Finder). The content itself lives in
/// ItemDetailsView: the info panel shows the same view, and two diverging copies of the
/// same rows would be an open invitation for them to drift apart.
struct GetInfoView: View {
    let url: URL

    var body: some View {
        ItemDetailsView(url: url, thumbnailSize: 128, showsPath: true)
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
            ThumbnailImage(item: item, displaySize: thumbnailSize)

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
