using System;
using System.Threading;
using System.Windows.Automation;
using Quili.Core;

namespace Quili.Platform
{
    /// <summary>What the focused field's text looks like right now: how many distinct secrets it holds and which button is the likely next step.</summary>
    public readonly record struct FieldHints(int Secrets, ActionSuggestion Suggestion);

    /// <summary>
    /// While the overlay is on a field, looks at that field's text every 600 ms on a background thread (a slow app must not
    /// stall the UI), on this computer only, and reports the hints through <see cref="Changed"/> on the UI thread, only
    /// when they change. Secrets are counted with the redaction rules (emails never count). The macOS twin is
    /// <c>Accessibility/SecretWatcher.swift</c>.
    /// </summary>
    public sealed class SecretWatcher : IDisposable
    {
        const int IntervalMs = 600, MaxChars = 20_000;

        readonly System.Windows.Threading.Dispatcher _dispatcher;
        readonly object _lock = new();
        readonly Timer _timer;
        AutomationElement? _element;
        string? _lastText;          // only touched by the timer callback and Follow, under _lock
        FieldHints _last;
        int _running;               // the timer never overlaps itself

        /// <summary>Raised on the UI thread when the hints change.</summary>
        public event Action<FieldHints>? Changed;

        public SecretWatcher(System.Windows.Threading.Dispatcher dispatcher)
        {
            _dispatcher = dispatcher;
            _timer = new Timer(_ => Tick(), null, Timeout.Infinite, Timeout.Infinite);
        }

        public void Start() => _timer.Change(IntervalMs, IntervalMs);

        /// <summary>The field to watch, or null when no field is focused (the hints reset).</summary>
        public void Follow(AutomationElement? element)
        {
            bool reset;
            lock (_lock)
            {
                _element = element;
                _lastText = null;
                reset = !_last.Equals(default(FieldHints));
                _last = default;
            }
            if (reset) Report(default);
        }

        void Tick()
        {
            if (Interlocked.Exchange(ref _running, 1) == 1) return;
            try
            {
                AutomationElement? element;
                lock (_lock) element = _element;
                if (element == null) return;

                var text = TextAccess.PeekText(element, MaxChars);
                if (text == null) return;
                FieldHints hints;
                lock (_lock)
                {
                    if (!ReferenceEquals(element, _element) || text == _lastText) return;
                    _lastText = text;
                    hints = new FieldHints(Redactor.Mask(text, emails: false).Values.Count, LanguageHint.SuggestionFor(text));
                    if (hints.Equals(_last)) return;
                    _last = hints;
                }
                Report(hints);
            }
            catch (Exception) { }
            finally { Interlocked.Exchange(ref _running, 0); }
        }

        void Report(FieldHints hints) => _dispatcher.BeginInvoke(() => Changed?.Invoke(hints));

        public void Dispose() => _timer.Dispose();
    }
}
