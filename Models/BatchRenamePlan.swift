import Foundation

/// Rules for building new names in a batch rename.
///
/// Deliberately kept in a separate type with no dependencies beyond Foundation:
/// it's pure logic, so it can be compiled together with a scratchpad script and
/// actually exercised instead of being restated in a test (see the verification
/// section in CLAUDE.md). Everything that touches the disk lives in
/// FileOperationService.batchRename.
enum BatchRenameMode: String, CaseIterable, Identifiable {
    case pattern
    case findReplace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pattern: return "Pattern"
        case .findReplace: return "Find & Replace"
        }
    }
}

/// Case applied to the new name (without the extension), in either mode.
enum BatchRenameCase: String, CaseIterable, Identifiable {
    case unchanged, lowercase, uppercase, capitalized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchanged: return "Keep Case"
        case .lowercase: return "lowercase"
        case .uppercase: return "UPPERCASE"
        case .capitalized: return "Capitalize Words"
        }
    }
}

struct BatchRenameSettings {
    var mode: BatchRenameMode = .pattern
    /// `#` (any number in a row) — a number zero-padded to the group's length,
    /// `*` — the original name without the extension, `[Date]`, `[Time]`, `[Track]`,
    /// `[Artist]`, `[Title]`, `[Album]` — from the file's metadata (see BatchRenameToken).
    var pattern: String = "*"
    var startIndex: Int = 1
    var find: String = ""
    var replace: String = ""
    var nameCase: BatchRenameCase = .unchanged
    /// .JPG → .jpg: cameras write upper case, most people want lower.
    var lowercaseExtension = false
}

/// What the metadata tokens are filled from. Read by FileMetadataReader (ImageIO/AVFoundation);
/// kept here as plain values so the naming rules stay Foundation-only and testable.
struct FileMetadata: Equatable {
    /// When the photo/video was taken (EXIF DateTimeOriginal, a movie's creation date).
    var captureDate: Date?
    /// Used by [Date]/[Time] when there's no capture date — the file's modification date.
    var fallbackDate: Date?
    var track: Int?
    var artist: String?
    var title: String?
    var album: String?
}

/// The `[Name]` tokens of the pattern. Matching is case-insensitive; an unknown `[word]`
/// stays literal text.
enum BatchRenameToken: String, CaseIterable {
    case date = "Date", time = "Time", track = "Track", artist = "Artist", title = "Title", album = "Album"

    var hint: String {
        switch self {
        case .date: return "Date taken (photos, videos) or modified — 2026-10-03"
        case .time: return "Time taken or modified — 12.28.04"
        case .track: return "Track number — 03"
        case .artist: return "Artist"
        case .title: return "Song title"
        case .album: return "Album"
        }
    }

    static func usesMetadata(_ pattern: String) -> Bool {
        let lower = pattern.lowercased()
        return allCases.contains { lower.contains("[\($0.rawValue.lowercased())]") }
    }
}

/// One preview row: what it was, what it will become, and why it can't be
/// applied.
struct BatchRenameEntry: Identifiable {
    enum Problem: Equatable {
        case invalidName
        /// Two selected files get the same name.
        case duplicateInBatch
        /// The name is taken by a file that isn't part of the rename.
        case takenInDirectory
        /// A token like [Track] has nothing to fill it from in this file.
        case missingMetadata(BatchRenameToken)

        var message: String {
            switch self {
            case .invalidName: return "Not a valid name"
            case .duplicateInBatch: return "Two items would get this name"
            case .takenInDirectory: return "A file with this name already exists"
            case .missingMetadata(let token): return "This file has no \(token.rawValue.lowercased()) in its metadata"
            }
        }
    }

    let id: String
    let originalName: String
    let newName: String
    var problem: Problem?

    var isChanged: Bool { originalName != newName }
}

enum BatchRenamePlan {

