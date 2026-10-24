using System;
using System.Collections.Generic;
using System.Globalization;

namespace Quili.Core
{
    /// <summary>
    /// A word-level diff for the review bubble: which parts of the rewritten text differ from the original.
    /// Both texts are split into tokens (a run of letters/digits, a single other non-whitespace character, or a run of
    /// whitespace) and compared with a longest-common-subsequence match; every word or mark of the result that is not
    /// part of that match is "changed". Whitespace is never highlighted by itself, but whitespace between two changed
    /// tokens is, so neighbouring changes merge into one range.
    /// </summary>
    public static class TextDiff
    {
        /// <summary>Above this many token pairs the diff is skipped (no highlight) to keep the preview instant.</summary>
        const long MaxCells = 4_000_000;

        readonly record struct Token(int Start, int Length, bool Space);

        /// <summary>Ranges (UTF-16 offsets, in <paramref name="result"/>) of the parts that differ from <paramref name="original"/>.</summary>
        public static List<(int Start, int Length)> ChangedRanges(string original, string result)
        {
            var ranges = new List<(int Start, int Length)>();
            var a = Tokenize(original);
            var b = Tokenize(result);
            if (b.Count == 0 || (long)a.Count * b.Count > MaxCells) return ranges;

            int n = a.Count, m = b.Count;
            var aText = new string[n];
            var bText = new string[m];
            for (int i = 0; i < n; i++) aText[i] = original.Substring(a[i].Start, a[i].Length);
            for (int j = 0; j < m; j++) bText[j] = result.Substring(b[j].Start, b[j].Length);

            // lcs[i, j] = length of the longest common subsequence of a[i..] and b[j..].
            var lcs = new int[n + 1, m + 1];
            for (int i = n - 1; i >= 0; i--)
                for (int j = m - 1; j >= 0; j--)
                    lcs[i, j] = aText[i] == bText[j] ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

            // Walk both token lists: equal tokens are matched; otherwise skip in the original when that keeps the longer
            // match (ties too), else the result token is new.
            var matched = new bool[m];
            for (int i = 0, j = 0; i < n && j < m;)
            {
                if (aText[i] == bText[j]) { matched[j] = true; i++; j++; }
                else if (lcs[i + 1, j] >= lcs[i, j + 1]) i++;
                else j++;
            }

            int? rangeStart = null;
            int rangeEnd = 0;
            for (int j = 0; j < m; j++)
            {
                var token = b[j];
                if (token.Space) continue; // neutral: stays inside an open range, never opens or closes one
                if (!matched[j])
                {
                    rangeStart ??= token.Start;
                    rangeEnd = token.Start + token.Length;
                }
                else if (rangeStart is int start)
                {
                    ranges.Add((start, rangeEnd - start));
                    rangeStart = null;
                }
            }
            if (rangeStart is int last) ranges.Add((last, rangeEnd - last));
            return ranges;
        }

        static List<Token> Tokenize(string s)
        {
            var tokens = new List<Token>();
            int i = 0;
            while (i < s.Length)
            {
                int start = i;
                char c = s[i];
                if (char.IsWhiteSpace(c))
                {
                    while (i < s.Length && char.IsWhiteSpace(s[i])) i++;
                    tokens.Add(new Token(start, i - start, true));
                }
                else if (IsWordChar(c))
                {
                    while (i < s.Length && IsWordChar(s[i])) i++;
                    tokens.Add(new Token(start, i - start, false));
                }
                else
                {
                    // A single other character; an emoji written as a surrogate pair stays one token.
                    i += char.IsHighSurrogate(c) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]) ? 2 : 1;
                    tokens.Add(new Token(start, i - start, false));
                }
            }
            return tokens;
        }

        /// <summary>Letters and digits, plus combining marks so an accent stays attached to its letter.</summary>
        static bool IsWordChar(char c) =>
            char.IsLetterOrDigit(c)
            || CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark;
    }
}
