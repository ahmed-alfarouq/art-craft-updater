using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Maps bridge rows onto the existing AppListItem UI model. Unknown or
    /// malformed states fall back to Unknown; nothing here installs anything.
    /// </summary>
    public sealed class UpdateCheckService
    {
        private readonly BridgeClient _bridge;

        public UpdateCheckService(BridgeClient bridge)
        {
            _bridge = bridge ?? throw new ArgumentNullException(nameof(bridge));
        }

        public async Task<List<AppListItem>> GetRowsAsync(CancellationToken cancellationToken)
        {
            using (JsonDocument response = await _bridge.InvokeAsync("check-updates", cancellationToken).ConfigureAwait(false))
            {
                JsonElement root = response.RootElement;
                if (!root.TryGetProperty("ok", out JsonElement ok) || !ok.GetBoolean())
                {
                    string message = "bridge reported failure";
                    if (root.TryGetProperty("error", out JsonElement err) &&
                        err.TryGetProperty("message", out JsonElement msg) &&
                        msg.ValueKind == JsonValueKind.String)
                    {
                        message = msg.GetString();
                    }
                    throw new InvalidOperationException(message);
                }
                var items = new List<AppListItem>();
                if (root.TryGetProperty("data", out JsonElement data) &&
                    data.TryGetProperty("rows", out JsonElement rows) &&
                    rows.ValueKind == JsonValueKind.Array)
                {
                    foreach (JsonElement row in rows.EnumerateArray())
                    {
                        items.Add(MapRow(row));
                    }
                }
                return items;
            }
        }

        internal static AppListItem MapRow(JsonElement row)
        {
            string state = GetString(row, "state");
            AppStatusKind kind;
            switch (state)
            {
                case "UpdateAvailable": kind = AppStatusKind.UpdateAvailable; break;
                case "UpToDate": kind = AppStatusKind.UpToDate; break;
                case "Checking": kind = AppStatusKind.Checking; break;
                case "Failed": kind = AppStatusKind.Failed; break;
                default: kind = AppStatusKind.Unknown; break;
            }
            string installed = GetString(row, "installedVersion");
            string latest = GetString(row, "latestVersion");
            string reason = GetString(row, "reason");
            string name = GetString(row, "displayName");
            return new AppListItem
            {
                Id = GetString(row, "appId"),
                Name = string.IsNullOrEmpty(name) ? GetString(row, "appId") : name,
                Initial = string.IsNullOrEmpty(name) ? "?" : name.Substring(0, 1).ToUpperInvariant(),
                InstalledVersion = string.IsNullOrEmpty(installed) ? "-" : installed,
                LatestVersion = string.IsNullOrEmpty(latest) ? "-" : latest,
                StatusKind = kind,
                StatusText = string.IsNullOrEmpty(reason) ? kind.ToString() : reason
            };
        }

        private static string GetString(JsonElement row, string name)
        {
            if (row.TryGetProperty(name, out JsonElement value) &&
                value.ValueKind == JsonValueKind.String)
            {
                return value.GetString() ?? string.Empty;
            }
            return string.Empty;
        }
    }
}
