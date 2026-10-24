using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Quili.Core;
using Quili.Platform;
using Quili.UI;

namespace Quili
{
    public enum NoticeLevel { Info, Error }

    /// <summary>
    /// Ties the pieces together: tracks the focused field, shows the overlay button on it, and runs
    /// read → paraphrase → replace when the button is clicked. Create it on the UI thread.
    /// </summary>
    public sealed class ParaphraseController : IDisposable
    {
        readonly Settings _settings;
        readonly Dispatcher _dispatcher;
        readonly Action<string, string, NoticeLevel> _notify;
        readonly OverlayWindow _overlay = new();
        readonly BubbleWindow _bubble = new();
        readonly ThreadWatcher _threadWatcher = new();
        readonly ThreadButtonWindow _threadButton = new();
        ThreadPane? _threadPane;
        bool _summarizing, _summaryDismissed; // a summary is being made / its close button was clicked meanwhile
        readonly FocusTracker _tracker = new();
        readonly CaretTracker _caret = new();
        TextTarget? _current;
        CancellationTokenSource? _cts;
        bool _writing; // once the field is being written, cancelling would leave it half-replaced

        // Tone chips: shown while the pointer is on the pill (and for a moment after it leaves, so it can reach the bar).
        // Undo bar: shown after a replace; Undo puts the original text back, Original shows it in a bubble.
        static readonly string[] UndoChips = { "Undo", "Original" };
        static readonly TimeSpan ToneHideDelay = TimeSpan.FromMilliseconds(250), UndoLifetime = TimeSpan.FromSeconds(15);
        readonly ChipBarWindow _toneBar = new(), _undoBar = new();
        readonly DispatcherTimer _toneHideTimer, _undoTimer;
        bool _toneHover, _toneBarHover;
        UndoState? _undo;
        bool _showingOriginal, _undoing; // the bubble shows the original text / an undo is being applied

        public ParaphraseController(Settings settings, Dispatcher dispatcher, Action<string, string, NoticeLevel> notify)
        {
            _settings = settings;
            _dispatcher = dispatcher;
            _notify = notify;
            _toneHideTimer = new DispatcherTimer { Interval = ToneHideDelay };
            _toneHideTimer.Tick += (_, _) =>
            {
                _toneHideTimer.Stop();
                if (!_toneHover && !_toneBarHover) HideToneBar();
            };
            _undoTimer = new DispatcherTimer { Interval = UndoLifetime };
            _undoTimer.Tick += (_, _) => ClearUndo();
            _overlay.ToneHoverChanged += hover => { _toneHover = hover; OnToneHover(); };
            _toneBar.HoverChanged += hover => { _toneBarHover = hover; OnToneHover(); };
            _toneBar.ChipClicked += index =>
            {
                HideToneBar();
                // The chosen tone becomes the paraphrase tone (a setting, also used by the sparkle button) and runs right away.
                if (index < 0 || index >= Tone.Presets.Count) return;
                _settings.Tone = Tone.Presets[index].Id;
                try { _settings.Save(); } catch (Exception ex) { DebugLog.Write($"saving the tone failed: {ex.GetType().Name}: {ex.Message}"); }
                _ = RunAsync(TextAction.Paraphrase);
            };
            _undoBar.ChipClicked += index => { if (index == 0) _ = UndoAsync(); else ToggleOriginal(); };
            _tracker.AppAllowed = names => AppFilter.Allows(names, _settings.AppFilterMode, _settings.AppFilterList);
            _overlay.ActionRequested += action => _ = RunAsync(action);
            _overlay.SettingsRequested += () => SettingsRequested?.Invoke();
            _overlay.CancelRequested += () =>
            {
                if (_writing) return;
                DebugLog.Write("cancel requested; dropping the connection");
                _cts?.Cancel();
            };
            _tracker.TargetChanged += t => _dispatcher.BeginInvoke(() => OnTargetChanged(t));
            _caret.CaretChanged += c => _dispatcher.BeginInvoke(() => _overlay.Avoid(c));
            _bubble.CloseRequested += () =>
            {
                _showingOriginal = false;
                // Clicked before the summary finished: stop the request too, and let the fade finish the job.
                if (_summarizing) { _summaryDismissed = true; _cts?.Cancel(); }
                _bubble.FadeOut();
            };
            _threadWatcher.PaneChanged += p => _dispatcher.BeginInvoke(() => OnThreadPaneChanged(p));
            _threadButton.Clicked += () =>
            {
                var pane = _threadPane;
                if (pane != null) StartSummary(_threadButton.Area, pane.Window);
            };
        }

