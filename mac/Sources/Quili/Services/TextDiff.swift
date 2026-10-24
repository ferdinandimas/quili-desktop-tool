import Foundation

/// Which words of a rewrite differ from the original text: the review bubble highlights them in soft blue.
/// Windows has the same algorithm in `Core/TextDiff.cs`; keep the two in step.
enum TextDiff {
    /// Above this many token pairs the diff is skipped (no highlight) to keep the UI responsive.
    private static let maxCells = 4_000_000

    private struct Token {
        let text: String
        let start: Int      // UTF-16 offset
        let length: Int     // UTF-16 length
        let isSpace: Bool
    }

    /// A token is a run of letters/digits, a run of whitespace, or any other single character.
    private static func tokens(_ s: String) -> [Token] {
        enum Kind { case word, space, other }
        func kind(_ c: Character) -> Kind { c.isWhitespace ? .space : (c.isLetter || c.isNumber ? .word : .other) }
        var result: [Token] = []
        var run = ""
        var runKind: Kind?
        var runStart = 0, offset = 0
        func flush() {
            guard let runKind, !run.isEmpty else { return }
            result.append(Token(text: run, start: runStart, length: run.utf16.count, isSpace: runKind == .space))
            run = ""
        }
        for c in s {
            let k = kind(c)
            if k == .other {
                flush(); runKind = nil
                result.append(Token(text: String(c), start: offset, length: c.utf16.count, isSpace: false))
            } else {
                if runKind != k { flush(); runKind = k; runStart = offset }
                run.append(c)
            }
            offset += c.utf16.count
        }
        flush()
        return result
    }

    /// Ranges (UTF-16, in `result`) of the words that are not part of the longest common token sequence with
    /// `original`; changed words separated only by whitespace merge into one range.
    static func changedRanges(original: String, result: String) -> [NSRange] {
        let a = tokens(original), b = tokens(result)
        guard !b.isEmpty else { return [] }
        let n = a.count, m = b.count
        guard n * m <= maxCells else { return [] }

        // lcs[i][j]: length of the LCS of a[i...] and b[j...]
        var lcs = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * w + j] = a[i].text == b[j].text ? lcs[(i + 1) * w + j + 1] + 1 : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var matched = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i].text == b[j].text { matched[j] = true; i += 1; j += 1 }
            else if lcs[(i + 1) * w + j] >= lcs[i * w + j + 1] { i += 1 }
            else { j += 1 }
        }

        var ranges: [NSRange] = []
        var current: (start: Int, end: Int)?
        for (index, token) in b.enumerated() where !token.isSpace {
            if matched[index] {
                if let c = current { ranges.append(NSRange(location: c.start, length: c.end - c.start)); current = nil }
            } else if let c = current {
                current = (c.start, token.start + token.length)
            } else {
                current = (token.start, token.start + token.length)
            }
        }
        if let c = current { ranges.append(NSRange(location: c.start, length: c.end - c.start)) }
        return ranges
    }
}
