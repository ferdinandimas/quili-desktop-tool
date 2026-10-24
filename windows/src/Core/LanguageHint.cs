using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Quili.Core
{
    /// <summary>The button the pill suggests for the text in the focused field: Translate (it does not look like English) or Summarize (it is long).</summary>
    public enum ActionSuggestion { None, Translate, Summarize }

    /// <summary>
    /// Decides on this computer, from the text alone, which button is the likely next step; nothing is sent. The macOS app has
    /// the same rules in <c>Services/LanguageHint.swift</c>; keep the two in step.
    /// </summary>
    public static class LanguageHint
    {
        /// <summary>Shorter text is not worth a hint.</summary>
        public const int MinLength = 20;
        /// <summary>From this many characters the pill suggests Summarize.</summary>
        public const int LongLength = 800;

        /// <summary>Common English function words: Indonesian and most other Latin-script languages hardly use them.</summary>
        static readonly HashSet<string> English = new()
        {
            "the", "and", "is", "are", "was", "were", "to", "of", "in", "that", "for", "it", "with", "as", "on", "be", "at", "by",
            "this", "have", "has", "had", "from", "or", "an", "not", "but", "you", "we", "they", "he", "she", "will", "would",
            "can", "could", "should", "do", "does", "did", "if", "so", "my", "your", "our", "their", "there", "what", "which",
            "who", "when", "where", "how", "just", "about", "please", "thanks", "thank", "hi", "hello", "been", "also", "than",
            "then", "them", "these", "those", "its", "i",
        };

        public static ActionSuggestion SuggestionFor(string text)
        {
            var trimmed = text.Trim();
            if (trimmed.Length < MinLength) return ActionSuggestion.None;
            if (IsLikelyNotEnglish(trimmed)) return ActionSuggestion.Translate;
            return trimmed.Length >= LongLength ? ActionSuggestion.Summarize : ActionSuggestion.None;
        }

        /// <summary>Text outside the Latin alphabets, or with hardly any common English words, is probably not English.</summary>
        public static bool IsLikelyNotEnglish(string text)
        {
            var trimmed = text.Trim();
            if (trimmed.Length < MinLength) return false;

            int letters = 0, nonLatin = 0;
            foreach (var rune in trimmed.EnumerateRunes())
            {
                if (!Rune.IsLetter(rune)) continue;
                letters++;
                if (rune.Value > 0x24F) nonLatin++;
            }
            if (letters > 0 && (double)nonLatin / letters > 0.3) return true;

            int words = 0, englishWords = 0;
            var word = new StringBuilder();
            void Finish()
            {
                if (word.Length >= 2)
                {
                    words++;
                    if (English.Contains(word.ToString().ToLowerInvariant())) englishWords++;
                }
                word.Clear();
            }
            foreach (var rune in trimmed.EnumerateRunes())
            {
                if (Rune.IsLetter(rune)) word.Append(rune.ToString());
                else Finish();
            }
            Finish();
            if (words < 6) return false;
            return (double)englishWords / words < 0.12;
        }
    }
}
