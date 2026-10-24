import Foundation

/// What the pill suggests for the text in the focused field: translate it (it does not look like English) or summarize
/// it (it is long). Decided on this computer from the text alone; nothing is sent. Windows has the same rules in
/// `Core/LanguageHint.cs`; keep the two in step.
enum ActionSuggestion: Equatable {
    case none, translate, summarize

    static func forText(_ text: String) -> ActionSuggestion { LanguageHint.suggestion(for: text) }
}

enum LanguageHint {
    /// Shorter text is not worth a hint.
    static let minLength = 20
    /// From this many characters the pill suggests Summarize.
    static let longLength = 800

    /// Common English function words: Indonesian and most other Latin-script languages hardly use them.
    private static let english: Set<String> = [
        "the", "and", "is", "are", "was", "were", "to", "of", "in", "that", "for", "it", "with", "as", "on", "be", "at", "by",
        "this", "have", "has", "had", "from", "or", "an", "not", "but", "you", "we", "they", "he", "she", "will", "would",
        "can", "could", "should", "do", "does", "did", "if", "so", "my", "your", "our", "their", "there", "what", "which",
        "who", "when", "where", "how", "just", "about", "please", "thanks", "thank", "hi", "hello", "been", "also", "than",
        "then", "them", "these", "those", "its", "i",
    ]

    static func suggestion(for text: String) -> ActionSuggestion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count >= minLength else { return .none }
        if isLikelyNotEnglish(trimmed) { return .translate }
        return trimmed.utf16.count >= longLength ? .summarize : .none
    }

    /// Text outside the Latin alphabets, or with hardly any common English words, is probably not English.
    static func isLikelyNotEnglish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count >= minLength else { return false }
        var letters = 0, nonLatin = 0
        for scalar in trimmed.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if scalar.value > 0x24F { nonLatin += 1 }
        }
        if letters > 0, Double(nonLatin) / Double(letters) > 0.3 { return true }

        var words = 0, englishWords = 0
        var word = ""
        func finish() {
            if word.count >= 2 {
                words += 1
                if english.contains(word.lowercased()) { englishWords += 1 }
            }
            word = ""
        }
        for ch in trimmed {
            if ch.isLetter { word.append(ch) } else { finish() }
        }
        finish()
        guard words >= 6 else { return false }
        return Double(englishWords) / Double(words) < 0.12
    }
}
