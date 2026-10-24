using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Quili.Core
{
    /// <summary>
    /// Swaps secrets (keys, tokens, passwords, optionally email addresses) for placeholders like QXKEY1QX before the
    /// text leaves the machine, and puts the originals back into the answer. The same value always gets the same number.
    /// </summary>
    public static class Redactor
    {
        public sealed record Masked(string Text, IReadOnlyList<string> Values);

        const string Marker = "QXKEY";

        sealed record Rule(Regex Pattern, int Group);

        static Regex Re(string pattern, RegexOptions options = RegexOptions.None) => new(pattern, options | RegexOptions.CultureInvariant);

        static readonly Rule[] SecretRules =
        {
            new(Re(@"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"), 0),
            new(Re(@"\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s:/@]+:([^\s@/]+)@"), 1),
            new(Re(@"\bbearer\s+([A-Za-z0-9._~+/\-]{16,}=*)", RegexOptions.IgnoreCase), 1),
            new(Re(@"\b(?:(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"), 0),
            new(Re(@"\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|token)\b\s*[:=]\s*[""']?([^\s""']{4,})", RegexOptions.IgnoreCase), 1),
        };

        static readonly Rule EmailRule = new(Re(@"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b"), 0);

        static readonly Regex PlaceholderPattern = new(@"QXKEY(\d+)QX", RegexOptions.CultureInvariant);

        /// <summary>Replaces every sensitive value in <paramref name="text"/> by a placeholder; <see cref="Masked.Values"/> holds the originals (placeholder n is Values[n - 1]).</summary>
        public static Masked Mask(string text, bool emails)
        {
            var values = new List<string>();
            var rules = new List<Rule>(SecretRules);
            if (emails) rules.Add(EmailRule);

            foreach (var rule in rules)
            {
                var matches = rule.Pattern.Matches(text);
                for (int i = matches.Count - 1; i >= 0; i--) // from the end, so earlier indexes stay valid
                {
                    var g = matches[i].Groups[rule.Group];
                    if (!g.Success || g.Length == 0 || g.Value.Contains(Marker)) continue;
                    int number = values.IndexOf(g.Value) + 1;
                    if (number == 0) { values.Add(g.Value); number = values.Count; }
                    text = text[..g.Index] + Marker + number + "QX" + text[(g.Index + g.Length)..];
                }
            }
            return new Masked(text, values);
        }

        /// <summary>Puts the original values back; <c>AllPresent</c> is false when the AI dropped or altered a placeholder.</summary>
        public static (string Text, bool AllPresent) Restore(string text, IReadOnlyList<string> values)
        {
            bool all = true;
            for (int n = 1; n <= values.Count; n++)
                if (!text.Contains($"{Marker}{n}QX")) { all = false; break; }
            var restored = PlaceholderPattern.Replace(text, m =>
            {
                return int.TryParse(m.Groups[1].Value, out int n) && n >= 1 && n <= values.Count ? values[n - 1] : m.Value;
            });
            return (restored, all);
        }

        /// <summary>For summaries: the placeholders stay hidden, shown as "[hidden value n]".</summary>
        public static string Relabel(string text) => PlaceholderPattern.Replace(text, "[hidden value $1]");
    }
}
