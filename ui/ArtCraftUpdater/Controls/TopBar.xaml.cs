using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Presentation states for the top bar. Phase 2A.1 drives these from mock
    /// presentation state only; no update operations are attached.
    /// </summary>
    public enum TopBarStatus
    {
        Default,
        Checking,
        Error,
        UpToDate
    }

    public partial class TopBar : UserControl
    {
        private readonly object _checkAgainContent;

        public TopBar()
        {
            InitializeComponent();
            _checkAgainContent = CheckAgainButton.Content;
        }

        /// <summary>
        /// Applies a presentation state. hasSelection drives Update selected;
        /// hasUpdates drives Update all. While checking, all buttons are off.
        /// </summary>
        public void SetStatus(TopBarStatus status, string message, bool hasSelection, bool hasUpdates)
        {
            var muted = (Brush)FindResource("MutedBrush");
            var success = (Brush)FindResource("SuccessBrush");
            var warning = (Brush)FindResource("WarningBrush");
            switch (status)
            {
                case TopBarStatus.Checking:
                    SubheaderText.Text = message ?? "Checking for updates...";
                    SubheaderText.Foreground = muted;
                    CheckingSpinner.Visibility = Visibility.Visible;
                    CheckAgainButton.Content = "Checking...";
                    CheckAgainButton.IsEnabled = false;
                    UpdateSelectedButton.IsEnabled = false;
                    UpdateAllButton.IsEnabled = false;
                    break;
                case TopBarStatus.Error:
                    SubheaderText.Text = message ?? "Could not check for updates.";
                    SubheaderText.Foreground = warning;
                    CheckingSpinner.Visibility = Visibility.Collapsed;
                    CheckAgainButton.Content = _checkAgainContent;
                    CheckAgainButton.IsEnabled = true;
                    UpdateSelectedButton.IsEnabled = hasSelection;
                    UpdateAllButton.IsEnabled = hasUpdates;
                    break;
                case TopBarStatus.UpToDate:
                    SubheaderText.Text = message ?? "All apps are up to date.";
                    SubheaderText.Foreground = success;
                    CheckingSpinner.Visibility = Visibility.Collapsed;
                    CheckAgainButton.Content = _checkAgainContent;
                    CheckAgainButton.IsEnabled = true;
                    UpdateSelectedButton.IsEnabled = false;
                    UpdateAllButton.IsEnabled = false;
                    break;
                default:
                    SubheaderText.Text = message ?? "1 update available \u00b7 last checked today at 22:11";
                    SubheaderText.Foreground = muted;
                    CheckingSpinner.Visibility = Visibility.Collapsed;
                    CheckAgainButton.Content = _checkAgainContent;
                    CheckAgainButton.IsEnabled = true;
                    UpdateSelectedButton.IsEnabled = hasSelection;
                    UpdateAllButton.IsEnabled = hasUpdates;
                    break;
            }
        }
    }
}
