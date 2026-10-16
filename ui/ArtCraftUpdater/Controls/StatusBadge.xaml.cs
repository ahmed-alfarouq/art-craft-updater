using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Reusable status pill. Status is always carried as readable text, never
    /// color alone. Colors come from the shared theme tokens.
    /// </summary>
    public partial class StatusBadge : UserControl
    {
        public static readonly DependencyProperty KindProperty =
            DependencyProperty.Register("Kind", typeof(AppStatusKind), typeof(StatusBadge),
                new PropertyMetadata(AppStatusKind.Unknown, OnKindChanged));

        public static readonly DependencyProperty TextProperty =
            DependencyProperty.Register("Text", typeof(string), typeof(StatusBadge),
                new PropertyMetadata("Unknown", OnTextChanged));

        public AppStatusKind Kind
        {
            get { return (AppStatusKind)GetValue(KindProperty); }
            set { SetValue(KindProperty, value); }
        }

        public string Text
        {
            get { return (string)GetValue(TextProperty); }
            set { SetValue(TextProperty, value); }
        }

        public StatusBadge()
        {
            InitializeComponent();
            ApplyKind();
        }

        private static void OnKindChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            ((StatusBadge)d).ApplyKind();
        }

        private static void OnTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            ((StatusBadge)d).Label.Text = (string)e.NewValue ?? string.Empty;
        }

        private void ApplyKind()
        {
            Label.Text = Text;
            Brush foreground = TryBrush("TextSecondaryBrush");
            Brush background = TryBrush("SurfaceBrush");
            Brush border = TryBrush("BorderBrush");
            switch (Kind)
            {
                case AppStatusKind.UpdateAvailable:
                    foreground = TryBrush("WarningBrush", foreground);
                    background = TryBrush("WarningBackgroundBrush", background);
                    border = TryBrush("WarningBrush", border);
                    break;
                case AppStatusKind.UpToDate:
                    foreground = TryBrush("SuccessBrush", foreground);
                    background = TryBrush("SuccessBackgroundBrush", background);
                    border = TryBrush("SuccessBrush", border);
                    break;
                case AppStatusKind.Checking:
                    break;
                case AppStatusKind.Failed:
                    // Spec: failure states are amber-toned, like update-available.
                    foreground = TryBrush("WarningBrush", foreground);
                    background = TryBrush("WarningBackgroundBrush", background);
                    border = TryBrush("WarningBrush", border);
                    break;
                default:
                    foreground = TryBrush("MutedBrush", foreground);
                    break;
            }
            Label.Foreground = foreground;
            Pill.Background = background;
            Pill.BorderBrush = border;
        }

        private Brush TryBrush(string key, Brush fallback = null)
        {
            var found = TryFindResource(key) as Brush;
            if (found != null) { return found; }
            if (fallback != null) { return fallback; }
            return SystemColors.ControlTextBrush;
        }
    }
}
