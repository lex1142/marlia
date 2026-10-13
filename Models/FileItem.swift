import Foundation
import AppKit
import UniformTypeIdentifiers

/// One item of a file listing. Identifiable by URL.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date
    /// Dates for the "Show View Options" columns. Non-optional (defaulting to
    /// .distantPast) so they can be sorted directly with KeyPathComparator (Optional
    /// isn't Comparable). Date Last Opened comes from contentAccessDate (atime) — the
    /// cheapest URL resource from the common stat; it may be inaccurate with
    /// noatime/relatime, but needs no Spotlight query.
    let created: Date
    let dateAdded: Date
    let lastOpened: Date
    /// Finder color tags (URLResourceValues.tagNames, read-only). Empty if there are no tags.
    let tags: [String]
    /// The content UTType (from resourceValues) — used by IconCache so regular files
    /// share one per-type icon instead of a NSWorkspace call per file.
    let contentType: UTType?

    var id: URL { url }

    /// Comma-separated tags — for the "Tags" column and sorting by it (KeyPathComparator
    /// over String; [String] itself isn't Comparable).
    var tagsDisplay: String { tags.joined(separator: ", ") }

    /// A folder that can be entered (packages like .app are treated as files).
    var isNavigableFolder: Bool { isDirectory && !isPackage }

    var icon: NSImage { IconCache.shared.icon(for: self) }

    var displaySize: String {
        isNavigableFolder ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Images/videos — for these the Icons mode loads a real thumbnail instead
    /// of the generic file-type icon.
    var isPreviewableMedia: Bool {
        guard !isNavigableFolder, !isPackage else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }

    /// Human-readable kind ("Folder", "PDF Document", "JPEG Image") — for the
    /// "Kind" column in the list, sorting by kind and the Get Info panel.
    var kind: String {
        if isNavigableFolder { return "Folder" }
        if isPackage { return "Package" }
        if let type = UTType(filenameExtension: url.pathExtension), let description = type.localizedDescription {
            return description.capitalized
        }
        return "Document"
    }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .addedToDirectoryDateKey, .contentAccessDateKey, .tagNamesKey,
        .contentTypeKey
    ]

    init?(url: URL) {
        guard var values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        // By default resourceValues does NOT resolve the final path component if it's
        // a symlink (important for Workspaces, where items are symlinks throughout):
        // isDirectory for the link itself is always false, and contentsOfDirectory on
        // such a path fails with ENOTDIR. Resolve manually for type/size, but keep
        // url as the original (the link itself) — so rename/trash act on it rather
        // than on the target.
        let isSymbolicLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if isSymbolicLink {
            let resolved = url.resolvingSymlinksInPath()
            if let resolvedValues = try? resolved.resourceValues(forKeys: Set(Self.resourceKeys)) {
                values = resolvedValues
            }
        }
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.isPackage = values.isPackage ?? false
        self.isHidden = values.isHidden ?? false
        self.isSymbolicLink = isSymbolicLink
        self.size = Int64(values.fileSize ?? 0)
        self.modified = values.contentModificationDate ?? .distantPast
        self.created = values.creationDate ?? .distantPast
        self.dateAdded = values.addedToDirectoryDate ?? .distantPast
        self.lastOpened = values.contentAccessDate ?? .distantPast
        self.tags = values.tagNames ?? []
        self.contentType = values.contentType
    }
}

enum ViewMode: String, CaseIterable {
    case list, icons, columns

    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        }
    }

    var help: String {
        switch self {
        case .list: return "List"
        case .icons: return "Icons"
        case .columns: return "Columns"
        }
    }
}

/// NSWorkspace.icon isn't a free call (disk + decoding), and the icon is re-read on
/// every redraw of a row/cell (selection, scrolling, etc.). Used only from rendering on
/// the main thread, hence no locks.
///
/// The key optimization: regular files (not folders/packages/symlinks) share the icon
/// of THEIR TYPE — cached by `UTType` via `NSWorkspace.icon(for:)` rather than by URL.
/// A folder of 10k files of one type then costs ONE NSWorkspace call instead of 10k
/// (that was the source of the delay on the first scroll through large directories).
/// The price: a custom icon on a specific regular file (rare) isn't shown, only the
/// type icon. Folders, packages (.app) and symlinks, whose own icon matters visually,
/// still go through `icon(forFile:)` with a per-URL cache.
final class IconCache {
    static let shared = IconCache()
    private var byURL: [URL: NSImage] = [:]
    private var byType: [UTType: NSImage] = [:]

