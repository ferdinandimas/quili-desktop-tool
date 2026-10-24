using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using Quili.Core;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>Opened from Settings: what is hidden before text is sent (secrets, emails), and in which apps the button shows.</summary>
    public partial class PrivacyWindow : Window
    {
        readonly Settings _settings;

        public PrivacyWindow(Settings settings)
        {
            InitializeComponent();
            _settings = settings;
            RedactBox.IsChecked = settings.RedactSecrets;
            EmailBox.IsChecked = settings.RedactEmails;
            HistoryBox.IsChecked = settings.KeepHistory;
            OnlyBox.IsChecked = settings.AppFilterMode == AppFilter.OnlyMode;
            AppsBox.Text = settings.AppFilterList;
            ContentRendered += (_, _) => BringToFront();
        }

        /// <summary>Same as Settings: make sure the window comes up in front, even when it was opened from a window that never takes focus.</summary>
        void BringToFront()
        {
            Topmost = true;
            Native.ForceForeground(new WindowInteropHelper(this).Handle);
            Activate();
            Topmost = false;
        }

        // The card has no title bar: the header is the drag handle, and the X closes without saving.
        void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        }

        void Close_Click(object sender, RoutedEventArgs e) => Close();

        void Save_Click(object sender, RoutedEventArgs e)
        {
            _settings.RedactSecrets = RedactBox.IsChecked == true;
            _settings.RedactEmails = EmailBox.IsChecked == true;
            _settings.KeepHistory = HistoryBox.IsChecked == true;
            if (!_settings.KeepHistory) HistoryStore.Clear(); // turning it off also clears what was kept
            _settings.AppFilterMode = OnlyBox.IsChecked == true ? AppFilter.OnlyMode : AppFilter.HideMode;
            _settings.AppFilterList = AppsBox.Text.Trim();
            _settings.Save();
            DialogResult = true;
        }
    }
}
