using System;
using System.Collections.Generic;
using System.Linq;

namespace Quili.Core
{
    /// <summary>
    /// The paraphrase tones (the Tone button's bar and the chips in Settings). The selected tone is a setting; it never
    /// replaces the built-in instruction: its adjustment is appended to it, so that instruction (grammar, flow, "keep
    /// the wording close") still applies and only the tone changes.
    /// </summary>
    public static class Tone
    {
        const string Separator = "\n\n";

        /// <summary>Adjustment: the line appended to the base instruction, after a blank line.</summary>
        public sealed record Preset(string Id, string Label, string Adjustment)
        {
            /// <summary>
            /// <paramref name="baseInstruction"/> followed by this tone's adjustment, within <paramref name="limit"/> characters
            /// (the base is cut, never the adjustment).
            /// </summary>
            public string AppliedTo(string baseInstruction, int limit = Settings.MaxStyleLength)
            {
                var text = baseInstruction.Trim();
                var tail = Separator + Adjustment;
                if (text.Length + tail.Length > limit) text = text[..Math.Max(0, limit - tail.Length)].Trim();
                return text.Length == 0 ? Adjustment : text + tail;
            }
        }

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

        /// <summary>The preset with this id, or null (empty or unknown ids mean "no tone").</summary>
        public static Preset? FindById(string? id) => Presets.FirstOrDefault(p => p.Id == id);

        /// <summary>The index of the preset with this id in <see cref="Presets"/>, or null.</summary>
        public static int? IndexOf(string? id)
        {
            for (int i = 0; i < Presets.Count; i++) if (Presets[i].Id == id) return i;
            return null;
        }
    }
}
