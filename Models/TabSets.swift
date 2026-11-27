import Foundation

/// Tab Sets — Path Finder's tab presets: the tabs of a window (each with both panes'
/// folders and view modes, the second pane and the info panel) saved under a name and
/// reopened in one go, e.g. "Website" = source, build output, assets. Stored in the
/// same WindowState form the session uses, so a set opens exactly like a restored
/// session does. App-wide, persisted in UserDefaults.
struct TabSet: Codable {
    var name: String
    var tabs: [WindowState]
}

final class TabSetStore: ObservableObject {
    static let shared = TabSetStore()
    private static let defaultsKey = "Marlia.TabSets"
    private let defaults: UserDefaults

    /// Sorted by name, the order the menu shows them in.
    @Published private(set) var sets: [TabSet] { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([TabSet].self, from: data) {
            sets = decoded
        } else {
            sets = []
        }
    }

    /// Saving under an existing name replaces that set (names compare case-insensitively).
    func save(_ set: TabSet) {
        var all = sets.filter { $0.name.caseInsensitiveCompare(set.name) != .orderedSame }
        all.append(set)
        sets = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func remove(named name: String) {
        sets.removeAll { $0.name == name }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
