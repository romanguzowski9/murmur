import Foundation

public struct LearnedCorrection: Equatable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Finds words the user fixed by hand in text Murmur inserted (Flow's "Auto-add to dictionary": corrected words are
/// learned automatically). Compares the field right after the paste with its later contents and keeps short
/// replacements of dictated words whose new spelling is unusual (a name, jargon, odd casing), so ordinary rewording
/// is not learned.
public enum CorrectionLearner {
    struct Token {
        var text: String
        var index: Int
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "+#@&"))) }
            .filter { !$0.isEmpty }
    }

    struct Hunk {
        var start: Int  // index of the first deleted baseline token
        var deleted: [String] = []
        var inserted: [String] = []
    }

    /// Word-level LCS diff of `a` against `b`, as replacement hunks.
    static func diff(_ a: [String], _ b: [String]) -> [Hunk] {
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var current: Hunk?
        var i = 0, j = 0
        func flush() {
            if let h = current, !(h.deleted.isEmpty && h.inserted.isEmpty) { hunks.append(h) }
            current = nil
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush()
                i += 1
                j += 1
            } else if j >= m || (i < n && dp[i + 1][j] >= dp[i][j + 1]) {
                if current == nil { current = Hunk(start: i) }
                current?.deleted.append(a[i])
                i += 1
            } else {
                if current == nil { current = Hunk(start: i) }
                current?.inserted.append(b[j])
                j += 1
            }
        }
        flush()
        return hunks
    }

    /// - Parameters:
    ///   - baseline: field contents right after Murmur pasted `inserted`.
    ///   - inserted: the text Murmur pasted.
    ///   - insertedAt: UTF-16 offset of `inserted` in `baseline`.
    ///   - current: field contents now.
    ///   - isUnusual: whether a corrected word is worth learning (not an ordinary dictionary word).
    public static func corrections(baseline: String, inserted: String, insertedAt: Int, current: String,
                                   isUnusual: (String) -> Bool) -> [LearnedCorrection] {
        let ns = baseline as NSString
        guard insertedAt >= 0, insertedAt <= ns.length else { return [] }
        let before = tokens(ns.substring(to: insertedAt))
        let dictated = tokens(inserted)
        guard !dictated.isEmpty else { return [] }

        // Compare a window around the dictated words to keep the diff small in long documents.
        let margin = 60
        let lo = max(0, before.count - margin)
        let baseTokens = tokens(baseline)
        let hi = min(baseTokens.count, before.count + dictated.count + margin)
        guard lo < hi else { return [] }
        let a = Array(baseTokens[lo..<hi])
        let currentTokens = tokens(current)
        let b = Array(currentTokens[min(lo, currentTokens.count)..<min(currentTokens.count, hi + margin)])
        let dictatedRange = (before.count - lo)..<(before.count - lo + dictated.count)

        var result: [LearnedCorrection] = []
        for hunk in diff(a, b) {
            guard (1...3).contains(hunk.deleted.count), (1...2).contains(hunk.inserted.count),
                  dictatedRange.contains(hunk.start), dictatedRange.contains(hunk.start + hunk.deleted.count - 1)
            else { continue }
            let from = hunk.deleted.joined(separator: " ")
            let to = hunk.inserted.joined(separator: " ")
            guard from != to, to.count <= 40, hunk.inserted.contains(where: isUnusual) else { continue }
            // A pure case change only matters when it adds capitals ("wispr" -> "Wispr").
            if from.lowercased() == to.lowercased(), !to.contains(where: \.isUppercase) { continue }
            let correction = LearnedCorrection(from: from, to: to)
            if !result.contains(correction) { result.append(correction) }
        }
        return result
    }

    /// Adds corrections to the dictionary, merging with existing entries. Returns the entries that changed.
    @discardableResult
    public static func merge(_ corrections: [LearnedCorrection], into dictionary: inout [DictionaryEntry]) -> [String] {
        var changed: [String] = []
        for c in corrections {
            if let i = dictionary.firstIndex(where: { $0.word == c.to }) {
                var misspellings = dictionary[i].misspellings ?? []
                if c.from.lowercased() != c.to.lowercased(),
                   !misspellings.contains(where: { $0.lowercased() == c.from.lowercased() }) {
                    misspellings.append(c.from)
                    dictionary[i].misspellings = misspellings
                    changed.append(c.to)
                }
            } else {
                let misspellings = c.from.lowercased() == c.to.lowercased() ? nil : [c.from]
                dictionary.append(DictionaryEntry(word: c.to, misspellings: misspellings, learned: true))
                changed.append(c.to)
            }
        }
        return changed
    }
}
