using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// An orange "!" in a white ring, half on and half off the round button's top-right edge. The overlay window is only as
    /// big as the pill, so the half that sticks out needs a window of its own, which <see cref="OverlayWindow"/> keeps in place.
    /// It never takes a click, focus or the pointer: the round button underneath keeps every click, hover and tooltip.
    /// </summary>
    sealed class WarningBadgeWindow : Window
    {
        const double SideDip = 14;
        const int WS_EX_TRANSPARENT = 0x00000020;
        IntPtr _hwnd;

        public WarningBadgeWindow()
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            Focusable = false;
            IsHitTestVisible = false;
            Width = SideDip;
            Height = SideDip;

            var grid = new Grid();
            grid.Children.Add(new Ellipse { Fill = Brushes.White });
            grid.Children.Add(new Ellipse { Fill = new SolidColorBrush(Color.FromRgb(0xF5, 0xA5, 0x24)), Margin = new Thickness(1.5) });
            grid.Children.Add(new TextBlock
            {
                Text = "!", FontSize = 10, FontWeight = FontWeights.Bold, Foreground = Brushes.White,
                Margin = new Thickness(0, -1, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            });
            Content = grid;

            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT);
        }

        /// <summary>
        /// Centres the badge on the round button's edge at 45° (up and to the right). (x, y) is the overlay's bottom-right
        /// button box in pixels, <paramref name="size"/> its side, <paramref name="scale"/> the DPI scale.
        /// </summary>
        public void PlaceNear(int x, int y, int size, double scale)
        {
            int side = (int)Math.Round(SideDip * scale);
            double radius = size / 2.0 - scale; // the green button is the box minus 1 dip on every side
            double offset = radius * Math.Sqrt(2) / 2;
            int left = (int)Math.Round(x + size / 2.0 + offset - side / 2.0);
            int top = (int)Math.Round(y + size / 2.0 - offset - side / 2.0);
            if (!IsVisible) Show();
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, left, top, side, side, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        public void Conceal()
        {
            if (IsVisible) Hide();
        }
    }
}
