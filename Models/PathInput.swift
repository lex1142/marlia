import Foundation

/// Paths typed by hand (Go to Folder): expanding, displaying and completing them.
/// Foundation only, so a scratchpad script can exercise it against a real directory.
enum PathInput {

    /// `~` and `~/x` → home; `/x` → absolute; anything else → relative to `base` (the active
    /// pane's folder). `.` and `..` are resolved.
    static func resolve(_ typed: String, relativeTo base: URL) -> URL {
        let expanded = (typed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
        return url.standardizedFileURL
    }

    /// The home folder shown as `~`, like Finder's Go to Folder does.
    static func display(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Folders that complete the last component of what was typed: "~/Do" → Documents,
    /// Downloads; "~/Projects/" → every folder inside Projects. Case-insensitive; hidden
    /// folders only when the typed component starts with a dot. Symlinks to folders count
    /// as folders. Sorted the way Finder sorts names.
    static func completions(_ typed: String, relativeTo base: URL, limit: Int = 40) -> [URL] {
        let directory: URL
        let prefix: String
        if typed.isEmpty || typed.hasSuffix("/") {
            directory = typed.isEmpty ? base.standardizedFileURL : resolve(typed, relativeTo: base)
            prefix = ""
        } else {
            let resolved = resolve(typed, relativeTo: base)
            directory = resolved.deletingLastPathComponent()
            // Not resolved.lastPathComponent: standardizing "~/.." would have consumed it.
            prefix = (typed as NSString).lastPathComponent
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let wanted = prefix.precomposedStringWithCanonicalMapping.lowercased()
        let showHidden = prefix.hasPrefix(".")
        var result: [URL] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if name.hasPrefix("."), !showHidden { continue }
            guard name.precomposedStringWithCanonicalMapping.lowercased().hasPrefix(wanted) else { continue }
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            // fileExists follows symlinks, so a link to a folder counts as a folder.
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // Packages (.app and friends) are files to a user.
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }
}

/// Recently visited folders (Go to Folder's list), most recent first, app-wide and persisted.
final class RecentFolders {
    static let shared = RecentFolders()

    private static let defaultsKey = "Marlia.RecentFolders"
    static let limit = 30
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var items: [URL] {
        (defaults.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != "/" else { return }
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
        defaults.set(paths, forKey: Self.defaultsKey)
    }
}
