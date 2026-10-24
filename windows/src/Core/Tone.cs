using System.Collections.Generic;
using System.Linq;

namespace Quili.Core
{
    /// <summary>The one-click tone presets in the pill's chip bar; each is sent as the paraphrase instruction instead of the saved one.</summary>
    public static class Tone
    {
        public sealed record Preset(string Id, string Label, string Instruction);

        public static readonly IReadOnlyList<Preset> Presets = new[]
        {
            new Preset("formal", "Formal", "Rewrite it in a formal, professional tone."),
            new Preset("casual", "Casual", "Rewrite it in a casual, friendly tone."),
            new Preset("shorter", "Shorter", "Make it shorter and more concise, keeping the key points."),
            new Preset("grammar", "Fix grammar",
                "Only fix spelling, grammar and punctuation. Keep the wording, tone and length as close to the original as possible."),
        };

        public static IReadOnlyList<string> Labels => Presets.Select(p => p.Label).ToArray();
    }
}
