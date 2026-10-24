using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Navigation;
using Quili.Platform;
using Quili.Core;

namespace Quili.UI
{
    public partial class SettingsWindow : Window
    {
        readonly Settings _settings;
        readonly List<(Border Chip, TextBlock Label, Tone.Preset Preset)> _toneChips = new();
        readonly HashSet<Border> _hoveredChips = new();
        string _tone = ""; // the selected tone's id (empty = none); written to the settings on Save

        public SettingsWindow(Settings settings)
        {
            InitializeComponent();
            _settings = settings;
            _tone = Tone.FindById(settings.Tone)?.Id ?? "";
            BuildToneChips();
            VersionText.Text = $"Version {AppInfo.Version}";
            KeyBox.Password = settings.ApiKey;
            ServerBox.Text = ParaphraseClient.NormalizeServerUrl(settings.ServerUrl);
            StartupBox.IsChecked = settings.RunAtStartup;
            MockBox.IsChecked = settings.MockMode;
            LogBox.IsChecked = settings.LoggingEnabled;
            ContentRendered += (_, _) => BringToFront();
        }

        /// <summary>
        /// Opened from the overlay (a window that never takes focus), Settings could otherwise appear behind the
        /// app the user was in. Raise it above everything and give it focus.
        /// </summary>
        void BringToFront()
        {
            Topmost = true;   // raises it above other windows even if Windows refuses to hand over focus
            Native.ForceForeground(new WindowInteropHelper(this).Handle);
            Activate();
            Topmost = false;
        }

        void RepoLink_RequestNavigate(object sender, RequestNavigateEventArgs e)
        {
            Process.Start(new ProcessStartInfo(AppInfo.RepoUrl) { UseShellExecute = true });
            e.Handled = true;
        }

        /// <summary>One small pill per tone preset; a click selects that tone (the selected one is deselected by another click), kept in the window until Save.</summary>
        void BuildToneChips()
        {
            for (int i = 0; i < Tone.Presets.Count; i++)
            {
                var preset = Tone.Presets[i];
                var label = new TextBlock { Text = preset.Label, FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
                var chip = new Border
                {
                    Child = label,
                    Height = 24,
                    Padding = new Thickness(11, 0, 11, 0),
                    CornerRadius = new CornerRadius(12),
                    BorderThickness = new Thickness(1),
                    Cursor = Cursors.Hand,
                    Margin = new Thickness(i == 0 ? 0 : 6, 0, 0, 0),
                };
                chip.MouseEnter += (_, _) => { _hoveredChips.Add(chip); RefreshToneChips(); };
                chip.MouseLeave += (_, _) => { _hoveredChips.Remove(chip); RefreshToneChips(); };
                chip.MouseLeftButtonUp += (_, _) =>
                {
                    _tone = _tone == preset.Id ? "" : preset.Id;
                    RefreshToneChips();
                };
                _toneChips.Add((chip, label, preset));
                ToneRow.Children.Add(chip);
            }
            RefreshToneChips();
        }

        /// <summary>White with a line border; hovered: green tint and ink; selected: tint, ink and a green border.</summary>
        void RefreshToneChips()
        {
            foreach (var (chip, label, preset) in _toneChips)
            {
                bool selected = preset.Id == _tone, hovered = _hoveredChips.Contains(chip);
                bool tinted = selected || hovered;
                chip.Background = (Brush)FindResource(tinted ? "GreenTint" : "WhiteBrushForChips");
                chip.BorderBrush = (Brush)FindResource(selected ? "Green" : "Line");
                label.Foreground = (Brush)FindResource(tinted ? "GreenInk" : "Ink");
            }
        }

        /// <summary>Secret redaction and the per-app list live in their own window; they save themselves.</summary>
        void PrivacyLink_Click(object sender, RoutedEventArgs e) => new PrivacyWindow(_settings) { Owner = this }.ShowDialog();

        // The card has no title bar: the header is the drag handle, and the X closes without saving.
        void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        }

        void Close_Click(object sender, RoutedEventArgs e) => Close();

        /// <summary>Switches the API key between dots and plain text, carrying what was typed across.</summary>
        void ToggleKey_Click(object sender, RoutedEventArgs e)
        {
            bool reveal = KeyPlain.Visibility != Visibility.Visible;
            if (reveal)
            {
                KeyPlain.Text = KeyBox.Password;
                KeyPlain.Visibility = Visibility.Visible;
                KeyBox.Visibility = Visibility.Collapsed;
                KeyPlain.Focus();
                KeyPlain.CaretIndex = KeyPlain.Text.Length;
            }
            else
            {
                KeyBox.Password = KeyPlain.Text;
                KeyBox.Visibility = Visibility.Visible;
                KeyPlain.Visibility = Visibility.Collapsed;
                KeyBox.Focus();
            }
            EyeIcon.Data = (Geometry)FindResource(reveal ? "EyeGeometry" : "EyeOffGeometry");
        }

        void Save_Click(object sender, RoutedEventArgs e)
        {
            var key = KeyPlain.Visibility == Visibility.Visible ? KeyPlain.Text : KeyBox.Password;
            _settings.ApiKey = key.Trim();
            _settings.ServerUrl = ParaphraseClient.NormalizeServerUrl(ServerBox.Text);
            _settings.Tone = _tone;
            _settings.RunAtStartup = StartupBox.IsChecked == true;
            ApplyMock(MockBox.IsChecked == true);
            ApplyLogging(LogBox.IsChecked == true);
            _settings.Save();
            DialogResult = true;
        }

        /// <summary>Turns the debug log on or off, leaving a note in the log either way (the last line before it goes quiet).</summary>
        void ApplyLogging(bool on)
        {
            if (on == _settings.LoggingEnabled) return;
            if (!on) DebugLog.Write("debug log turned off in Settings");
            _settings.LoggingEnabled = on;
            DebugLog.Enabled = on;
            if (on) DebugLog.Write("debug log turned on in Settings");
        }

        /// <summary>Turns the built-in mock server on (and starts it) or off (and stops it).</summary>
        void ApplyMock(bool on)
        {
            _settings.MockMode = on;
            if (!on) { MockServer.Shared.Stop(); return; }
            try { MockServer.Shared.Start(); }
            catch (Exception ex)
            {
                _settings.MockMode = false;
                DebugLog.Write($"mock server failed to start: {ex.GetType().Name}: {ex.Message}");
                System.Windows.MessageBox.Show(ex.Message, "Mock server failed", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }
}