        /// <summary>The gear in the pill was clicked.</summary>
        public event Action? SettingsRequested;

        public void Start()
        {
            _tracker.Start();
            _caret.Start();
            _threadWatcher.Start();
        }

        public bool Paused
        {
            set
            {
                _tracker.Paused = value;
                _threadWatcher.Paused = value;
                if (value) { _overlay.HideOverlay(); HideToneBar(); ClearUndo(); _bubble.HideBubble(); _threadButton.HideButton(); }
            }
        }

        public void Dispose()
        {
            _toneHideTimer.Stop();
            _undoTimer.Stop();
            _tracker.Dispose();
            _caret.Dispose();
            _threadWatcher.Dispose();
        }

        /// <summary>A thread pane opened, moved or closed in Slack: keep the Summarize button on it.</summary>
        void OnThreadPaneChanged(ThreadPane? pane)
        {
            bool appeared = (pane != null) != (_threadPane != null);
            _threadPane = pane;
            if (appeared) // logged when the button appears or disappears, not on every move
                DebugLog.Write(pane == null
                    ? "thread button: hidden"
                    : $"thread button: beside Slack's Summarize thread button, bounds={pane.Bounds}");
            if (pane == null) _threadButton.HideButton();
            else _threadButton.ShowBeside(pane.Bounds);
        }

        void OnTargetChanged(TextTarget? target)
        {
            // Keep the button where it is while a request is running; the result is validated afterwards.
            if (_overlay.IsBusy) return;

            // The undo only belongs to the field it was made in.
            if (_undo != null && (target == null || !FocusTracker.SameElement(_undo.Element, target.Element))) ClearUndo();
            HideToneBar();

            // Same field as before (just moved or resized): a button the user dragged stays where they put it.
            bool sameField = target != null && _current != null && FocusTracker.SameElement(_current.Element, target.Element);
            _current = target;
            _caret.Follow(target?.Element);
            if (target == null) _overlay.HideOverlay();
            else _overlay.ShowAt(target.Bounds, sameField);
            if (_undo != null) ShowUndoBar(); // follow the pill
        }

        /// <summary>The pointer moved onto or off the pill or the tone bar.</summary>
        void OnToneHover()
        {
            if (_toneHover || _toneBarHover)
            {
                _toneHideTimer.Stop();
                if (!_toneBar.IsShown && _current != null && !_overlay.IsBusy && !_overlay.ToneArea.IsEmpty)
                {
                    HideUndoBar(); // same spot: the tone chips take over until they hide again
                    _toneBar.Show(Tone.Labels, _overlay.ToneArea, _overlay.ChipsPreferAbove, centered: true, selected: Tone.IndexOf(_settings.Tone));
                    _overlay.KeepExpanded = true; // the pill stays open while the pointer is on the bar
                }
            }
            else if (_toneBar.IsShown)
            {
                _toneHideTimer.Stop();
                _toneHideTimer.Start(); // a short grace period so the pointer can cross the gap to the bar
            }
        }

        void HideToneBar()
        {
            _toneHideTimer.Stop();
            _toneHover = _toneBarHover = false;
            bool wasShown = _toneBar.IsShown;
            _toneBar.HideBar();
            _overlay.KeepExpanded = false;
            if (wasShown && _undo != null) ShowUndoBar();
        }

        void ShowUndoBar()
        {
            if (_undo == null || _toneBar.IsShown || _overlay.Area.IsEmpty) return;
            _undoBar.Show(UndoChips, _overlay.Area, _overlay.ChipsPreferAbove);
        }

        /// <summary>Hides the undo bar (and the original-text bubble) but keeps the undo available.</summary>
        void HideUndoBar()
        {
            _undoBar.HideBar();
            if (_showingOriginal) { _showingOriginal = false; _bubble.HideBubble(); }
        }

        /// <summary>Forgets the undo: it is used up, timed out, or the field is no longer the one it was made in.</summary>
        void ClearUndo()
        {
            _undo = null;
            _undoTimer.Stop();
            HideUndoBar();
        }

