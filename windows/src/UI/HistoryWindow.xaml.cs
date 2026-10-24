using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Quili.Core;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// "Recent rewrites": the last 10 requests (paraphrase, translate, summaries), newest first, each with what was sent and
    /// what came back and chips to copy either. Opened from the History chip that shows over the sparkle button.
    /// </summary>
    public partial class HistoryWindow : Window
    {
        readonly Settings _settings;

        public HistoryWindow(Settings settings)
        {
            InitializeComponent();
            _settings = settings;
            Reload();
            KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); }; // not a modal dialog, so no IsCancel button
            ContentRendered += (_, _) => BringToFront();
        }

        /// <summary>Raised to the front once, then an ordinary window (so other windows can cover it later), like Settings.</summary>
        public void BringToFront()
        {
            Topmost = true;
            Native.ForceForeground(new WindowInteropHelper(this).Handle);
            Activate();
            Topmost = false;
        }

        /// <summary>Rebuilds the list from the store (each time the window opens, and after Clear).</summary>
        public void Reload()
        {
            List.Children.Clear();
            var entries = HistoryStore.Load();
            if (entries.Count == 0)
            {
                EmptyText.Text = _settings.KeepHistory
                    ? "Nothing here yet. Your last 10 rewrites will show up here."
                    : "Nothing here yet. Your last 10 rewrites will show up here.\nHistory is turned off in Privacy & apps.";
                EmptyText.Visibility = Visibility.Visible;
                Scroller.Visibility = Visibility.Collapsed;
                return;
            }
            EmptyText.Visibility = Visibility.Collapsed;
            Scroller.Visibility = Visibility.Visible;
            for (int i = 0; i < entries.Count; i++)
            {
                if (i > 0) List.Children.Add(new Border { Height = 1, Background = (Brush)FindResource("LineSoft") });
                List.Children.Add(BuildRow(entries[i]));
            }
            Scroller.ScrollToTop();
        }

        UIElement BuildRow(HistoryStore.Entry entry)
        {
            var row = new StackPanel { Margin = new Thickness(0, 14, 0, 14) };

            var title = new TextBlock { TextWrapping = TextWrapping.Wrap };
            title.Inlines.Add(new System.Windows.Documents.Run(Label(entry.Kind))
            {
                FontWeight = FontWeights.Bold, FontSize = 15, Foreground = (Brush)FindResource("Ink"),
            });
            var meta = $" · {When(entry.Time)}" + (string.IsNullOrWhiteSpace(entry.App) ? "" : $" · {entry.App}");
            title.Inlines.Add(new System.Windows.Documents.Run(meta) { FontSize = 13, Foreground = (Brush)FindResource("Muted") });
            row.Children.Add(title);

            if (!string.IsNullOrEmpty(entry.Original))
                row.Children.Add(Snippet(entry.Original, 13.5, 19, 2, "Muted", new Thickness(0, 6, 0, 0)));
            row.Children.Add(Snippet(entry.Result, 14, 20, 3, "Ink", new Thickness(0, 6, 0, 0)));

            var chips = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
            chips.Children.Add(CopyChip("Copy result", entry.Result, first: true));
            if (!string.IsNullOrEmpty(entry.Original)) chips.Children.Add(CopyChip("Copy original", entry.Original, first: false));
            row.Children.Add(chips);
            return row;
        }

        /// <summary>The text cut to <paramref name="lines"/> lines of fixed height with a trailing ellipsis.</summary>
        TextBlock Snippet(string text, double size, double lineHeight, int lines, string brush, Thickness margin) => new()
        {
            Text = text,
            FontSize = size,
            LineHeight = lineHeight,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            MaxHeight = lineHeight * lines,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)FindResource(brush),
            Margin = margin,
        };

        /// <summary>A small outlined chip like the Settings tone chips; a click copies <paramref name="text"/> and the chip reads "Copied" for 1.5 s.</summary>
        Border CopyChip(string caption, string text, bool first)
        {
            var label = new TextBlock
            {
                Text = caption, FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("Ink"),
            };
            var chip = new Border
            {
                Child = label,
                Height = 24,
                Padding = new Thickness(11, 0, 11, 0),
                CornerRadius = new CornerRadius(12),
                BorderThickness = new Thickness(1),
                BorderBrush = (Brush)FindResource("Line"),
                Background = (Brush)FindResource("WhiteBrushForChips"),
                Cursor = Cursors.Hand,
                Margin = new Thickness(first ? 0 : 6, 0, 0, 0),
            };
            void Paint(bool hot)
            {
                chip.Background = (Brush)FindResource(hot ? "GreenTint" : "WhiteBrushForChips");
                label.Foreground = (Brush)FindResource(hot ? "GreenInk" : "Ink");
            }
            chip.MouseEnter += (_, _) => Paint(true);
            chip.MouseLeave += (_, _) => Paint(false);
            chip.MouseLeftButtonUp += (_, _) =>
            {
                TextAccess.TrySetClipboard(text);
                label.Text = "Copied";
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
                timer.Tick += (_, _) => { timer.Stop(); label.Text = caption; };
                timer.Start();
            };
            return chip;
        }

        static string Label(string kind) => kind switch
        {
            "translate" => "Translate to English",
            "summarize" => "Summarize",
            _ => "Paraphrase",
        };

        /// <summary>"Today 11:42", "Yesterday 09:10" or "24 Oct 11:42", in local time.</summary>
        static string When(string iso)
        {
            if (!DateTime.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time)) return "";
            var local = time.ToLocalTime();
            var clock = local.ToString("HH:mm", CultureInfo.InvariantCulture);
            if (local.Date == DateTime.Today) return $"Today {clock}";
            if (local.Date == DateTime.Today.AddDays(-1)) return $"Yesterday {clock}";
            return local.ToString("d MMM", CultureInfo.InvariantCulture) + " " + clock;
        }

        // The card has no title bar: the header is the drag handle.
        void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        }

        void Close_Click(object sender, RoutedEventArgs e) => Close();

        void Clear_Click(object sender, RoutedEventArgs e)
        {
            HistoryStore.Clear();
            Reload();
        }
    }
}
