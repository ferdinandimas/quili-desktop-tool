using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// A small always-on-top card of text chips beside the overlay button: the tone presets while the pointer is on the
    /// pill, and Undo / Original after a replace. Never activated, so focus stays in the field.
    /// </summary>
    public partial class ChipBarWindow : Window
    {
        const double GapDip = 6, ChipSpacingDip = 6;

        static readonly Brush TextBrush = Frozen("#1F2A24"), HoverTextBrush = Frozen("#1B7F3A"), HoverBrush = Frozen("#E4F4E9"),
            SelectedBorderBrush = Frozen("#3DBE4A");

        readonly IntPtr _hwnd;
        string _shown = ""; // the chips currently built, so showing the same bar again does not rebuild it

        public ChipBarWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
        }

        /// <summary>The chip at this index was clicked.</summary>
        public event Action<int>? ChipClicked;

        /// <summary>The pointer entered (true) or left (false) the bar.</summary>
        public event Action<bool>? HoverChanged;

        public bool IsShown => IsVisible;

        /// <summary>Screen rectangle (pixels) the bar occupies; empty while hidden. A bubble can anchor to it.</summary>
        public System.Drawing.Rectangle Area { get; private set; }

        static Brush Frozen(string color)
        {
            var brush = (Brush)new BrushConverter().ConvertFromString(color)!;
            brush.Freeze();
            return brush;
        }

        void Card_MouseEnter(object sender, MouseEventArgs e) => HoverChanged?.Invoke(true);

        void Card_MouseLeave(object sender, MouseEventArgs e) => HoverChanged?.Invoke(false);

        void Build(IReadOnlyList<string> chips, int? selected)
        {
            Row.Children.Clear();
            for (int i = 0; i < chips.Count; i++)
            {
                int index = i;
                bool isSelected = selected == i; // the tone in use: tint, green ink text and a green border
                var label = new TextBlock { Text = chips[i], FontSize = 12.5, Foreground = isSelected ? HoverTextBrush : TextBrush, VerticalAlignment = VerticalAlignment.Center };
                var chip = new Border
                {
                    Child = label,
                    Padding = new Thickness(9, 4, 9, 4),
                    BorderThickness = new Thickness(1),
                    BorderBrush = isSelected ? SelectedBorderBrush : Brushes.Transparent,
                    CornerRadius = new CornerRadius(7),
                    Background = isSelected ? HoverBrush : Brushes.Transparent,
                    Cursor = Cursors.Hand,
                    Margin = new Thickness(i == 0 ? 0 : ChipSpacingDip, 0, 0, 0),
                };
                chip.MouseEnter += (_, _) => { chip.Background = HoverBrush; label.Foreground = HoverTextBrush; };
                chip.MouseLeave += (_, _) =>
                {
                    chip.Background = isSelected ? HoverBrush : Brushes.Transparent;
                    label.Foreground = isSelected ? HoverTextBrush : TextBrush;
                };
                chip.MouseLeftButtonUp += (_, _) => ChipClicked?.Invoke(index);
                Row.Children.Add(chip);
            }
        }

        /// <summary>
        /// Shows <paramref name="chips"/> right-aligned (or, with <paramref name="centered"/>, centred horizontally) above
        /// <paramref name="anchor"/> (screen pixels), or below it when <paramref name="preferAbove"/> is false or there is
        /// no room; kept inside the screen's work area. The chip at <paramref name="selected"/> (if any) is drawn as the one in use.
        /// </summary>
        public void Show(IReadOnlyList<string> chips, System.Drawing.Rectangle anchor, bool preferAbove, bool centered = false, int? selected = null)
        {
            if (anchor.IsEmpty || chips.Count == 0) return;
            var key = string.Join("\u001f", chips) + "\u001e" + selected;
            if (key != _shown) { Build(chips, selected); _shown = key; }

            if (!IsVisible) Show();

            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            Card.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            int w = (int)Math.Ceiling(Card.DesiredSize.Width * scale), h = (int)Math.Ceiling(Card.DesiredSize.Height * scale);
            int gap = (int)Math.Round(GapDip * scale);

            var area = System.Windows.Forms.Screen.FromRectangle(anchor).WorkingArea;
            int wanted = centered ? anchor.Left + (anchor.Width - w) / 2 : anchor.Right - w;
            int x = Math.Max(area.Left, Math.Min(wanted, area.Right - w));
            int above = anchor.Top - gap - h, below = anchor.Bottom + gap;
            int y = preferAbove
                ? (above >= area.Top ? above : Math.Min(below, area.Bottom - h))
                : (below + h <= area.Bottom ? below : Math.Max(above, area.Top));

            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
            Area = new System.Drawing.Rectangle(x, y, w, h);
        }

        public void HideBar()
        {
            _shown = "";
            Area = System.Drawing.Rectangle.Empty;
            Row.Children.Clear();
            if (IsVisible) Hide();
        }
    }
}