        /// <summary>The Original chip: shows the text from before the replace in a closable bubble, or hides it again.</summary>
        void ToggleOriginal()
        {
            var undo = _undo;
            if (undo == null) return;
            if (_showingOriginal)
            {
                _showingOriginal = false;
                _bubble.FadeOut();
                return;
            }
            _showingOriginal = true;
            var anchor = _undoBar.Area.IsEmpty ? _overlay.Area : System.Drawing.Rectangle.Union(_overlay.Area, _undoBar.Area); // clear of both the pill and the bar
            _bubble.ShowText(undo.Original, anchor, tall: true, closable: true, markdown: false);
        }

        /// <summary>The Undo chip: puts the original text back where the result was written.</summary>
        async Task UndoAsync()
        {
            var undo = _undo;
            if (undo == null || _undoing || _overlay.IsBusy || _cts != null) return;
            _undoing = true;
            ClearUndo(); // one undo only; the bar goes away right away
            DebugLog.Write($"undo clicked (selection={undo.WasSelection})");
            try
            {
                var window = Native.GetForegroundWindow();
                bool focused = FocusTracker.StillFocused(undo.Element), front = FocusTracker.IsForeground(undo.Element);
                if (!focused || !front)
                {
                    DebugLog.Write($"undo: target lost focus (focused={focused}, foreground={front}); bringing it back");
                    if (!await FocusTracker.RestoreFocusAsync(undo.Element, window))
                    {
                        DebugLog.Write("undo: could not restore focus; original left on the clipboard");
                        TextAccess.TrySetClipboard(undo.Original);
                        _notify("Focus changed", "The original text was copied to the clipboard instead.", NoticeLevel.Info);
                        return;
                    }
                }

                if (undo.WasSelection) await TextAccess.UndoAsync(undo, undo.Element);
                else await TextAccess.ReplaceAsync(new FieldText(undo.Result, false), undo.Original, undo.Element);
                DebugLog.Write("undo applied");
            }
            catch (Exception ex)
            {
                DebugLog.Write($"undo failed: {ex.GetType().Name}: {ex.Message}");
                TextAccess.TrySetClipboard(undo.Original);
                _notify("Couldn't undo automatically", "The original text was copied to the clipboard.", NoticeLevel.Error);
            }
            finally
            {
                _undoing = false;
            }
        }

        /// <summary>
        /// Reads the Slack thread open in <paramref name="window"/> and shows its summary above <paramref name="anchor"/>
        /// (the Summarize button). Never writes to Slack; the summary is also copied to the clipboard.
        /// </summary>
        void StartSummary(System.Drawing.Rectangle anchor, IntPtr window)
        {
            if (_cts != null || _overlay.IsBusy || _undoing) return;
            _ = SummarizeAsync(anchor, window);
        }

        async Task SummarizeAsync(System.Drawing.Rectangle anchor, IntPtr window)
        {
            var action = TextAction.SummarizeThread;
            if (window == IntPtr.Zero || !ThreadReader.IsSlack(window))
            {
                _notify("Open a Slack thread first", "Switch to Slack, open the thread, then click the Summarize button.", NoticeLevel.Info);
                return;
            }
            DebugLog.Write("summarize clicked");
            ClearUndo(); // the bubble is about to show the summary

            using var cts = _cts = new CancellationTokenSource();
            _summarizing = true;
            _summaryDismissed = false;
            bool previewing = true; // late streamed updates must not re-show the bubble after the request ended
            bool keepBubble = false;
            // Closable from the start, so a slow summary can be dismissed (which also cancels it).
            _bubble.ShowText("Reading the thread…", anchor, tall: true, closable: true);
            try
            {
                var thread = await Task.Run(() => ThreadReader.Read(window), cts.Token);
                cts.Token.ThrowIfCancellationRequested();
                if (thread == null || thread.Text.Trim().Length <= 20)
                {
                    _notify("No thread found", "Open the thread in Slack's side pane (click its replies link) and try again.", NoticeLevel.Info);
                    return;
                }
                DebugLog.Write($"read {thread.Text.Length} chars from the thread{(thread.Truncated ? " (oldest messages dropped)" : "")}");
                DebugLog.Write($"thread text to summarize:\n{thread.Text}");

                var result = await ParaphraseClient.RunAsync(thread.Text, _settings, action, cts.Token,
                    partial => _dispatcher.BeginInvoke(() =>
                    {
                        if (previewing && !cts.IsCancellationRequested) _bubble.ShowText(partial, anchor, tall: true, closable: true);
                    }));
                previewing = false;
                cts.Token.ThrowIfCancellationRequested(); // closed while the last of it was arriving
                TextAccess.TrySetClipboard(TextHygiene.SlackMarkup(result));
                // The summary stays until it is closed with its close button.
                _bubble.ShowText(result, anchor, tall: true, closable: true);
                keepBubble = true;
                _notify("Thread summarized", "The summary was copied to the clipboard.", NoticeLevel.Info);
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested)
            {
                DebugLog.Write($"{action} cancelled by the user");
            }
            catch (Exception ex)
            {
                DebugLog.Write($"{action} failed: {ex.GetType().Name}: {ex.Message}");
                _notify($"{action.Verb()} failed", ex.Message, NoticeLevel.Error);
            }
            finally
            {
                previewing = false;
                _summarizing = false;
                if (!keepBubble && !_summaryDismissed) _bubble.HideBubble(); // a dismissed bubble is already fading out
                _cts = null;
            }
        }

