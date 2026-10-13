import Foundation

/// The remembered sort order of individual directories — survives an app restart.
///
/// The idea is exactly Finder's: pick a sort in a folder and that folder keeps it,
/// including after the app is closed. Directories where the user never chose anything
/// behave as before: the pane arrives with its current sort, nothing is imposed and
/// nothing is remembered.
///
/// Stored in UserDefaults as a single JSON dictionary "path → field + direction". One
/// singleton for the app (like ShortcutStore): a folder's sort is shared by all windows
/// and tabs, otherwise the same folder in two tabs would disagree.
@MainActor
final class SortPreferencesStore {
    static let shared = SortPreferencesStore()

    /// What is remembered: the field and the direction. The direction is separate
    /// because it's set not only by the menu (where each field has a default direction)
    /// but also by a column-header click in List mode, which can invert the order.
    struct Entry: Codable {
        let field: String
        let ascending: Bool
        /// When the entry was last useful — the store is trimmed by this field
        /// (folders come and go, and the dictionary would otherwise grow forever).
        var usedAt: Date
    }

    /// Beyond this it's no longer "recent folders" but garbage: the dictionary is
    /// written in full on every sort change, and there's no point in bloating it.
    private static let limit = 500
    private static let defaultsKey = "Marlia.SortByDirectory"

    private var entries: [String: Entry]

    private init() {
        entries = Self.load()
    }

    /// The sort remembered for this directory (nil — nothing remembered).
    func sort(for url: URL) -> (field: SortField, ascending: Bool)? {
        let key = Self.key(for: url)
        guard let entry = entries[key], let field = SortField(rawValue: entry.field) else { return nil }
        // Update "last used" right on read: a frequently opened folder shouldn't be
        // evicted from the store just because its sort hasn't been changed in a while.
        entries[key]?.usedAt = Date()
        return (field, entry.ascending)
    }

    func record(field: SortField, ascending: Bool, for url: URL) {
        entries[Self.key(for: url)] = Entry(field: field.rawValue, ascending: ascending, usedAt: Date())
        trimIfNeeded()
        save()
    }

    /// The path as the key: a symlink path and the "real" path of the same folder
    /// must map to one entry, otherwise a Workspace link and the original would
    /// remember different things.
    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func trimIfNeeded() {
        guard entries.count > Self.limit else { return }
        let survivors = entries.sorted { $0.value.usedAt > $1.value.usedAt }.prefix(Self.limit)
        entries = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        // Flush to disk right away: changing the sort is a rare user action, but a
        // choice made just before ⌘Q must not be lost to a deferred write
        // (synchronize is in WindowStateStore for the same reason).
        UserDefaults.standard.synchronize()
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }
}
