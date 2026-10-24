using System;
using System.Collections.Generic;
using System.Linq;

namespace Quili.Core
{
    /// <summary>
    /// The per-app list behind "Privacy &amp; apps": one process name per line (or comma separated), compared
    /// case-insensitively without ".exe". Lines starting with # are comments.
    /// </summary>
    public static class AppFilter
    {
        public const string HideMode = "hide", OnlyMode = "only";

        public static IReadOnlyList<string> Parse(string? list) =>
            (list ?? "")
                .Split(new[] { '\r', '\n', ',' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(e => e.Trim())
                .Where(e => e.Length > 0 && !e.StartsWith('#'))
                .Select(StripExe)
                .Where(e => e.Length > 0)
                .ToArray();

        static string StripExe(string entry) =>
            entry.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? entry[..^4].Trim() : entry;

        /// <summary>
        /// Whether the button may show in the app known by <paramref name="names"/> (its process name, with and without ".exe").
        /// Mode "only": only listed apps (an empty list means none). Otherwise ("hide"): every app that is not listed.
        /// </summary>
        public static bool Allows(IEnumerable<string> names, string? mode, string? list)
        {
            var entries = Parse(list);
            bool matched = names.Any(n => entries.Any(e => string.Equals(StripExe(n.Trim()), e, StringComparison.OrdinalIgnoreCase)));
            return mode == OnlyMode ? matched : !matched;
        }
    }
}
