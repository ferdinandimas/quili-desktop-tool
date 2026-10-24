using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Quili.Core
{
    public static class ParaphraseClient
    {
        // A dead or stale connection fails fast (connect timeout, short idle lifetime) and is retried once,
        // so a restart on the server costs seconds instead of a long hang.
        static readonly HttpClient Http = new(new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(8),
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(45),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        }) { Timeout = TimeSpan.FromSeconds(45) };

        /// <summary>Accepts either the base URL or the full endpoint URL and returns the base URL.</summary>
        public static string NormalizeServerUrl(string? url)
        {
            var u = (url ?? "").Trim().TrimEnd('/');
            foreach (var endpoint in new[] { "/api/paraphrase", "/api/translate", "/api/summarize-thread", "/api/summarize-text" })
                if (u.EndsWith(endpoint, StringComparison.OrdinalIgnoreCase))
                    u = u[..^endpoint.Length].TrimEnd('/');
            return u;
        }

        public static Task<string> ParaphraseAsync(string text, Settings settings, CancellationToken ct = default) =>
            RunAsync(text, settings, TextAction.Paraphrase, ct);

        /// <summary>Whole-request cap once the response has started streaming (the server stops at 60s).</summary>
        static readonly TimeSpan StreamTimeout = TimeSpan.FromSeconds(75);

        /// <summary>
        /// Runs the action on the server. <paramref name="onText"/> (optional) receives the rewritten text so
        /// far while the model is still writing it (each call replaces the previous one); the return value is
        /// the final, authoritative text. The paraphrase instruction is <see cref="Settings.EffectiveStyle"/>.
        /// <paramref name="context"/> (paraphrase and translate only) is the Slack conversation the text replies to; it is masked
        /// like the text, with placeholder numbers after the text's own, and its placeholders are never restored or required.
        /// </summary>
        public static async Task<string> RunAsync(string text, Settings settings, TextAction action,
            CancellationToken ct = default, Action<string>? onText = null, string? context = null)
        {
            var apiKey = settings.ApiKey;
            // With the mock toggle on, every action is answered by the built-in mock, which needs neither a
            // server URL nor an API key.
            bool mocked = settings.MockMode;
            string serverUrl;
            if (mocked)
            {
                try { serverUrl = MockServer.Shared.Start(); }
                catch (Exception ex) { throw new InvalidOperationException($"The mock server could not start: {ex.Message}"); }
            }
            else serverUrl = NormalizeServerUrl(settings.ServerUrl);
            if ((!mocked && string.IsNullOrWhiteSpace(apiKey)) || string.IsNullOrWhiteSpace(serverUrl))
                throw new InvalidOperationException("Server URL or API key not set. Open Settings from the tray icon.");

            text = TextHygiene.StripLoneSurrogates(text);
            // Secrets (and optionally emails) never leave the machine: they travel as placeholders and come back after.
            Redactor.Masked? masked = null;
            if (settings.RedactSecrets)
            {
                masked = Redactor.Mask(text, settings.RedactEmails);
                text = masked.Text;
                if (masked.Values.Count > 0) DebugLog.Write($"redacted {masked.Values.Count} value(s) before sending");
            }
            string? outgoingContext = context == null ? null : TextHygiene.StripLoneSurrogates(context).Trim();
            if (!string.IsNullOrEmpty(outgoingContext) && settings.RedactSecrets)
                outgoingContext = Redactor.Mask(outgoingContext, settings.RedactEmails, (masked?.Values.Count ?? 0) + 1).Text;
            DebugLog.Write($"{action} request: POST {serverUrl}{action.Path()} ({TextHygiene.Describe(text)})");
            // The default encoder escapes every non-ASCII character (\uD83D\uDE00), so emoji cannot be
            // mangled in transit; the body is also sent explicitly as UTF-8.
            // Paraphrase carries the user's instruction; translate always targets English; a summary has no instruction.
            var fields = new Dictionary<string, object> { ["text"] = text };
            switch (action)
            {
                case TextAction.TranslateToEnglish: fields["target_language"] = "English"; break;
                case TextAction.SummarizeThread or TextAction.SummarizeText: break;
                default: fields["style"] = TextHygiene.StripLoneSurrogates(settings.EffectiveStyle); break;
            }
            // The conversation a reply belongs to goes along only with a paraphrase or a translation, and only when there is one.
            if (!string.IsNullOrEmpty(outgoingContext) && (action is TextAction.Paraphrase or TextAction.TranslateToEnglish))
                fields["context"] = outgoingContext;
            fields["stream"] = true;
            var body = JsonSerializer.Serialize(fields);

            HttpRequestMessage NewRequest()
            {
                var req = new HttpRequestMessage(HttpMethod.Post, serverUrl + action.Path())
                {
                    Content = new StringContent(body, new UTF8Encoding(false), "application/json"),
                };
                if (!string.IsNullOrEmpty(apiKey)) req.Headers.Add("X-API-Key", apiKey);
                req.Headers.Accept.ParseAdd("text/event-stream");
                req.Headers.Accept.ParseAdd("application/json");
                return req;
            }

            using var overall = CancellationTokenSource.CreateLinkedTokenSource(ct);
            overall.CancelAfter(StreamTimeout);
            var token = overall.Token;

            HttpResponseMessage resp;
            try
            {
                using var first = NewRequest();
                resp = await Http.SendAsync(first, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            }
            catch (HttpRequestException ex)
            {
                // Connection-level failure (no HTTP response at all): safe to try once more.
                DebugLog.Write($"{action} connection failed ({ex.Message}); retrying once");
                using var second = NewRequest();
                resp = await Http.SendAsync(second, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException("The server took too long to respond.");
            }

            using var _ = resp;
            DebugLog.Write($"{action} response: HTTP {(int)resp.StatusCode}");

            // Streamed text and the final text get the hidden values back (a summary shows "[hidden value n]" instead).
            string Reveal(string t) => masked == null ? t
                : action.IsSummary() ? Redactor.Relabel(t) : Redactor.Restore(t, masked.Values).Text;
            Action<string>? shown = onText == null || masked == null ? onText : partial => onText(Reveal(partial));

            string result;
            try
            {
                if (resp.IsSuccessStatusCode && resp.Content.Headers.ContentType?.MediaType == "text/event-stream")
                    result = await ReadStreamAsync(resp, action, shown, token).ConfigureAwait(false);
                else
                    result = await ReadJsonAsync(resp, action, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException("The server took too long to respond.");
            }

            if (masked == null) return result;
            if (action.IsSummary()) return Redactor.Relabel(result);
            var (restored, allPresent) = Redactor.Restore(result, masked.Values);
            if (!allPresent)
            {
                DebugLog.Write("a protected value is missing from the result; nothing is replaced");
                throw new InvalidOperationException(
                    "Some protected values (secrets) were changed by the AI, so nothing was replaced. Turn off \"Redact secrets before sending\" in Settings > Privacy & apps to send the text as it is.");
            }
            return restored;
        }

        /// <summary>Reads server-sent events: `delta` (text so far), then `done` (final result) or `error`.</summary>
        static async Task<string> ReadStreamAsync(HttpResponseMessage resp, TextAction action, Action<string>? onText, CancellationToken ct)
        {
            await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            using var reader = new StreamReader(stream, new UTF8Encoding(false));
            string? eventName = null, data = null, line;
            while ((line = await reader.ReadLineAsync(ct).ConfigureAwait(false)) != null)
            {
                if (line.StartsWith("event:", StringComparison.Ordinal)) eventName = line[6..].Trim();
                else if (line.StartsWith("data:", StringComparison.Ordinal)) data = line[5..].Trim();
                else if (line.Length == 0 && eventName != null && data != null)
                {
                    using var doc = JsonDocument.Parse(data);
                    var root = doc.RootElement;
                    switch (eventName)
                    {
                        case "delta":
                            var partial = TextHygiene.StripLoneSurrogates(root.GetProperty("text").GetString() ?? "");
                            if (partial.Length > 0) onText?.Invoke(partial);
                            break;
                        case "done":
                            var content = TextHygiene.StripLoneSurrogates(root.GetProperty("text").GetString() ?? "").Trim();
                            if (content.Length == 0)
                                throw new InvalidOperationException("Paraphrase server returned an empty response.");
                            DebugLog.Write($"{action} result: {TextHygiene.Describe(content)}");
                            return content;
                        case "error":
                            throw new InvalidOperationException($"{action.Verb()} server error: {root.GetProperty("detail")}");
                    }
                    eventName = data = null;
                }
            }
            throw new InvalidOperationException("The connection closed before the result arrived.");
        }

        static async Task<string> ReadJsonAsync(HttpResponseMessage resp, TextAction action, CancellationToken ct)
        {
            // Decode as UTF-8 ourselves rather than trusting a missing/incorrect charset header.
            var json = Encoding.UTF8.GetString(await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
            if (!resp.IsSuccessStatusCode)
            {
                string msg = json;
                try
                {
                    var detail = JsonDocument.Parse(json).RootElement.GetProperty("detail");
                    msg = detail.ValueKind == JsonValueKind.String ? detail.GetString() ?? json : detail.ToString();
                }
                catch (Exception) { }
                throw new InvalidOperationException($"{action.Verb()} server error {(int)resp.StatusCode}: {msg}");
            }

            using var doc = JsonDocument.Parse(json);
            var content = doc.RootElement.GetProperty("text").GetString();
            if (string.IsNullOrWhiteSpace(content))
                throw new InvalidOperationException("Paraphrase server returned an empty response.");
            content = TextHygiene.StripLoneSurrogates(content).Trim();
            DebugLog.Write($"{action} result: {TextHygiene.Describe(content)}");
            return content;
        }
    }
}
