import Foundation

/// POSIX permission bits for Get Info's permissions section (Path Finder edits them in its
/// info panel). Foundation only, so a scratchpad script can check the bit math and the
/// recursive mode string against real files.
enum Permissions {
    enum Who: Int, CaseIterable, Identifiable {
        case owner, group, everyone
        var id: Int { rawValue }
        var shift: UInt16 { switch self { case .owner: return 6; case .group: return 3; case .everyone: return 0 } }
        var letter: Character { switch self { case .owner: return "u"; case .group: return "g"; case .everyone: return "o" } }
    }

    enum Access: UInt16, CaseIterable, Identifiable {
        case read = 4, write = 2, execute = 1
        var id: UInt16 { rawValue }
    }

    static func has(_ mode: UInt16, _ who: Who, _ access: Access) -> Bool {
        mode & (access.rawValue << who.shift) != 0
    }

    static func setting(_ mode: UInt16, _ who: Who, _ access: Access, _ on: Bool) -> UInt16 {
        let bit = access.rawValue << who.shift
        return on ? mode | bit : mode & ~bit
    }

    /// "rwxr-xr-x", like `ls -l`.
    static func string(_ mode: UInt16) -> String {
        Who.allCases.map { who in
            Access.allCases.map { has(mode, who, $0) ? String(Self.letter($0)) : "-" }.joined()
        }.joined()
    }

    /// The `chmod -R` mode that gives everything inside a folder the folder's read/write
    /// access, as Finder's "Apply to enclosed items" does — e.g. "u=rwX,g=rX,o=". Capital
    /// X is the point: subfolders get "open" (execute) where the folder has it, but a file
    /// becomes executable only if it already was, so documents don't turn into programs
    /// and scripts don't stop being runnable.
    static func enclosedItemsMode(for folderMode: UInt16) -> String {
        Who.allCases.map { who in
            var letters = ""
            if has(folderMode, who, .read) { letters += "r" }
            if has(folderMode, who, .write) { letters += "w" }
            if has(folderMode, who, .execute) { letters += "X" }
            return "\(who.letter)=\(letters)"
        }.joined(separator: ",")
    }

    private static func letter(_ access: Access) -> Character {
        switch access { case .read: return "r"; case .write: return "w"; case .execute: return "x" }
    }

    struct Info: Equatable {
        var mode: UInt16
        var owner: String
        var group: String
        var isFolder: Bool
    }

    /// Of the item itself, a symlink resolved first (chmod changes the target anyway, so
    /// showing the link's own bits would be showing something that can't be edited).
    static func read(_ url: URL) -> Info? {
        let path = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return nil }
        return Info(mode: mode & 0o777,
                    owner: attributes[.ownerAccountName] as? String ?? "?",
                    group: attributes[.groupOwnerAccountName] as? String ?? "?",
                    isFolder: (attributes[.type] as? FileAttributeType) == .typeDirectory)
    }

    /// Keeps the special bits (setuid/setgid/sticky) that the checkboxes don't show.
    static func write(_ mode: UInt16, to url: URL) throws {
        let path = url.resolvingSymlinksInPath().path
        let current = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let combined = (current & ~0o777) | (mode & 0o777)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: combined)], ofItemAtPath: path)
    }

    /// `chmod -R <mode> <folder>` as the user. Returns nil on success, the error text
    /// otherwise (chmod carries on past items it can't change and reports them).
    static func applyToEnclosed(_ folder: URL, mode: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", mode, folder.resolvingSymlinksInPath().path]
        let pipe = Pipe()
        process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
