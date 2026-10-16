using System.Collections.Generic;
using System.Linq;
using System.Windows;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Review surface for a proposed update. Confirm returns true and exposes
    /// an ApprovalRecord; Cancel returns false and records nothing.
    /// Neither path installs, downloads, or modifies anything.
    /// </summary>
    public partial class ReviewDialog : Window
    {
        public ApprovalRecord Approval { get; private set; }

        public ReviewDialog(List<AppListItem> items, List<string> warnings)
        {
            InitializeComponent();
            ReviewList.ItemsSource = items;
            if (warnings != null && warnings.Count > 0)
            {
                WarningsText.Text = string.Join("\n", warnings.ToArray());
                WarningsText.Visibility = Visibility.Visible;
            }
            CancelButton.Click += (sender, args) => { DialogResult = false; };
            ConfirmButton.Click += (sender, args) =>
            {
                Approval = new ApprovalRecord(items);
                DialogResult = true;
            };
        }
    }
}
