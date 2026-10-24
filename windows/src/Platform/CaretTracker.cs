using System;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Quili.Platform
{
    /// <summary>
    /// Follows the typing caret of the focused text field, so the ✦ button can step aside when the caret reaches it.
    /// Polls UI Automation on its own thread (UIA calls into other processes can be slow) and reports the caret's box
    /// in screen pixels only when it moves; null when the app doesn't report one.
    /// </summary>
    public sealed class CaretTracker : IDisposable
    {
        readonly Thread _thread;
        readonly object _lock = new();
        AutomationElement? _element;
        Rect? _last;
        volatile bool _stop;

        /// <summary>Raised on the polling thread.</summary>
        public event Action<Rect?>? CaretChanged;

        public CaretTracker()
        {
            _thread = new Thread(Loop) { IsBackground = true, Name = "CaretTracker" };
        }

        public void Start() => _thread.Start();
        public void Dispose() => _stop = true;

        /// <summary>The field to follow, or null when no field is focused.</summary>
        public void Follow(AutomationElement? field)
        {
            lock (_lock) { _element = field; _last = null; }
        }

        void Loop()
        {
            while (!_stop)
            {
                AutomationElement? field;
                lock (_lock) field = _element;
                if (field != null)
                {
                    var box = CaretBox(field);
                    bool changed;
                    lock (_lock) { changed = !Equals(box, _last) && ReferenceEquals(field, _element); if (changed) _last = box; }
                    if (changed) CaretChanged?.Invoke(box);
                }
                Thread.Sleep(100);
            }
        }

        /// <summary>A thin box at the caret (or at the end of the selection), rounded so tiny jitter does not count as movement.</summary>
        static Rect? CaretBox(AutomationElement field)
        {
            try
            {
                if (!field.TryGetCurrentPattern(TextPattern.Pattern, out var p)) return null;
                var selection = ((TextPattern)p).GetSelection();
                if (selection.Length == 0) return null;

                // Collapse the selection to its end: that is where the caret is.
                var caret = selection[0].Clone();
                caret.MoveEndpointByRange(TextPatternRangeEndpoint.Start, caret, TextPatternRangeEndpoint.End);

                // 1. The collapsed range itself: exact where the app reports a box for it.
                var rect = Rects(caret).LastOrDefault();
                if (rect.Height > 0) return Box(rect.Left, rect);

                // 2. Else the character before the caret, whose right edge is the caret (not after a line break:
                //    that character sits at the end of the previous line).
                var before = caret.Clone();
                if (before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1) == -1)
                {
                    var text = before.GetText(2);
                    if (text.IndexOf('\n') < 0 && text.IndexOf('\r') < 0 && text.IndexOf(' ') < 0 && text.IndexOf(' ') < 0)
                    {
                        rect = Rects(before).LastOrDefault();
                        if (rect.Height > 0) return Box(rect.Right, rect);
                    }
                }

                // 3. Else the character after it: its left edge is the caret.
                var after = caret.Clone();
                if (after.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, 1) == 1)
                {
                    rect = Rects(after).FirstOrDefault();
                    if (rect.Height > 0) return Box(rect.Left, rect);
                }
                return null;
            }
            catch (Exception) { return null; }
        }

        static Rect[] Rects(TextPatternRange range)
        {
            try { return range.GetBoundingRectangles(); } catch (Exception) { return Array.Empty<Rect>(); }
        }

        static Rect Box(double x, Rect r) => new(Math.Round(x), Math.Round(r.Top), 0, Math.Round(r.Height));
    }
}
