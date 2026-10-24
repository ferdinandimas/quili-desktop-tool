using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
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

        // Hover bars: the tone chips show while the pointer is on the Tone button, the History chip while it is on the
        // sparkle button (both stay for a moment after the pointer leaves, so it can reach the bar). Only one at a time.
        // Undo bar: shown after a replace; Undo puts the original text back, Original shows it in a bubble.
        enum HoverBar { None, Tone, History }
        static readonly string[] UndoChips = { "Undo", "Original" }, HistoryChips = { "History" };
        static readonly TimeSpan ToneHideDelay = TimeSpan.FromMilliseconds(250), UndoLifetime = TimeSpan.FromSeconds(15);
        readonly ChipBarWindow _toneBar = new(), _historyBar = new(), _undoBar = new();
        readonly DispatcherTimer _toneHideTimer, _undoTimer;
        bool _toneHover, _toneBarHover, _historyHover, _historyBarHover;
        HoverBar _barShown = HoverBar.None;
        UndoState? _undo;
        bool _showingOriginal, _undoing; // the bubble shows the original text / an undo is being applied

        // Review before replace: a finished paraphrase or translation waits in the bubble for Apply or Discard.
        sealed record PendingReview(AutomationElement Element, IntPtr Window, FieldText Field, string Result, TextAction Action);
        PendingReview? _pending;
        HistoryWindow? _history;

        public ParaphraseController(Settings settings, Dispatcher dispatcher, Action<string, string, NoticeLevel> notify)
        {
            _settings = settings;
            _dispatcher = dispatcher;
            _notify = notify;
            _toneHideTimer = new DispatcherTimer { Interval = ToneHideDelay };
            _toneHideTimer.Tick += (_, _) =>
            {
                _toneHideTimer.Stop();
                if (!_toneHover && !_toneBarHover && !_historyHover && !_historyBarHover) HideHoverBars();
            };
            _undoTimer = new DispatcherTimer { Interval = UndoLifetime };
            _undoTimer.Tick += (_, _) => ClearUndo();
            _overlay.ToneHoverChanged += hover => { _toneHover = hover; OnBarHover(); };
            _toneBar.HoverChanged += hover => { _toneBarHover = hover; OnBarHover(); };
            _overlay.ParaphraseHoverChanged += hover => { _historyHover = hover; OnBarHover(); };
            _historyBar.HoverChanged += hover => { _historyBarHover = hover; OnBarHover(); };
            _historyBar.ChipClicked += _ =>
            {
                HideHoverBars();
                OpenHistory();
            };
            _toneBar.ChipClicked += index =>
            {
                HideHoverBars();
                // The chosen tone becomes the paraphrase tone (a setting, also used by the sparkle button) and runs right away.
                if (index < 0 || index >= Tone.Presets.Count) return;
                _settings.Tone = Tone.Presets[index].Id;
                try { _settings.Save(); } catch (Exception ex) { DebugLog.Write($"saving the tone failed: {ex.GetType().Name}: {ex.Message}"); }
                _ = RunAsync(TextAction.Paraphrase);
            };
            _undoBar.ChipClicked += index => { if (index == 0) _ = UndoAsync(); else ToggleOriginal(); };
            _tracker.AppAllowed = names => AppFilter.Allows(names, _settings.AppFilterMode, _settings.AppFilterList);
            _overlay.ActionRequested += action => _ = action == TextAction.SummarizeText ? SummarizeSelectionAsync(fromPill: true) : RunAsync(action);
            _overlay.SettingsRequested += () => SettingsRequested?.Invoke();
            _overlay.CancelRequested += () =>
            {
                if (_writing) return;
                DebugLog.Write("cancel requested; dropping the connection");
                _cts?.Cancel();
            };
            _tracker.TargetChanged += t => _dispatcher.BeginInvoke(() => OnTargetChanged(t));
            _caret.CaretChanged += c => _dispatcher.BeginInvoke(() => _overlay.Avoid(c));
            _bubble.ApplyRequested += () => _ = ApplyReviewAsync();
            _bubble.CloseRequested += () =>
            {
                if (_pending != null) { DiscardReview(fade: true); return; } // the x or Discard on a review
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
                if (value) { _overlay.HideOverlay(); HideHoverBars(); ClearUndo(); DiscardReview(); _bubble.HideBubble(); _threadButton.HideButton(); }
            }
        }

        public void Dispose()
        {
            _toneHideTimer.Stop();
            _undoTimer.Stop();
            _tracker.Dispose();
            _caret.Dispose();
            _threadWatcher.Dispose();
            _history?.Close();
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
            // So does a review that is waiting for Apply.
            if (_pending != null && (target == null || !FocusTracker.SameElement(_pending.Element, target.Element))) DiscardReview();
            HideHoverBars();

            // Same field as before (just moved or resized): a button the user dragged stays where they put it.
            bool sameField = target != null && _current != null && FocusTracker.SameElement(_current.Element, target.Element);
            _current = target;
            _caret.Follow(target?.Element);
            if (target == null) _overlay.HideOverlay();
            else _overlay.ShowAt(target.Bounds, sameField);
            if (_undo != null) ShowUndoBar(); // follow the pill
        }

        /// <summary>The pointer moved onto or off the Tone button, the sparkle button or their bars.</summary>
        void OnBarHover()
        {
            var wanted = _toneHover || _toneBarHover ? HoverBar.Tone
                : _historyHover || _historyBarHover ? HoverBar.History
                : HoverBar.None;
            if (wanted != HoverBar.None)
            {
                _toneHideTimer.Stop();
                if (wanted != _barShown && _current != null && !_overlay.IsBusy) ShowHoverBar(wanted);
            }
            else if (_barShown != HoverBar.None)
            {
                _toneHideTimer.Stop();
                _toneHideTimer.Start(); // a short grace period so the pointer can cross the gap to the bar
            }
        }

        /// <summary>Shows the tone bar (over the Tone button) or the History chip (over the sparkle button); never both.</summary>
        void ShowHoverBar(HoverBar kind)
        {
            var area = kind == HoverBar.Tone ? _overlay.ToneArea : _overlay.ParaphraseArea;
            if (area.IsEmpty) return;
            HideUndoBar(); // same spot: the chips take over until they hide again
            if (kind == HoverBar.Tone)
            {
                _historyBar.HideBar();
                _historyBarHover = false;
                _toneBar.Show(Tone.Labels, area, _overlay.ChipsPreferAbove, centered: true, selected: Tone.IndexOf(_settings.Tone));
            }
            else
            {
                _toneBar.HideBar();
                _toneBarHover = false;
                _historyBar.Show(HistoryChips, area, _overlay.ChipsPreferAbove, centered: true);
            }
            _barShown = kind;
            _overlay.KeepExpanded = true; // the pill stays open while the pointer is on the bar
        }

        void HideHoverBars()
        {
            _toneHideTimer.Stop();
            _toneHover = _toneBarHover = _historyHover = _historyBarHover = false;
            bool wasShown = _barShown != HoverBar.None;
            _barShown = HoverBar.None;
            _toneBar.HideBar();
            _historyBar.HideBar();
            _overlay.KeepExpanded = false;
            if (wasShown && _undo != null) ShowUndoBar();
        }

        void ShowUndoBar()
        {
            if (_undo == null || _barShown != HoverBar.None || _overlay.Area.IsEmpty) return;
            _undoBar.Show(UndoChips, _overlay.Area, _overlay.ChipsPreferAbove);
        }

        /// <summary>Opens the "Recent rewrites" window (or brings the open one to the front, with a fresh list).</summary>
        void OpenHistory()
        {
            if (_history == null)
            {
                _history = new HistoryWindow(_settings);
                _history.Closed += (_, _) => _history = null;
                _history.Show();
            }
            else
            {
                _history.Reload();
                _history.BringToFront();
            }
        }

        /// <summary>Remembers a finished request for the "Recent rewrites" list (only while the setting is on).</summary>
        void RecordHistory(string kind, string? app, string original, string result)
        {
            if (!_settings.KeepHistory) return;
            try { HistoryStore.Add(kind, app, original, result); }
            catch (Exception ex) { DebugLog.Write($"recording the history failed: {ex.GetType().Name}"); }
        }

        static string HistoryKind(TextAction action) => action switch
        {
            TextAction.TranslateToEnglish => "translate",
            TextAction.Paraphrase => "paraphrase",
            _ => "summarize",
        };

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
            DiscardReview();

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
                RecordHistory("summarize", FocusTracker.ForegroundProcessName() ?? "slack", "", result);
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

        /// <summary>
        /// Summarizes the text the user has selected, in a tall, closable bubble that never writes to a field: from the pill
        /// (the focused field's selection, or all of its text) or from the tray item (whatever is selected in the foreground
        /// app, under the mouse pointer). The summary is copied to the clipboard.
        /// </summary>
        async Task SummarizeSelectionAsync(bool fromPill)
        {
            var target = _current;
            DebugLog.Write($"summarize text clicked (fromPill={fromPill})");
            if (_overlay.IsBusy || _cts != null || _undoing) return;
            if (fromPill && target == null) return;

            var action = TextAction.SummarizeText;
            HideHoverBars();
            ClearUndo();
            DiscardReview();

            using var cts = _cts = new CancellationTokenSource();
            _summarizing = true;
            _summaryDismissed = false;
            if (fromPill) _overlay.SetBusy(true);
            bool previewing = false; // late streamed updates must not re-show the bubble after the request ended
            bool keepBubble = false;
            var anchor = fromPill ? _overlay.Area : CursorAnchor();
            string? app = fromPill ? FocusTracker.ForegroundProcessName() : null;
            try
            {
                string text;
                if (fromPill)
                {
                    text = (await TextAccess.ReadAsync(target!.Element)).Text;
                    if (string.IsNullOrWhiteSpace(text))
                    {
                        _notify("Nothing to summarize", "The text field is empty.", NoticeLevel.Info);
                        return;
                    }
                }
                else
                {
                    // The tray menu has just closed; give the foreground app a moment to take the focus back.
                    await Task.Delay(250, cts.Token);
                    app = FocusTracker.ForegroundProcessName();
                    text = await TextAccess.ReadForegroundSelectionAsync();
                    anchor = CursorAnchor();
                    if (string.IsNullOrWhiteSpace(text))
                    {
                        _notify("No text selected", "Select the text you want summarized in any app, then choose Summarize selected text.", NoticeLevel.Info);
                        return;
                    }
                }
                DebugLog.Write($"read {text.Length} chars to summarize");

                // Closable from the start, so a slow summary can be dismissed (which also cancels it).
                previewing = true;
                _bubble.ShowText("Summarizing…", anchor, tall: true, closable: true);
                var result = await ParaphraseClient.RunAsync(text, _settings, action, cts.Token,
                    partial => _dispatcher.BeginInvoke(() =>
                    {
                        if (previewing && !cts.IsCancellationRequested) _bubble.ShowText(partial, anchor, tall: true, closable: true);
                    }));
                previewing = false;
                cts.Token.ThrowIfCancellationRequested(); // closed while the last of it was arriving
                TextAccess.TrySetClipboard(result.Replace("**", ""));
                // The summary stays until it is closed with its close button.
                _bubble.ShowText(result, anchor, tall: true, closable: true);
                keepBubble = true;
                RecordHistory("summarize", app, text, result);
                _notify("Text summarized", "The summary was copied to the clipboard.", NoticeLevel.Info);
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
                if (fromPill) _overlay.SetBusy(false);
            }
        }

        /// <summary>The tray's "Summarize selected text": the text selected in the foreground app (not necessarily an editable field).</summary>
        public void SummarizeSelection() => _ = SummarizeSelectionAsync(fromPill: false);

        /// <summary>A 1x1 rectangle at the mouse pointer (screen pixels), where the tray's summary bubble appears.</summary>
        static System.Drawing.Rectangle CursorAnchor()
        {
            var p = System.Windows.Forms.Cursor.Position;
            return new System.Drawing.Rectangle(p.X, p.Y, 1, 1);
        }

        /// <summary>Forgets a review that is waiting for Apply and closes its bubble (fading it when the user closed it).</summary>
        void DiscardReview(bool fade = false)
        {
            if (_pending == null) return;
            _pending = null;
            if (fade) _bubble.FadeOut();
            else _bubble.HideBubble();
        }

        /// <summary>
        /// Runs a paraphrase or translation on the focused field. The result is not written: it waits in a review bubble
        /// (changed words highlighted) until Apply is clicked.
        /// </summary>
        async Task RunAsync(TextAction action)
        {
            var target = _current;
            DebugLog.Write($"{action} clicked (target={(target == null ? "none" : "set")}, busy={_overlay.IsBusy})");
            if (target == null || _overlay.IsBusy || _cts != null || _undoing) return;

            HideHoverBars();
            ClearUndo();
            DiscardReview(); // a new request replaces a review that was still waiting

            _overlay.SetBusy(true);
            using var cts = _cts = new CancellationTokenSource();
            _writing = false;
            var targetWindow = Native.GetForegroundWindow();
            var app = FocusTracker.ForegroundProcessName();
            bool previewing = true; // late streamed updates must not re-show the bubble after the request ended
            bool keepBubble = false;
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
                // not touched until the user applies the finished result.
                var result = await ParaphraseClient.RunAsync(field.Text, _settings, action, cts.Token,
                    partial => _dispatcher.BeginInvoke(() =>
                    {
                        if (previewing && !cts.IsCancellationRequested) _bubble.ShowText(partial, _overlay.Area);
                    }));
                previewing = false;
                RecordHistory(HistoryKind(action), app, field.Text, result);

                // Review: the same bubble now shows the result with the changed words highlighted and Discard / Apply.
                _pending = new PendingReview(target.Element, targetWindow, field, result, action);
                _bubble.ShowReview(result, TextDiff.ChangedRanges(field.Text, result), _overlay.Area);
                keepBubble = true;
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
                if (!keepBubble) _bubble.HideBubble();
                _cts = null;
                _writing = false;
                _overlay.SetBusy(false);
            }
        }

        /// <summary>The Apply button of the review bubble: writes the reviewed result into the field and offers Undo.</summary>
        async Task ApplyReviewAsync()
        {
            var pending = _pending;
            if (pending == null || _overlay.IsBusy || _cts != null || _undoing) return;
            _pending = null;
            _bubble.HideBubble();
            DebugLog.Write($"review applied ({pending.Action})");

            _overlay.SetBusy(true);
            using var cts = _cts = new CancellationTokenSource();
            _writing = true; // the field is about to be written: no cancelling
            try
            {
                var element = pending.Element;
                bool focused = FocusTracker.StillFocused(element), front = FocusTracker.IsForeground(element);
                if (!focused || !front)
                {
                    DebugLog.Write($"target lost focus (focused={focused}, foreground={front}); bringing it back");
                    if (await FocusTracker.RestoreFocusAsync(element, pending.Window))
                        DebugLog.Write("focus restored");
                    else
                    {
                        DebugLog.Write("could not restore focus; result left on the clipboard");
                        TextAccess.TrySetClipboard(pending.Result);
                        _notify("Focus changed", $"The {pending.Action.Verb().ToLowerInvariant()}d text was copied to the clipboard instead.", NoticeLevel.Info);
                        return;
                    }
                }

                // A whole-field replace overwrites everything, so make sure the user did not keep typing meanwhile.
                if (!await TextAccess.IsFieldUnchangedAsync(pending.Field, element))
                {
                    DebugLog.Write("the field changed while reviewing; nothing replaced");
                    _notify("Text changed", "The field changed while you were reviewing, so nothing was replaced. Run it again.", NoticeLevel.Info);
                    return;
                }

                await TextAccess.ReplaceAsync(pending.Field, pending.Result, element);
                DebugLog.Write("field replaced");

                // Offer to undo it for a while.
                _undo = new UndoState(element, pending.Field.Text, pending.Result, pending.Field.IsSelection);
                _undoTimer.Stop();
                _undoTimer.Start();
                ShowUndoBar();
            }
            catch (Exception ex)
            {
                DebugLog.Write($"{pending.Action} failed: {ex.GetType().Name}: {ex.Message}");
                _notify($"{pending.Action.Verb()} failed", ex.Message, NoticeLevel.Error);
            }
            finally
            {
                _cts = null;
                _writing = false;
                _overlay.SetBusy(false);
            }
        }
    }
}
