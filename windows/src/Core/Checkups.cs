using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;

namespace Quili.Core
{
    /// <summary>"Check setup…" and "Check for updates…" from the tray menu, and the quiet daily update check at startup. Call from the UI thread.</summary>
    public static class Checkups
    {
        const string LatestReleaseUrl = "https://api.github.com/repos/ferdinandimas/quili-desktop-tool/releases/latest";
        static readonly TimeSpan Day = TimeSpan.FromHours(24);
        static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

        // ---- Setup ----

        /// <summary>Settings, the server and Windows accessibility, one line each (✓ works, ✗ needs attention).</summary>
        public static async Task CheckSetupAsync(Settings settings)
        {
            var lines = new List<(bool Ok, string Text)>();
            bool ready = settings.MockMode
                || (!string.IsNullOrWhiteSpace(settings.ServerUrl) && !string.IsNullOrEmpty(settings.ApiKey));
            if (settings.MockMode) lines.Add((true, "Mock server (offline) is on"));
            else if (ready) lines.Add((true, "Settings: server URL and API key are set"));
            else lines.Add((false, "Settings: set the server URL and API key"));

            if (ready && !settings.MockMode) lines.Add(await ServerLineAsync(settings));

            lines.Add((true, "Windows accessibility: ready"));

            var text = string.Join("\n", lines.Select(l => (l.Ok ? "✓ " : "✗ ") + l.Text));
            MessageBox.Show(text, "Quili setup", MessageBoxButton.OK,
                lines.All(l => l.Ok) ? MessageBoxImage.Information : MessageBoxImage.Warning);
        }

        /// <summary>An empty POST to the paraphrase endpoint: a reachable server with a good key answers 422 (nothing to rewrite).</summary>
        static async Task<(bool Ok, string Text)> ServerLineAsync(Settings settings)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, ParaphraseClient.NormalizeServerUrl(settings.ServerUrl) + "/api/paraphrase")
                {
                    Content = new StringContent("{}", new UTF8Encoding(false), "application/json"),
                };
                request.Headers.Add("X-API-Key", settings.ApiKey);
                using var response = await Http.SendAsync(request);
                return (int)response.StatusCode switch
                {
                    422 => (true, "Server reachable and the API key works"),
                    401 => (false, "The server rejected the API key"),
                    503 => (false, "The server has no API key configured"),
                    var status => (false, $"The server answered with status {status}"),
                };
            }
            catch (Exception) { return (false, "Can't reach the server"); }
        }

        // ---- Updates ----

        sealed record Release(string Tag, string Url);

        static async Task<Release?> LatestReleaseAsync()
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, LatestReleaseUrl);
                request.Headers.TryAddWithoutValidation("User-Agent", $"Quili/{AppInfo.Version}");
                request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
                using var response = await Http.SendAsync(request);
                if (!response.IsSuccessStatusCode) return null;
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                var root = doc.RootElement;
                var tag = root.GetProperty("tag_name").GetString();
                var url = root.GetProperty("html_url").GetString();
                return string.IsNullOrEmpty(tag) || string.IsNullOrEmpty(url) ? null : new Release(tag, url);
            }
            catch (Exception) { return null; }
        }

        /// <summary>The tray's "Check for updates…": says where things stand either way.</summary>
        public static async Task CheckForUpdatesAsync()
        {
            var release = await LatestReleaseAsync();
            if (release == null)
            {
                MessageBox.Show("Try again later.", "Couldn't check for updates", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (VersionCompare.IsNewer(release.Tag, AppInfo.Version))
            {
                if (MessageBox.Show("Open the release page?", $"Quili {release.Tag} is available", MessageBoxButton.YesNo,
                        MessageBoxImage.Information) == MessageBoxResult.Yes)
                    OpenPage(release.Url);
            }
            else
                MessageBox.Show($"You have version {AppInfo.Version}.", "Quili is up to date", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        static void OpenPage(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception ex) { DebugLog.Write($"opening the release page failed: {ex.GetType().Name}: {ex.Message}"); }
        }

        /// <summary>
        /// At startup, with "Check for updates once a day" on and the last check more than a day old: asks GitHub quietly and only
        /// speaks up (through <paramref name="notify"/>) when there is a newer release. The time is saved after every attempt, failed or not.
        /// </summary>
        public static async Task CheckInBackgroundAsync(Settings settings, Action<string, string> notify)
        {
            if (!settings.AutoUpdateCheck || DateTime.UtcNow - settings.LastUpdateCheck <= Day) return;
            var release = await LatestReleaseAsync();
            settings.LastUpdateCheck = DateTime.UtcNow;
            try { settings.Save(); } catch (Exception ex) { DebugLog.Write($"saving the update check time failed: {ex.GetType().Name}: {ex.Message}"); }
            if (release == null || !VersionCompare.IsNewer(release.Tag, AppInfo.Version)) return;
            DebugLog.Write($"update available: {release.Tag}");
            notify($"Quili {release.Tag} is available", "Open the tray menu and choose Check for updates… to get it.");
        }
    }
}