        /// <summary>Runs <paramref name="action"/> on the focused field.</summary>
        async Task RunAsync(TextAction action)
        {
            var target = _current;
            DebugLog.Write($"{action} clicked (target={(target == null ? "none" : "set")}, busy={_overlay.IsBusy})");
            if (target == null || _overlay.IsBusy || _cts != null || _undoing) return;

            HideToneBar();
            ClearUndo();

            _overlay.SetBusy(true);
            using var cts = _cts = new CancellationTokenSource();
            _writing = false;
            var targetWindow = Native.GetForegroundWindow();
            bool previewing = true; // late streamed updates must not re-show the bubble after the request ended
            try
            {
                var field = await TextAccess.ReadAsync(target.Element);
                DebugLog.Write($"read {field.Text.Length} chars from field");
                if (string.IsNullOrWhiteSpace(field.Text))
                {
                    _notify($"Nothing to {action.Verb().ToLowerInvariant()}", "The text field is empty.", NoticeLevel.Info);
                    return;
                }

                // The text streams into a bubble beside the button while the model writes it; the field itself is
                // only touched once the final text is in.
                var result = await ParaphraseClient.RunAsync(field.Text, _settings, action, cts.Token,
                    partial => _dispatcher.BeginInvoke(() =>
                    {
                        if (previewing && !cts.IsCancellationRequested) _bubble.ShowText(partial, _overlay.Area);
                    }));
                previewing = false;
                _bubble.HideBubble();

                bool focused = FocusTracker.StillFocused(target.Element), front = FocusTracker.IsForeground(target.Element);
                if (!focused || !front)
                {
                    DebugLog.Write($"target lost focus (focused={focused}, foreground={front}); bringing it back");
                    if (await FocusTracker.RestoreFocusAsync(target.Element, targetWindow))
                        DebugLog.Write("focus restored");
                    else
                    {
                        DebugLog.Write("could not restore focus; result left on the clipboard");
                        TextAccess.TrySetClipboard(result);
                        _notify("Focus changed", $"The {action.Verb().ToLowerInvariant()}d text was copied to the clipboard instead.", NoticeLevel.Info);
                        return;
                    }
                }

                _writing = true;
                await TextAccess.ReplaceAsync(field, result, target.Element);
                DebugLog.Write("field replaced");

                // Offer to undo it for a while.
                _undo = new UndoState(target.Element, field.Text, result, field.IsSelection);
                _undoTimer.Stop();
                _undoTimer.Start();
                ShowUndoBar();
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested)
            {
                DebugLog.Write($"{action} cancelled by the user");
            }
            catch (Exception ex)
            {
                DebugLog.Write($"{action} failed: {ex.GetType().Name}: {ex.Message}");
                _notify($"{action.Verb()} failed", ex.Message, NoticeLevel.Error);
            }
            finally
            {
                previewing = false;
                _bubble.HideBubble();
                _cts = null;
                _writing = false;
                _overlay.SetBusy(false);
            }
        }
    }
}
