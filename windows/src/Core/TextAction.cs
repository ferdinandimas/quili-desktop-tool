namespace Quili.Core
{
    /// <summary>
    /// What the server can be asked to do with text: the overlay's buttons act on the focused field, and the
    /// Summarize button next to Slack's own summarizes a chat thread read from another app's window.
    /// </summary>
    public enum TextAction
    {
        /// <summary>Rewrite in the same language, following the Paraphrase instruction from Settings.</summary>
        Paraphrase,

        /// <summary>Translate into natural, paraphrased English whatever the original language.</summary>
        TranslateToEnglish,

        /// <summary>Summarize the Slack thread that is open in the Slack window (never written back to a field).</summary>
        SummarizeThread,

        /// <summary>Summarize any selected text (the pill's Summarize cell, or the tray item); never written back to a field.</summary>
        SummarizeText,
    }

    public static class TextActionInfo
    {
        public static string Verb(this TextAction action) => action switch
        {
            TextAction.TranslateToEnglish => "Translate",
            TextAction.SummarizeThread => "Summarize",
            TextAction.SummarizeText => "Summarize",
            _ => "Paraphrase",
        };

        /// <summary>A summary (of a thread or of selected text): no instruction is sent, nothing is replaced, secrets are only relabelled.</summary>
        public static bool IsSummary(this TextAction action) => action is TextAction.SummarizeThread or TextAction.SummarizeText;

        public static string Path(this TextAction action) => action switch
        {
            TextAction.TranslateToEnglish => "/api/translate",
            TextAction.SummarizeThread => "/api/summarize-thread",
            TextAction.SummarizeText => "/api/summarize-text",
            _ => "/api/paraphrase",
        };
    }
}
