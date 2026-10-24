import Foundation

/// Hides secrets in text before it leaves the machine. Each secret is swapped for an opaque placeholder
/// (`QXKEY1QX`), the model is told to copy such identifiers as they are, and the originals are put back into the
/// answer afterwards. Summaries only get a label, so a secret never reappears in text that is shared.
enum Redactor {
    struct Masked {
        let text: String
        /// `values[i]` is the original behind placeholder number `i + 1`.
        let values: [String]
    }

    private struct Rule {
        let pattern: String
        let group: Int // 0 hides the whole match, otherwise just that capture group
        let isEmail: Bool
    }

    // Applied in this order. The same patterns are used by the Windows app (windows/src/Core/Redactor.cs).
    private static let rules: [Rule] = [
        Rule(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, group: 0, isEmail: false),
        Rule(pattern: #"\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s:/@]+:([^\s@/]+)@"#, group: 1, isEmail: false),
        Rule(pattern: #"(?i)\bbearer\s+([A-Za-z0-9._~+/\-]{16,}=*)"#, group: 1, isEmail: false),
        Rule(pattern: #"\b(?:(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"#, group: 0, isEmail: false),
        Rule(pattern: #"(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|token)\b\s*[:=]\s*["']?([^\s"']{4,})"#, group: 1, isEmail: false),
        Rule(pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b"#, group: 0, isEmail: true),
    ]

    static func placeholder(_ number: Int) -> String { "QXKEY\(number)QX" }

    /// `startingAt` numbers the placeholders from there instead of 1, so a second text (the conversation context) can
    /// be masked after the first without reusing its numbers.
    static func mask(_ text: String, emails: Bool, startingAt first: Int = 1) -> Masked {
        var current = text
        var values: [String] = []
        for rule in rules where emails || !rule.isEmail {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let source = current as NSString
            var edits: [(range: NSRange, number: Int)] = []
            for match in regex.matches(in: current, range: NSRange(location: 0, length: source.length)) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let original = source.substring(with: range)
                if original.contains("QXKEY") { continue } // already a placeholder
                let number: Int
                if let known = values.firstIndex(of: original) { number = known + first }
                else { values.append(original); number = values.count - 1 + first }
                edits.append((range, number))
            }
            let result = NSMutableString(string: current)
            for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: placeholder(edit.number)) }
            current = result as String
        }
        return Masked(text: current, values: values)
    }

    /// Puts the originals back. `allPresent` is false when a placeholder the model was given no longer occurs in the
    /// text, which means the model dropped or altered a protected value.
    static func restore(_ text: String, values: [String]) -> (text: String, allPresent: Bool) {
        var result = text
        var allPresent = true
        for (index, value) in values.enumerated() {
            let token = placeholder(index + 1)
            if !result.contains(token) { allPresent = false; continue }
            result = result.replacingOccurrences(of: token, with: value)
        }
        return (result, allPresent)
    }

    /// For summaries: `QXKEY3QX` becomes `[hidden value 3]`.
    static func relabel(_ text: String) -> String {
        text.replacingOccurrences(of: #"QXKEY(\d+)QX"#, with: "[hidden value $1]", options: .regularExpression)
    }
}
