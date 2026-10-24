using System;
using System.Collections.Generic;
using System.Linq;

namespace Quili.Core
{
    /// <summary>
    /// The one-click tones (the Tone button's bar and the chips in Settings). A tone never replaces the paraphrase
    /// instruction: its adjustment is appended to it, so the base instruction (grammar, flow, "keep the wording close")
    /// still applies and only the tone changes.
    /// </summary>
    public static class Tone
    {
        /// <summary>Adjustment: the line appended to the base instruction, after a blank line.</summary>
        public sealed record Preset(string Id, string Label, string Adjustment)
        {
            /// <summary>
            /// <paramref name="baseInstruction"/> followed by this tone's adjustment, within <paramref name="limit"/> characters
            /// (the base is cut, never the adjustment). A tone adjustment already at the end of the base is replaced.
            /// </summary>
            public string AppliedTo(string baseInstruction, int limit = Settings.MaxStyleLength)
            {
                var text = RemoveAdjustment(baseInstruction).Trim();
                var tail = Separator + Adjustment;
                if (text.Length + tail.Length > limit) text = text[..Math.Max(0, limit - tail.Length)].Trim();
                return text.Length == 0 ? Adjustment : text + tail;
            }

            /// <summary>Whether <paramref name="text"/> ends with this tone's adjustment.</summary>
            public bool IsAppliedTo(string text) => text.Trim().EndsWith(Separator + Adjustment, StringComparison.Ordinal);
        }

        const string Separator = "\n\n";

        public static readonly IReadOnlyList<Preset> Presets = new[]
        {
            new Preset("formal", "Formal",
                "Tone adjustment: use a formal, professional tone, even if the instruction above says to avoid being formal. Keep everything else above."),
            new Preset("casual", "Casual",
                "Tone adjustment: use a casual, friendly, relaxed tone. Keep everything else above."),
            new Preset("shorter", "Shorter",
                "Tone adjustment: make it shorter and more concise, keeping the key points. Keep everything else above."),
            new Preset("grammar", "Fix grammar",
                "Tone adjustment: only fix spelling, grammar and punctuation, keeping the wording, tone and length as close to the original as possible. Keep everything else above."),
        };

        public static IReadOnlyList<string> Labels => Presets.Select(p => p.Label).ToArray();

        /// <summary>The text without a tone adjustment at its end (the base instruction).</summary>
        public static string RemoveAdjustment(string text)
        {
            var trimmed = text.Trim();
            foreach (var preset in Presets)
            {
                var tail = Separator + preset.Adjustment;
                if (trimmed.EndsWith(tail, StringComparison.Ordinal)) return trimmed[..^tail.Length];
            }
            return trimmed == text ? text : trimmed;
        }
    }
}
