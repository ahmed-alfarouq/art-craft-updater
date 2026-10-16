using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Windows;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Explicit install confirmation and truthful progress surface. Nothing
    /// runs until the Install button is chosen; closing the dialog runs
    /// nothing. While an install runs the dialog cannot be closed, because
    /// the engine transaction is non-interruptible and killing it could
    /// leave files inconsistent. Results are reported exactly as returned:
    /// success only on engine-confirmed success, rollback only when the
    /// engine confirms it.
    /// </summary>
    public partial class InstallDialog : Window
    {
        private readonly UpdateExecutionService _service;
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private bool _running;
        private bool _attempted;

        public List<InstallAttempt> Attempts { get; private set; }
        public bool InstallAttempted { get { return _attempted; } }
        public bool AllSucceeded { get { return _attempted && Attempts != null && Attempts.Count > 0 && Attempts.All(a => a.Success); } }

        public InstallDialog(List<AppListItem> items, string bridgeScript, InstallTracker tracker)
        {
            if (items == null) { throw new ArgumentNullException(nameof(items)); }
            InitializeComponent();
            InstallList.ItemsSource = items;
            _service = new UpdateExecutionService(bridgeScript, tracker ?? new InstallTracker());
            InstallButton.Click += async (sender, args) => await RunAsync(items);
            CloseButton.Click += (sender, args) => { DialogResult = _attempted && AllSucceeded; };
            Closing += (sender, args) => { if (_running) { args.Cancel = true; } };
            Closed += (sender, args) =>
            {
                try { _cts.Cancel(); } catch { }
                _cts.Dispose();
            };
        }

        private async System.Threading.Tasks.Task RunAsync(List<AppListItem> items)
        {
            if (_running || _attempted) { return; }
            _running = true;
            InstallButton.IsEnabled = false;
            CloseButton.IsEnabled = false;
            PhaseText.Text = "Installing " + items.Count + " update(s)...";
            ResultText.Visibility = Visibility.Collapsed;
            try
            {
                List<InstallAttempt> attempts = await _service.ExecuteAsync(items, _cts.Token).ConfigureAwait(true);
                Attempts = attempts;
                _attempted = true;
                int ok = attempts.Count(a => a.Success);
                if (ok == attempts.Count && attempts.Count > 0)
                {
                    PhaseText.Text = "Completed: " + ok + " of " + attempts.Count + " update(s) installed and verified.";
                }
                else
                {
                    PhaseText.Text = "Finished with failures: " + ok + " of " + attempts.Count + " update(s) installed.";
                }
                ResultText.Text = string.Join("\n", attempts.Select(Describe).ToArray());
                ResultText.Visibility = Visibility.Visible;
            }
            catch (OperationCanceledException)
            {
                PhaseText.Text = "Cancelled before starting. Nothing was installed.";
            }
            catch (Exception ex) when (!(ex is OutOfMemoryException))
            {
                _attempted = true;
                PhaseText.Text = "Install could not run: " + ex.Message;
            }
            finally
            {
                _running = false;
                CloseButton.IsEnabled = true;
            }
        }

        private static string Describe(InstallAttempt attempt)
        {
            string line = attempt.DisplayName + ": " + (attempt.Success ? "installed" : "not installed") +
                " (" + attempt.Outcome + ")";
            if (!string.IsNullOrWhiteSpace(attempt.StageReached))
            {
                line += " [stage: " + attempt.StageReached + "]";
            }
            if (attempt.RollbackPerformed)
            {
                string rb = attempt.RollbackSucceeded == true ? "rolled back" :
                    (attempt.RollbackSucceeded == false ? "rollback FAILED" : "rollback state unknown");
                line += " [" + rb + "]";
            }
            if (attempt.Success && !string.IsNullOrWhiteSpace(attempt.InstalledVersionAfter))
            {
                line += " [now: " + attempt.InstalledVersionAfter + "]";
            }
            return line;
        }
    }
}
