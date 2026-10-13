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

struct BatchRenameSettings {
    var mode: BatchRenameMode = .pattern
    /// `#` (any number in a row) — a number zero-padded to the group's length,
    /// `*` — the original name without the extension.
    var pattern: String = "*"
    var startIndex: Int = 1
    var find: String = ""
    var replace: String = ""
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

        var message: String {
            switch self {
            case .invalidName: return "Not a valid name"
            case .duplicateInBatch: return "Two items would get this name"
            case .takenInDirectory: return "A file with this name already exists"
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
                      settings: BatchRenameSettings) -> [BatchRenameEntry] {
        var entries: [BatchRenameEntry] = []
        var seen: [String: Int] = [:]   // new name → how many times it occurs

        for (offset, name) in names.enumerated() {
            let newName: String
            switch settings.mode {
            case .pattern:
                newName = applyPattern(to: name,
                                       index: settings.startIndex + offset,
                                       pattern: settings.pattern,
                                       numbered: names.count > 1)
            case .findReplace:
                newName = applyFindReplace(to: name, find: settings.find, replace: settings.replace)
            }
            entries.append(BatchRenameEntry(id: name, originalName: name, newName: newName))
            seen[newName, default: 0] += 1
        }

        for index in entries.indices {
            let entry = entries[index]
            if !isValidName(entry.newName) {
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
    private static func applyPattern(to name: String, index: Int,
                                     pattern: String, numbered: Bool) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var template = pattern
        // Without a `#` group every file would get the same name, so a number is
        // appended automatically. Not for a single file — there a pattern without a
        // number makes sense.
        if numbered, !template.contains("#") {
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

        for character in template {
            switch character {
            case "#":
                digits += 1
            case "*":
                flushDigits()
                result += base
            default:
                flushDigits()
                result.append(character)
            }
        }
        flushDigits()

        return ext.isEmpty ? result : result + "." + ext
    }

    /// Works on the FULL name, extension included — like Finder's "Replace Text". An
    /// empty search string changes nothing: otherwise the replacement would be
    /// inserted between every pair of characters.
    private static func applyFindReplace(to name: String, find: String, replace: String) -> String {
        guard !find.isEmpty else { return name }
        return name.replacingOccurrences(of: find, with: replace)
    }
}
