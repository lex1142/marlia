import Foundation

/// Fuzzy matching for the command palette: "nf" finds "New Folder", "sbn" finds
/// "Sort By › Name". The query's characters must appear in the candidate in order (case and
/// spaces ignored); the score prefers matches at word starts and runs of consecutive
/// characters, so the result an experienced user is typing toward rises to the top.
///
/// Foundation only, on purpose: a scratchpad script can compile and exercise it directly
/// (see the verification section in CLAUDE.md).
enum FuzzyMatch {

    /// nil when the candidate doesn't contain the query as a subsequence; otherwise a score,
    /// higher is better. An empty query matches everything with score 0.
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(candidate)
        let lower = Array(candidate.lowercased())
        // lowercased() can change the length for a few exotic characters; then fall back to
        // comparing against the original, which keeps indices aligned.
        let hay = lower.count == original.count ? lower : original

        var position = 0
        var score = 0
        var previous = -2
        var first = -1
        for (index, character) in hay.enumerated() where position < needle.count {
            guard character == needle[position] else { continue }
            var gain = 1
            if index == previous + 1 { gain += 5 }                 // a run: "fol" in "Folder"
            if isWordStart(original, index) { gain += 8 }          // "nf" → New Folder
            score += gain
            previous = index
            if first < 0 { first = index }
            position += 1
        }
        guard position == needle.count else { return nil }
        // Earlier matches and shorter candidates win ties.
        return score - first - hay.count / 12
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        if index == 0 { return true }
        let before = characters[index - 1]
        let current = characters[index]
        if !before.isLetter && !before.isNumber { return true }
        return current.isUppercase && before.isLowercase      // camelCase boundary
    }

    /// Ranks candidates for a query: the best score first, ties in the original order.
    /// `title` is what the user sees; `context` (the menu path) also matches, but a match in
    /// the title counts for more.
    static func rank<T>(_ items: [T], query: String, title: (T) -> String, context: (T) -> String) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        let scored: [(offset: Int, item: T, score: Int)] = items.enumerated().compactMap { offset, item in
            let inTitle = score(trimmed, in: title(item)).map { $0 + 20 }
            // Both orders: people type the way the menu path reads ("sort name" for
            // View › Sort By › Name) as well as title-first ("name sort").
            let pathFirst = score(trimmed, in: context(item) + " " + title(item))
            let titleFirst = score(trimmed, in: title(item) + " " + context(item))
            guard let best = [inTitle, pathFirst, titleFirst].compactMap({ $0 }).max() else { return nil }
            return (offset, item, best)
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
    }
}
