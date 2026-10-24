using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Quili.Core
{
    /// <summary>
    /// The last 10 rewrites (paraphrase, translate, summaries), newest first, kept in <c>%APPDATA%\Quili\history.json</c>
    /// when the "Keep my last 10 rewrites" setting is on. A missing or damaged file counts as an empty list.
    /// </summary>
    public static class HistoryStore
    {
        public const int MaxEntries = 10, MaxOriginalChars = 2000, MaxResultChars = 20000;

        public sealed class Entry
        {
            [JsonPropertyName("id")] public string Id { get; set; } = "";
            /// <summary>ISO-8601, UTC.</summary>
            [JsonPropertyName("time")] public string Time { get; set; } = "";
            /// <summary>"paraphrase", "translate" or "summarize".</summary>
            [JsonPropertyName("kind")] public string Kind { get; set; } = "";
            /// <summary>Process name of the foreground app when the request ran (for example "slack"), or null.</summary>
            [JsonPropertyName("app")] public string? App { get; set; }
            [JsonPropertyName("original")] public string Original { get; set; } = "";
            [JsonPropertyName("result")] public string Result { get; set; } = "";
        }

        static readonly object Gate = new();
        static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Quili", "history.json");

        /// <summary>The stored entries, newest first.</summary>
        public static List<Entry> Load()
        {
            lock (Gate) return LoadUnlocked();
        }

        /// <summary>Adds an entry at the top (the original cut to 2000 characters, the result to 20000) and drops the oldest beyond 10.</summary>
        public static void Add(string kind, string? app, string original, string result)
        {
            lock (Gate)
            {
                var entries = LoadUnlocked();
                entries.Insert(0, new Entry
                {
                    Id = Guid.NewGuid().ToString(),
                    Time = DateTime.UtcNow.ToString("o", System.Globalization.CultureInfo.InvariantCulture),
                    Kind = kind,
                    App = string.IsNullOrWhiteSpace(app) ? null : app,
                    Original = original.Length > MaxOriginalChars ? original[..MaxOriginalChars] + "…" : original,
                    Result = result.Length > MaxResultChars ? result[..MaxResultChars] : result,
                });
                SaveUnlocked(entries.Take(MaxEntries).ToList());
            }
        }

        public static void Clear()
        {
            lock (Gate)
            {
                try { if (File.Exists(FilePath)) File.Delete(FilePath); }
                catch (Exception ex) { DebugLog.Write($"clearing the history failed: {ex.GetType().Name}"); }
            }
        }

        static List<Entry> LoadUnlocked()
        {
            try
            {
                if (File.Exists(FilePath))
                    return (JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(FilePath)) ?? new List<Entry>())
                        .Take(MaxEntries).ToList();
            }
            catch (Exception) { }
            return new List<Entry>();
        }

        static void SaveUnlocked(List<Entry> entries)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(entries, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { DebugLog.Write($"saving the history failed: {ex.GetType().Name}"); }
        }
    }
}
