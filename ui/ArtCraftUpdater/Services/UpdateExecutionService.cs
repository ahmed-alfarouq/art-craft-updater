using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// One application's execution result. Success is true only when the
    /// bridge reports ok:true AND data.success:true for that application.
    /// Every other path (refusal, failure, timeout, malformed response) is
    /// Success=false with a truthful Outcome; success is never assumed.
    /// </summary>
    public sealed class InstallAttempt
    {
        public string AppId { get; set; }
        public string DisplayName { get; set; }
        public string InstalledVersion { get; set; }
        public string LatestVersion { get; set; }
        public bool Success { get; set; }
        public string Outcome { get; set; }
        public string StageReached { get; set; }
        public bool RollbackPerformed { get; set; }
        public bool? RollbackSucceeded { get; set; }
        public string InstalledVersionAfter { get; set; }
    }

    /// <summary>
    /// Executes approved updates one application at a time through the
    /// bridge install-update operation. Approvals are validated before
    /// starting; duplicates and overlaps are refused by the tracker;
    /// cancellation is honored only between applications, never by killing
    /// a running install (the engine transaction is non-interruptible, so
    /// forcible termination could leave files inconsistent).
    /// </summary>
    public sealed class UpdateExecutionService
    {
        /// <summary>
        /// Generous ceiling for one install (download over slow links plus
        /// verification, staging, and commit). Exceeding it reports unknown
        /// state, never success; the list is then re-checked to reconcile.
        /// </summary>
        public const int InstallTimeoutMs = 1800000;

        private readonly string _bridgeScript;
        private readonly int _timeoutMs;
        private readonly InstallTracker _tracker;

        public UpdateExecutionService(string bridgeScript, InstallTracker tracker, int timeoutMs = InstallTimeoutMs)
        {
            _bridgeScript = bridgeScript ?? throw new ArgumentNullException(nameof(bridgeScript));
            _tracker = tracker ?? throw new ArgumentNullException(nameof(tracker));
            _timeoutMs = timeoutMs;
        }

        public async Task<List<InstallAttempt>> ExecuteAsync(List<AppListItem> targets, CancellationToken cancellationToken)
        {
            var attempts = new List<InstallAttempt>();
            if (targets == null) { return attempts; }
            foreach (AppListItem target in targets)
            {
                if (target == null || string.IsNullOrEmpty(target.Id)) { continue; }
                cancellationToken.ThrowIfCancellationRequested();
                var attempt = new InstallAttempt
                {
                    AppId = target.Id,
                    DisplayName = target.Name,
                    InstalledVersion = target.InstalledVersion,
                    LatestVersion = target.LatestVersion,
                    Success = false,
                    Outcome = string.Empty
                };
                if (!_tracker.TryBegin(target.Id))
                {
                    attempt.Outcome = "another install is already running for " + target.Name + "; refusing to start a duplicate";
                    attempts.Add(attempt);
                    continue;
                }
                try
                {
                    // CancellationToken.None on purpose: once the bridge
                    // process starts its transaction, cancelling here would
                    // kill it mid-commit. Cancellation applies between apps.
                    using (var client = new BridgeClient(_bridgeScript, _timeoutMs))
                    using (JsonDocument response = await client.InvokeAsync(
                        "install-update", BuildParams(target), CancellationToken.None).ConfigureAwait(false))
                    {
                        CopyMapped(attempt, MapResponse(response));
                    }
                }
                catch (TimeoutException)
                {
                    attempt.Outcome = "install timed out; state is unknown and nothing is assumed - re-check updates before retrying";
                }
                catch (OperationCanceledException)
                {
                    attempt.Outcome = "cancelled before starting; nothing was installed";
                }
                catch (Exception ex) when (!(ex is OutOfMemoryException))
                {
                    attempt.Outcome = ex.Message;
                }
                finally
                {
                    _tracker.End(target.Id);
                }
                attempts.Add(attempt);
            }
            return attempts;
        }

        public static void CopyMapped(InstallAttempt attempt, InstallAttempt mapped)
        {
            attempt.Success = mapped.Success;
            attempt.Outcome = mapped.Outcome;
            attempt.StageReached = mapped.StageReached;
            attempt.RollbackPerformed = mapped.RollbackPerformed;
            attempt.RollbackSucceeded = mapped.RollbackSucceeded;
            attempt.InstalledVersionAfter = mapped.InstalledVersionAfter;
        }

        /// <summary>
        /// Maps one validated bridge response to an attempt. Pure function
        /// over the response document; the only success path is ok:true with
        /// data.success:true. Refusals, engine failures, and unreadable
        /// responses all map to Success=false with the real detail.
        /// </summary>
        public static InstallAttempt MapResponse(JsonDocument response)
        {
            var attempt = new InstallAttempt { Success = false, Outcome = string.Empty };
            try
            {
                JsonElement root = response.RootElement;
                if (!root.TryGetProperty("ok", out JsonElement ok) || !ok.GetBoolean())
                {
                    string code = "bridge-error";
                    string message = "bridge reported failure";
                    if (root.TryGetProperty("error", out JsonElement err))
                    {
                        if (err.TryGetProperty("code", out JsonElement c) && c.ValueKind == JsonValueKind.String)
                        {
                            code = c.GetString();
                        }
                        if (err.TryGetProperty("message", out JsonElement m) && m.ValueKind == JsonValueKind.String)
                        {
                            message = m.GetString();
                        }
                    }
                    attempt.Outcome = "install refused (" + code + "): " + message;
                    return attempt;
                }
                if (!root.TryGetProperty("data", out JsonElement data) || data.ValueKind != JsonValueKind.Object)
                {
                    attempt.Outcome = "could not understand the bridge response; nothing is assumed about the install";
                    return attempt;
                }
                bool success = data.TryGetProperty("success", out JsonElement s) && s.GetBoolean();
                attempt.Success = success;
                attempt.Outcome = GetString(data, "outcome");
                attempt.StageReached = GetString(data, "stageReached");
                attempt.RollbackPerformed = data.TryGetProperty("rollbackPerformed", out JsonElement rp) && rp.GetBoolean();
                if (data.TryGetProperty("rollbackSucceeded", out JsonElement rs))
                {
                    if (rs.ValueKind == JsonValueKind.True) { attempt.RollbackSucceeded = true; }
                    else if (rs.ValueKind == JsonValueKind.False) { attempt.RollbackSucceeded = false; }
                }
                attempt.InstalledVersionAfter = GetString(data, "installedVersionAfter");
                if (success && string.IsNullOrWhiteSpace(attempt.Outcome))
                {
                    attempt.Outcome = "installed and verified";
                }
                if (!success && string.IsNullOrWhiteSpace(attempt.Outcome))
                {
                    string detail = attempt.StageReached;
                    if (string.IsNullOrWhiteSpace(detail)) { detail = "the engine reported failure"; }
                    attempt.Outcome = "install failed during " + detail;
                }
                return attempt;
            }
            catch (Exception ex) when (!(ex is OutOfMemoryException))
            {
                attempt.Success = false;
                attempt.Outcome = "could not understand the bridge response (" + ex.Message + "); nothing is assumed about the install";
                return attempt;
            }
        }

        /// <summary>
        /// Parses a raw bridge response line the same way the service does,
        /// so tests and diagnostics share the mapping. Throws only when the
        /// line is not valid protocol JSON at all.
        /// </summary>
        public static InstallAttempt MapResponseLine(string responseLine)
        {
            using (JsonDocument document = JsonDocument.Parse(responseLine))
            {
                return MapResponse(document);
            }
        }

        private static string GetString(JsonElement element, string name)
        {
            if (element.TryGetProperty(name, out JsonElement value) &&
                value.ValueKind == JsonValueKind.String)
            {
                return value.GetString() ?? string.Empty;
            }
            return string.Empty;
        }

        public static string BuildParams(AppListItem target)
        {
            return "{\"appId\":\"" + JsonEscape(target.Id) +
                "\",\"installedVersion\":\"" + JsonEscape(target.InstalledVersion) +
                "\",\"latestVersion\":\"" + JsonEscape(target.LatestVersion) + "\"}";
        }

        public static string JsonEscape(string value)
        {
            if (value == null) { return string.Empty; }
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"")
                .Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");
        }
    }
}
