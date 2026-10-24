import Foundation

/// The rewrite tones (the Tone button's bar and the chips in Settings). The selected one is a setting. A tone never
/// replaces the built-in paraphrase instruction (`Settings.baseInstruction`): its adjustment is appended to it, so the
/// base (grammar, flow, "keep the wording close") still applies and only the tone changes.
struct Tone {
    let id: String
    let label: String
    /// The line appended to the base instruction, after a blank line.
    let adjustment: String

    static let all: [Tone] = [
        Tone(id: "formal", label: "Formal",
             adjustment: "Tone adjustment: use a formal, professional tone, even if the instruction above says to avoid being formal. Keep everything else above."),
        Tone(id: "casual", label: "Casual",
             adjustment: "Tone adjustment: use a casual, friendly, relaxed tone. Keep everything else above."),
        Tone(id: "shorter", label: "Shorter",
             adjustment: "Tone adjustment: make it shorter and more concise, keeping the key points. Keep everything else above."),
        Tone(id: "grammar", label: "Fix grammar",
             adjustment: "Tone adjustment: only fix spelling, grammar and punctuation, keeping the wording, tone and length as close to the original as possible. Keep everything else above."),
    ]

    private static let separator = "\n\n"

    /// `base` followed by this tone's adjustment, within `limit` characters (the base is cut, never the adjustment).
    func applied(to base: String, limit: Int = Settings.maxStyleLength) -> String {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = Self.separator + adjustment
        if text.count + tail.count > limit { text = String(text.prefix(max(0, limit - tail.count))).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.isEmpty ? adjustment : text + tail
    }

    static func find(_ id: String) -> Tone? { all.first { $0.id == id } }
}
