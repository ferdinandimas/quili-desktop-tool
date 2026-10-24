using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Quili.Platform;

namespace Quili.Core
{
    public class Settings
    {
        /// <summary>Quili's built-in paraphrase instruction; the selected <see cref="Tone"/> is added to it. Lives only in code.</summary>
        public const string BaseInstruction =
            "Polish the provided text to improve grammar, verb tenses, clarity, and natural flow while preserving the original meaning, tone, and intent.\n\nKeep the wording and sentence structure as close to the original as possible, making only necessary adjustments. Use natural, conversational English without making it overly formal or complicated.\n\nReturn only the revised text, without explanations or additional commentary.";
        /// <summary>The server accepts an instruction of at most this many characters.</summary>
        public const int MaxStyleLength = 1000;

        public string ApiKeyProtected { get; set; } = "";
        public string ServerUrl { get; set; } = "";

        /// <summary>The id of the selected paraphrase tone (see <see cref="Core.Tone"/>); empty = no tone, the built-in instruction as it is.</summary>
        public string Tone { get; set; } = "";
        public bool RunAtStartup { get; set; }

        /// <summary>Whether <see cref="DebugLog"/> writes anything (the "Write debug log" setting); on by default.</summary>
        public bool LoggingEnabled { get; set; } = true;

        /// <summary>Offline demo: every request goes to the built-in <see cref="MockServer"/> instead of the real server.</summary>
        public bool MockMode { get; set; }

        /// <summary>Privacy: keys, tokens and passwords are swapped for placeholders before the text is sent, and restored after.</summary>
        public bool RedactSecrets { get; set; } = true;

        /// <summary>Privacy: email addresses are hidden the same way (off by default).</summary>
        public bool RedactEmails { get; set; }

        /// <summary>"hide" (the default): no button in the apps listed. "only": the button shows only in the listed apps.</summary>
        public string AppFilterMode { get; set; } = AppFilter.HideMode;

        /// <summary>Process names, one per line (see <see cref="AppFilter"/>).</summary>
        public string AppFilterList { get; set; } = "";

        static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Quili");
        static readonly string FilePath = Path.Combine(Dir, "settings.json");
        // Quili was called "Paraphrase Tool" before; its settings live here.
        static readonly string LegacyFilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ParaphraseTool", "settings.json");

        [JsonIgnore]
        public string ApiKey
        {
            get
            {
                if (string.IsNullOrEmpty(ApiKeyProtected)) return "";
                try
                {
                    var bytes = ProtectedData.Unprotect(
                        Convert.FromBase64String(ApiKeyProtected), null, DataProtectionScope.CurrentUser);
                    return Encoding.UTF8.GetString(bytes);
                }
                catch (CryptographicException) { return ""; }
            }
            set
            {
                ApiKeyProtected = string.IsNullOrEmpty(value)
                    ? ""
                    : Convert.ToBase64String(ProtectedData.Protect(
                        Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
            }
        }

        /// <summary>The instruction sent to the server as the paraphrase command: the built-in one, with the selected tone's adjustment added (never empty, length-capped).</summary>
        [JsonIgnore]
        public string EffectiveStyle
        {
            get
            {
                var preset = Core.Tone.FindById(Tone);
                var s = preset == null ? BaseInstruction : preset.AppliedTo(BaseInstruction);
                return s.Length > MaxStyleLength ? s[..MaxStyleLength] : s;
            }
        }

        /// <summary>First launch after the rename: carry the old app's settings (server URL, API key, startup entry) over.</summary>
        static void MigrateFromParaphraseTool()
        {
            try
            {
                if (File.Exists(FilePath) || !File.Exists(LegacyFilePath)) return;
                Directory.CreateDirectory(Dir);
                File.Copy(LegacyFilePath, FilePath); // the API key is DPAPI-protected per user, so it still decrypts
                StartupRegistration.MigrateLegacy();
                DebugLog.Write("migrated settings from the old Paraphrase Tool app");
            }
            catch (Exception) { }
        }

        public static Settings Load()
        {
            MigrateFromParaphraseTool();
            try
            {
                if (File.Exists(FilePath))
                {
                    // An old "style" entry (the instruction box that no longer exists) is simply ignored.
                    return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
                }
            }
            catch (Exception) { }
            return new Settings();
        }

        public void Save()
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            StartupRegistration.Apply(RunAtStartup);
        }
    }
}
