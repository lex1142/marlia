import Foundation

/// Compare Folders (⇧F2, as in Total Commander): in each pane, select what the other pane
/// lacks or holds an older copy of.
///
/// - An entry present on one side only is selected (files and folders alike; folder
///   *contents* aren't compared, only whether the folder exists).
/// - A file present on both sides: the newer copy is selected. Dates within
///   `dateTolerance` count as equal, because FAT/exFAT store modification times with
///   2-second precision and a copy to a USB stick would otherwise always look "different".
/// - Same date but different size: both copies are selected — they clearly differ, and
///   there's no telling which one is right.
/// - Names compare the way APFS and HFS+ do by default: case-insensitively and with Unicode
///   normalization, so "Photo.JPG" here matches "photo.jpg" there.
///
/// Foundation only, so a scratchpad script can exercise it directly.
enum FolderComparison {
    struct Entry {
        let name: String
        let isFolder: Bool
        let size: Int64
        let modified: Date
    }

    static let dateTolerance: TimeInterval = 2

    /// Names to select on the left and on the right (original spelling of each side).
    static func compare(left: [Entry], right: [Entry]) -> (left: Set<String>, right: Set<String>) {
        let leftByKey = Dictionary(left.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let rightByKey = Dictionary(right.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var selectLeft = Set<String>()
        var selectRight = Set<String>()

        for (k, l) in leftByKey {
            guard let r = rightByKey[k], r.isFolder == l.isFolder else {
                selectLeft.insert(l.name)
                continue
            }
            if l.isFolder { continue }
            let delta = l.modified.timeIntervalSince(r.modified)
            if delta > dateTolerance {
                selectLeft.insert(l.name)
            } else if delta < -dateTolerance {
                selectRight.insert(r.name)
            } else if l.size != r.size {
                selectLeft.insert(l.name)
                selectRight.insert(r.name)
            }
        }
        for (k, r) in rightByKey {
            if let l = leftByKey[k], l.isFolder == r.isFolder { continue }
            selectRight.insert(r.name)
        }
        return (selectLeft, selectRight)
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