    func icon(for item: FileItem) -> NSImage {
        if !item.isNavigableFolder, !item.isPackage, !item.isSymbolicLink,
           let type = item.contentType {
            if let cached = byType[type] { return cached }
            let icon = NSWorkspace.shared.icon(for: type)
            byType[type] = icon
            return icon
        }
        return icon(forFileURL: item.url)
    }

    /// The icon of a specific file by URL (folders/packages/symlinks, plus the drag
    /// ghost). Same gotcha as in FileItem.init: NSWorkspace.icon(forFile:) doesn't
    /// resolve the final symlink itself — for a link (Workspace) it returns a generic
    /// blank document icon instead of the target's real type icon, hence
    /// resolvingSymlinksInPath.
    func icon(forFileURL url: URL) -> NSImage {
        if let cached = byURL[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
        byURL[url] = icon
        return icon
    }
}

extension FileItem {
    /// Directory contents as a list of URLs — the single directory-reading entry point for
    /// the pane (`PaneViewModel.reload`) and for neighbouring columns (`loadItems`), so the
    /// Applications merge below behaves the same in every mode.
    ///
    /// The merge: since macOS Catalina, Apple's apps live on the read-only system volume in
    /// /System/Applications, while third-party ones are in /Applications. Finder shows both
    /// folders as ONE list (28 + 47 items here), so we also read the system folder when
    /// /Applications itself is open. Items keep their real URLs — open, drag, Get Info and
    /// copy work as usual, while renaming/deleting a system app fails (the volume is
    /// read-only) — exactly as in Finder.
    static func contentURLs(in url: URL, includeHidden: Bool) throws -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        var urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: resourceKeys, options: options
        )
        guard let systemApplications = systemApplicationsCounterpart(for: url) else { return urls }
        let extra = (try? FileManager.default.contentsOfDirectory(
            at: systemApplications, includingPropertiesForKeys: resourceKeys, options: options
        )) ?? []
        var byName = Dictionary(urls.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in extra {
            guard let existing = byName[candidate.lastPathComponent] else {
                urls.append(candidate)
                byName[candidate.lastPathComponent] = candidate
                continue
            }
            // For a same-named app keep the one from /Applications (the writable volume —
            // that's where the installed/updated version lives). The exception is an
            // empty stub folder: the one real name collision on macOS is Utilities, where
            // /Applications holds an empty placeholder (0 visible items) and the
            // utilities themselves are in /System/Applications/Utilities (19). Showing an
            // empty folder where Finder shows Terminal and Disk Utility would be a bug.
            if isEmptyStubDirectory(existing) {
                urls.removeAll { $0 == existing }
                urls.append(candidate)
                byName[candidate.lastPathComponent] = candidate
            }
        }
        return urls
    }

    /// A directory with no visible items at all (/Applications/Utilities holds only
    /// .localized). An app bundle doesn't meet this condition — it isn't empty.
    private static func isEmptyStubDirectory(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: resolved, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.isEmpty
    }

    /// /System/Applications — but only when /Applications itself is open, not a subfolder
    /// of it.
    private static func systemApplicationsCounterpart(for url: URL) -> URL? {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == "/Applications" else { return nil }
        let system = URL(fileURLWithPath: "/System/Applications")
        return FileManager.default.fileExists(atPath: system.path) ? system : nil
    }

    /// The contents of a folder outside the active pane — needed for
    /// neighbouring columns in Columns mode (the pane itself watches only
    /// currentURL).
    static func loadItems(in url: URL, includeHidden: Bool) -> [FileItem] {
        let urls = (try? contentURLs(in: url, includeHidden: includeHidden)) ?? []
        return urls.compactMap(FileItem.init).sorted { a, b in
            if a.isNavigableFolder != b.isNavigableFolder { return a.isNavigableFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
