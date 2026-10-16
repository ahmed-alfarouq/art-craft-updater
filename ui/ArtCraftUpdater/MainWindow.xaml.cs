using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace ArtCraftUpdater.Wpf
{
    public partial class MainWindow : Window
    {
        private readonly AppListState _selection = new AppListState();
        private List<AppListItem> _items = new List<AppListItem>();
        private CancellationTokenSource _checkCts;
        private CancellationTokenSource _validateCts;
        private int _checkSeq;
        private ApprovalRecord _lastApproval;
        private readonly InstallTracker _tracker = new InstallTracker();
        private readonly string _bridgeScript;

        public MainWindow()
        {
            InitializeComponent();
            _bridgeScript = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "ArtCraftBridge.ps1");
            AppList.SelectionChanged += AppList_SelectionChanged;
            TopBar.CheckAgainButton.Click += async (sender, args) => await RefreshAsync();
            TopBar.UpdateSelectedButton.Click += async (sender, args) => await OpenReviewAsync(forAll: false);
            TopBar.UpdateAllButton.Click += async (sender, args) => await OpenReviewAsync(forAll: true);
            Loaded += async (sender, args) => await RefreshAsync();
            Closed += (sender, args) =>
            {
                try { _checkCts?.Cancel(); } catch { }
                try { _validateCts?.Cancel(); } catch { }
            };
        }

        private async Task RefreshAsync()
        {
            if (_checkCts != null) { return; }
            int seq = ++_checkSeq;
            _checkCts = new CancellationTokenSource();
            _lastApproval = null;
            TopBar.SetStatus(TopBarStatus.Checking, "Checking for updates...", false, false);
            try
            {
                var client = new BridgeClient(_bridgeScript);
                var service = new UpdateCheckService(client);
                List<AppListItem> rows = await Task.Run(
                    () => service.GetRowsAsync(_checkCts.Token)).ConfigureAwait(true);
                if (seq != _checkSeq) { return; }
                _items = rows;
                AppList.ItemsSource = _items;
                _selection.Clear();
                int failed = _items.Count(i => i.StatusKind == AppStatusKind.Failed ||
                                               i.StatusKind == AppStatusKind.Unknown);
                int updates = _items.Count(i => i.StatusKind == AppStatusKind.UpdateAvailable);
                string when = DateTime.Now.ToString("HH:mm");
                if (failed > 0 && updates == 0 && _items.Count > 0)
                {
                    TopBar.SetStatus(TopBarStatus.Error,
                        failed + " check(s) failed \u00b7 last checked today at " + when, false, false);
                }
                else if (updates > 0)
                {
                    TopBar.SetStatus(TopBarStatus.Default,
                        updates + " update(s) available \u00b7 last checked today at " + when, false, false);
                }
                else
                {
                    TopBar.SetStatus(TopBarStatus.UpToDate,
                        "All apps are up to date \u00b7 last checked today at " + when, false, false);
                }
            }
            catch (Exception ex) when (!(ex is OutOfMemoryException))
            {
                if (seq != _checkSeq) { return; }
                TopBar.SetStatus(TopBarStatus.Error,
                    "Could not check for updates: " + ex.Message, false, false);
            }
            finally
            {
                if (_checkCts != null) { _checkCts.Dispose(); _checkCts = null; }
            }
        }

        private async Task OpenReviewAsync(bool forAll)
        {
            if (_validateCts != null) { return; }
            List<AppListItem> targets = forAll
                ? _items.Where(i => i.StatusKind == AppStatusKind.UpdateAvailable).ToList()
                : _items.Where(i => i.StatusKind == AppStatusKind.UpdateAvailable &&
                                    _selection.SelectedIds.Contains(i.Id)).ToList();
            if (targets.Count == 0)
            {
                TopBar.SetStatus(TopBarStatus.Default,
                    forAll ? "No updates available." : "No selected applications have updates available.",
                    _selection.HasSelection, _selection.HasUpdates(_items));
                return;
            }
            ApprovalCheck approval = ApprovalValidation.Validate(
                _lastApproval != null ? _lastApproval.Applications : null,
                _lastApproval != null ? _lastApproval.ApprovedAtUtc : DateTime.MinValue,
                _items, targets, DateTime.UtcNow);
            if (approval.Ok)
            {
                await RunInstallAsync(targets).ConfigureAwait(true);
                return;
            }
            _validateCts = new CancellationTokenSource();
            SetUpdateButtonsEnabled(false);
            try
            {
                Dictionary<string, List<string>> warnings = await FetchTargetWarningsAsync(targets, _validateCts.Token).ConfigureAwait(true);
                var flat = new List<string>();
                foreach (var item in targets)
                {
                    if (warnings.TryGetValue(item.Id, out List<string> list))
                    {
                        flat.AddRange(list.Select(w => item.Name + ": " + w));
                    }
                }
                var dialog = new ReviewDialog(targets, flat);
                dialog.Owner = this;
                bool? confirmed = dialog.ShowDialog();
                if (confirmed == true && dialog.Approval != null)
                {
                    _lastApproval = dialog.Approval;
                    TopBar.SetStatus(TopBarStatus.Default,
                        "Approval recorded for " + targets.Count + " update(s). Nothing was installed. Choose Update again to install.",
                        _selection.HasSelection, _selection.HasUpdates(_items));
                }
                else
                {
                    TopBar.SetStatus(TopBarStatus.Default,
                        "Review cancelled. Nothing was changed.",
                        _selection.HasSelection, _selection.HasUpdates(_items));
                }
            }
            catch (Exception ex) when (!(ex is OutOfMemoryException))
            {
                TopBar.SetStatus(TopBarStatus.Error,
                    "Could not validate update targets: " + ex.Message, false, false);
            }
            finally
            {
                if (_validateCts != null) { _validateCts.Dispose(); _validateCts = null; }
                SetUpdateButtonsEnabled(true);
            }
        }

        private async Task RunInstallAsync(List<AppListItem> targets)
        {
            var dialog = new InstallDialog(targets, _bridgeScript, _tracker);
            dialog.Owner = this;
            dialog.ShowDialog();
            if (dialog.InstallAttempted)
            {
                _lastApproval = null;
                await RefreshAsync().ConfigureAwait(true);
            }
        }

        private async Task<Dictionary<string, List<string>>> FetchTargetWarningsAsync(
            List<AppListItem> targets, CancellationToken token)
        {
            var result = new Dictionary<string, List<string>>();
            var client = new BridgeClient(_bridgeScript);
            foreach (AppListItem item in targets)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    string safeId = item.Id.Replace("\\", "\\\\").Replace("\"", "\\\"");
                    string packed = await client.InvokeOperationAsync(
                        "validate-target", "{\"appId\":\"" + safeId + "\"}", token).ConfigureAwait(false);
                    var lines = new List<string>();
                    using (var wrapper = System.Text.Json.JsonDocument.Parse(packed))
                    using (var document = System.Text.Json.JsonDocument.Parse(
                        wrapper.RootElement.GetProperty("line").GetString()))
                    {
                        JsonElement root = document.RootElement;
                        JsonElement ok = default(JsonElement);
                        JsonElement data = default(JsonElement);
                        JsonElement warnings = default(JsonElement);
                        bool hasOk = root.TryGetProperty("ok", out ok) && ok.GetBoolean();
                        bool hasWarnings = hasOk && root.TryGetProperty("data", out data) &&
                            data.TryGetProperty("warnings", out warnings) &&
                            warnings.ValueKind == System.Text.Json.JsonValueKind.Array;
                        if (hasWarnings)
                        {
                            foreach (System.Text.Json.JsonElement w in warnings.EnumerateArray())
                            {
                                if (w.ValueKind == System.Text.Json.JsonValueKind.String) { lines.Add(w.GetString()); }
                            }
                        }
                        else if (root.TryGetProperty("error", out System.Text.Json.JsonElement err))
                        {
                            lines.Add("validation unavailable: " + err.ToString());
                        }
                        else if (!hasOk)
                        {
                            lines.Add("validation unavailable: bridge reported failure");
                        }
                    }
                    result[item.Id] = lines;
                }
                catch (Exception ex) when (!(ex is OutOfMemoryException))
                {
                    result[item.Id] = new List<string> { "validation unavailable: " + ex.Message };
                }
            }
            return result;
        }

        private void SetUpdateButtonsEnabled(bool enabled)
        {
            TopBar.UpdateSelectedButton.IsEnabled = enabled && _selection.HasSelection;
            TopBar.UpdateAllButton.IsEnabled = enabled && _selection.HasUpdates(_items);
        }

        private void AppList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            _selection.Clear();
            foreach (AppListItem item in AppList.SelectedItems.OfType<AppListItem>())
            {
                _selection.Toggle(item.Id);
            }
        }
    }
}
