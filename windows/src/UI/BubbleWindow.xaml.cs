using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// A small always-on-top card next to the overlay button that shows the rewritten text as it streams in,
    /// before it replaces the field's text. Click-through and never activated, so focus stays in the field.
    /// When the text is final it can turn into a review: the changed words are highlighted and Discard / Apply
    /// buttons decide whether the field is replaced.
    /// </summary>
    public partial class BubbleWindow : Window
    {
        const int WS_EX_TRANSPARENT = 0x20;
        const double GapDip = 6, MaxHeightDip = 150, TallMaxHeightDip = 440, CloseExtraDip = 16, ReviewMinWidthDip = 200;

        static readonly Brush ChangedBackground = Frozen("#D6E8FF"), ChangedForeground = Frozen("#1F4E8C"),
            ApplyBrush = Frozen("#27AE4B"), ApplyHoverBrush = Frozen("#1F9E43"),
            DiscardBrush = Frozen("#FFFFFF"), DiscardHoverBrush = Frozen("#F1F5F2");

        static Brush Frozen(string color)
        {
            var brush = (Brush)new BrushConverter().ConvertFromString(color)!;
            brush.Freeze();
            return brush;
        }

        static readonly TimeSpan FadeDuration = TimeSpan.FromMilliseconds(250);

        readonly IntPtr _hwnd;
        int _fadeId; // bumped by show/hide so a fade that was overtaken does not hide the new bubble

        public BubbleWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE,
                ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT);
        }

        /// <summary>Raised when the close button of a closable bubble is clicked (and for a review's Discard button).</summary>
        public event Action? CloseRequested;

        /// <summary>Raised when a review's Apply button is clicked.</summary>
        public event Action? ApplyRequested;

        /// <summary>A closable bubble takes clicks; the others are click-through so they never get in the way.</summary>
        void SetClickable(bool clickable)
        {
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, clickable ? ex & ~WS_EX_TRANSPARENT : ex | WS_EX_TRANSPARENT);
            IsHitTestVisible = clickable;
            CloseButton.Visibility = clickable ? Visibility.Visible : Visibility.Collapsed;
            Scroller.Margin = new Thickness(0, 0, clickable ? CloseExtraDip : 0, 0);
            Footer.Visibility = Visibility.Collapsed; // only a review has the buttons (ShowReview turns them on)
            Footnote.Visibility = Visibility.Collapsed;
            Footnote.Text = "";
            Card.MinWidth = 0;
        }

        void Close_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => CloseRequested?.Invoke();

        void Discard_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => CloseRequested?.Invoke();
        void Apply_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => ApplyRequested?.Invoke();
        void Discard_MouseEnter(object sender, MouseEventArgs e) => DiscardButton.Background = DiscardHoverBrush;
        void Discard_MouseLeave(object sender, MouseEventArgs e) => DiscardButton.Background = DiscardBrush;
        void Apply_MouseEnter(object sender, MouseEventArgs e) => ApplyButton.Background = ApplyHoverBrush;
        void Apply_MouseLeave(object sender, MouseEventArgs e) => ApplyButton.Background = ApplyBrush;

        /// <summary>
        /// Shows <paramref name="text"/> above <paramref name="anchor"/> (screen pixels), or below it when there is no room.
        /// A <paramref name="tall"/> bubble (a summary) is taller and reads from its first line instead of following the newest ones.
        /// A <paramref name="closable"/> bubble has a close button and takes clicks (it stays until closed).
        /// <paramref name="markdown"/> says whether <c>**bold**</c> is rendered; by default it follows <paramref name="tall"/>.
        /// </summary>
        public void ShowText(string text, System.Drawing.Rectangle anchor, bool tall = false, bool closable = false, bool? markdown = null)
        {
            if (anchor.IsEmpty) return;
            CancelFade();
            SetClickable(closable);
            Scroller.MaxHeight = tall ? TallMaxHeightDip : MaxHeightDip;
            SetBody(text, markdown: markdown ?? tall);
            if (tall) Scroller.ScrollToTop();
            else Scroller.ScrollToBottom(); // long text: keep the newest lines in view
            Place(anchor);
        }

        /// <summary>
        /// Shows the finished rewrite for review: a tall, closable, non-markdown bubble in which the parts listed in
        /// <paramref name="changed"/> (offsets into <paramref name="text"/>) have a soft blue highlight, with Discard and
        /// Apply buttons under it. The close button and Discard raise <see cref="CloseRequested"/>, Apply raises
        /// <see cref="ApplyRequested"/>; the field is not touched by the bubble itself. A <paramref name="footnote"/> (what the review
        /// used as context) is shown in muted text at the footer's left.
        /// </summary>
        public void ShowReview(string text, IReadOnlyList<(int Start, int Length)> changed, System.Drawing.Rectangle anchor, string? footnote = null)
        {
            if (anchor.IsEmpty) return;
            CancelFade();
            SetClickable(true);
            Footer.Visibility = Visibility.Visible;
            Footnote.Text = footnote ?? "";
            Footnote.Visibility = string.IsNullOrEmpty(footnote) ? Visibility.Collapsed : Visibility.Visible;
            DiscardButton.Background = DiscardBrush;
            ApplyButton.Background = ApplyBrush;
            Card.MinWidth = ReviewMinWidthDip;
            Scroller.MaxHeight = TallMaxHeightDip;
            SetHighlightedBody(text, changed);
            Scroller.ScrollToTop();
            Place(anchor);
        }

        /// <summary>Makes the window visible and puts it above <paramref name="anchor"/> (screen pixels), or below it when there is no room.</summary>
        void Place(System.Drawing.Rectangle anchor)
        {
            if (!IsVisible) Show();

            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            Card.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            int w = (int)Math.Ceiling(Card.DesiredSize.Width * scale), h = (int)Math.Ceiling(Card.DesiredSize.Height * scale);
            int gap = (int)Math.Round(GapDip * scale);

            var area = System.Windows.Forms.Screen.FromRectangle(anchor).WorkingArea;
            int x = Math.Max(area.Left, Math.Min(anchor.Right - w, area.Right - w));
            int y = anchor.Top - gap - h;
            if (y < area.Top) y = Math.Min(anchor.Bottom + gap, area.Bottom - h);

            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        /// <summary>Fades the bubble out, then hides it (the close button and the 5 s auto-close); a show or hide meanwhile cancels the fade.</summary>
        public void FadeOut()
        {
            if (!IsVisible) return;
            int id = ++_fadeId;
            SetClickable(false); // already closing: no more clicks
            var fade = new DoubleAnimation(0, FadeDuration);
            fade.Completed += (_, _) => { if (_fadeId == id) HideBubble(); };
            BeginAnimation(OpacityProperty, fade);
        }

        /// <summary>Stops a running fade and makes the window fully opaque again.</summary>
        void CancelFade()
        {
            _fadeId++;
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
        }

        /// <summary>
        /// With <paramref name="markdown"/> (a summary) text between <c>**</c> pairs is bold and the markers are hidden; an
        /// unclosed <c>**</c> (the summary is still streaming) stays bold to the end. Other text is shown as it is.
        /// </summary>
        void SetBody(string text, bool markdown)
        {
            if (!markdown || !text.Contains("**")) { Body.Text = text; return; }
            Body.Inlines.Clear();
            bool bold = false;
            var pieces = text.Split(new[] { "**" }, StringSplitOptions.None);
            for (int i = 0; i < pieces.Length; i++)
            {
                if (i > 0) bold = !bold;
                if (pieces[i].Length == 0) continue;
                var run = new System.Windows.Documents.Run(pieces[i]);
                if (bold) run.FontWeight = FontWeights.Bold;
                Body.Inlines.Add(run);
            }
        }

        /// <summary>The text with the given ranges drawn on a soft blue background in blue ink; the rest as it is.</summary>
        void SetHighlightedBody(string text, IReadOnlyList<(int Start, int Length)> changed)
        {
            Body.Text = "";
            Body.Inlines.Clear();
            int pos = 0;
            foreach (var (start, length) in changed)
            {
                if (start < pos || length <= 0 || start + length > text.Length) continue; // ranges are sorted and inside the text
                if (start > pos) Body.Inlines.Add(new System.Windows.Documents.Run(text[pos..start]));
                Body.Inlines.Add(new System.Windows.Documents.Run(text.Substring(start, length))
                {
                    Background = ChangedBackground,
                    Foreground = ChangedForeground,
                });
                pos = start + length;
            }
            if (pos < text.Length) Body.Inlines.Add(new System.Windows.Documents.Run(text[pos..]));
        }

        public void HideBubble()
        {
            CancelFade();
            SetClickable(false);
            Body.Inlines.Clear();
            Body.Text = "";
            if (IsVisible) Hide();
        }
    }
}