    /// The single source of truth on whether a file name is valid —
    /// FileOperationService.isValidItemName comes here too. Keeping a second copy of
    /// the rules nearby would be an open invitation for them to diverge.
    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !trimmed.contains("\0")
            && !trimmed.contains(where: \.isNewline)
    }

    /// `existingNames` — names in the same folder that are NOT part of the rename.
    /// Only these are checked for being taken: a name freed by another file being
    /// renamed isn't a conflict (swapping names is allowed — the rename runs in two
    /// phases, see FileOperationService.batchRename).
    static func build(names: [String],
                      existingNames: Set<String>,
                      settings: BatchRenameSettings,
                      metadata: [String: FileMetadata] = [:]) -> [BatchRenameEntry] {
        var entries: [BatchRenameEntry] = []
        var seen: [String: Int] = [:]   // new name → how many times it occurs
        var missing: [String: BatchRenameToken] = [:]

        for (offset, name) in names.enumerated() {
            var newName: String
            switch settings.mode {
            case .pattern:
                let result = applyPattern(to: name,
                                          index: settings.startIndex + offset,
                                          pattern: settings.pattern,
                                          numbered: names.count > 1,
                                          metadata: metadata[name] ?? FileMetadata())
                newName = result.name
                if let token = result.missing { missing[name] = token }
            case .findReplace:
                newName = applyFindReplace(to: name, find: settings.find, replace: settings.replace)
            }
            newName = applyCase(to: newName, settings: settings)
            entries.append(BatchRenameEntry(id: name, originalName: name, newName: newName))
            seen[newName, default: 0] += 1
        }

        for index in entries.indices {
            let entry = entries[index]
            if let token = missing[entry.originalName] {
                entries[index].problem = .missingMetadata(token)
            } else if !isValidName(entry.newName) {
                entries[index].problem = .invalidName
            } else if seen[entry.newName, default: 0] > 1 {
                entries[index].problem = .duplicateInBatch
            } else if existingNames.contains(entry.newName) {
                entries[index].problem = .takenInDirectory
            }
        }
        return entries
    }

    static func hasProblems(_ entries: [BatchRenameEntry]) -> Bool {
        entries.contains { $0.problem != nil }
    }

    // MARK: Modes

    /// The extension is always kept: the pattern describes the name, not the file type,
    /// and losing the extension of fifty files in one click isn't a mistake worth making
    /// possible. Changing extensions is what find-and-replace mode is for; it works on
    /// the full name.
    private static func applyPattern(to name: String, index: Int, pattern: String, numbered: Bool,
                                     metadata: FileMetadata) -> (name: String, missing: BatchRenameToken?) {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var missing: BatchRenameToken?

        var template = pattern
        // Without a `#` group every file would get the same name, so a number is
        // appended automatically. Not for a single file — there a pattern without a
        // number makes sense. Nor when the pattern uses metadata ([Date] [Time] already
        // tells photos apart); if names still collide, the duplicate check says so.
        if numbered, !template.contains("#"), !BatchRenameToken.usesMetadata(template) {
            template += " #"
        }

        var result = ""
        var digits = 0

        func flushDigits() {
            guard digits > 0 else { return }
            let number = String(index)
            result += number.count >= digits
                ? number
                : String(repeating: "0", count: digits - number.count) + number
            digits = 0
        }

        let characters = Array(template)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            switch character {
            case "#":
                digits += 1
            case "*":
                flushDigits()
                result += base
            case "[":
                flushDigits()
                // A `[Token]`: replaced by its value; an unknown word in brackets is text.
                if let close = characters[position...].firstIndex(of: "]"),
                   let token = BatchRenameToken.allCases.first(where: {
                       $0.rawValue.lowercased() == String(characters[(position + 1)..<close]).lowercased()
                   }) {
                    if let value = tokenValue(token, metadata) {
                        result += value
                    } else if missing == nil {
                        missing = token
                    }
                    position = close
                } else {
                    result.append(character)
                }
            default:
                flushDigits()
                result.append(character)
            }
            position += 1
        }
        flushDigits()

        return (ext.isEmpty ? result : result + "." + ext, missing)
    }

    private static func tokenValue(_ token: BatchRenameToken, _ metadata: FileMetadata) -> String? {
        switch token {
        case .date:
            return (metadata.captureDate ?? metadata.fallbackDate).map { dateFormatter.string(from: $0) }
        case .time:
            return (metadata.captureDate ?? metadata.fallbackDate).map { timeFormatter.string(from: $0) }
        case .track:
            return metadata.track.map { $0 < 10 ? "0\($0)" : "\($0)" }
        case .artist: return metadata.artist.flatMap(safeText)
        case .title: return metadata.title.flatMap(safeText)
        case .album: return metadata.album.flatMap(safeText)
        }
    }

    /// Tag text can hold characters a file name can't ("AC/DC", "Live: 1999").
    private static func safeText(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 2026-10-03 and 12.28.04: sortable, and no ":" (Finder shows it as "/").
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH.mm.ss"
        return f
    }()

    /// Case applies to the name part; the extension only follows "lowercase extension".
    private static func applyCase(to name: String, settings: BatchRenameSettings) -> String {
        guard settings.nameCase != .unchanged || settings.lowercaseExtension else { return name }
        let ns = name as NSString
        var base = ns.deletingPathExtension
        var ext = ns.pathExtension
        // ".hidden" has no extension in this sense: deletingPathExtension leaves it whole.
        switch settings.nameCase {
        case .unchanged: break
        case .lowercase: base = base.lowercased()
        case .uppercase: base = base.uppercased()
        case .capitalized: base = base.capitalized
        }
        if settings.lowercaseExtension { ext = ext.lowercased() }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Works on the FULL name, extension included — like Finder's "Replace Text". An
    /// empty search string changes nothing: otherwise the replacement would be
    /// inserted between every pair of characters.
    private static func applyFindReplace(to name: String, find: String, replace: String) -> String {
        guard !find.isEmpty else { return name }
        return name.replacingOccurrences(of: find, with: replace)
    }
}
