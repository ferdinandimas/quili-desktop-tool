import Foundation

/// The one-click rewrite styles offered as chips next to the ✦ button. Each sends its instruction to the paraphrase
/// endpoint instead of the instruction saved in Settings.
struct Tone {
    let id: String
    let label: String
    let instruction: String

    static let all: [Tone] = [
        Tone(id: "formal", label: "Formal", instruction: "Rewrite it in a formal, professional tone."),
        Tone(id: "casual", label: "Casual", instruction: "Rewrite it in a casual, friendly tone."),
        Tone(id: "shorter", label: "Shorter", instruction: "Make it shorter and more concise, keeping the key points."),
        Tone(id: "grammar", label: "Fix grammar",
             instruction: "Only fix spelling, grammar and punctuation. Keep the wording, tone and length as close to the original as possible."),
    ]
}
