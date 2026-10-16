using System;
using System.Collections.Generic;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Outcome of approval validation: Ok plus a machine-readable reason
    /// that the UI surfaces truthfully. Reasons are stable strings so tests
    /// and the bridge error codes stay aligned.
    /// </summary>
    public sealed class ApprovalCheck
    {
        public ApprovalCheck(bool ok, string reason)
        {
            Ok = ok;
            Reason = reason ?? string.Empty;
        }

        public bool Ok { get; private set; }
        public string Reason { get; private set; }
    }

    /// <summary>
    /// Pure approval-binding rules. An approval is usable only when it is
    /// present, unexpired, and every target still matches the currently
    /// checked rows by application, installed version, latest version, and
    /// update-available status. Anything else is missing, expired, stale,
    /// or mismatched and must force a fresh review. No I/O, no UI.
    /// </summary>
    public static class ApprovalValidation
    {
        public const int ApprovalTtlMinutes = 30;

        public static ApprovalCheck Validate(
            List<AppListItem> approved,
            DateTime approvedAtUtc,
            List<AppListItem> current,
            List<AppListItem> targets,
            DateTime utcNow)
        {
            if (approved == null || approved.Count == 0)
            {
                return new ApprovalCheck(false, "no-approval");
            }
            if (utcNow - approvedAtUtc > TimeSpan.FromMinutes(ApprovalTtlMinutes))
            {
                return new ApprovalCheck(false, "approval-expired");
            }
            if (targets == null || targets.Count == 0)
            {
                return new ApprovalCheck(false, "no-targets");
            }
            var currentById = new Dictionary<string, AppListItem>(StringComparer.Ordinal);
            if (current != null)
            {
                foreach (AppListItem item in current)
                {
                    if (item != null && !string.IsNullOrEmpty(item.Id)) { currentById[item.Id] = item; }
                }
            }
            var approvedById = new Dictionary<string, AppListItem>(StringComparer.Ordinal);
            foreach (AppListItem item in approved)
            {
                if (item != null && !string.IsNullOrEmpty(item.Id)) { approvedById[item.Id] = item; }
            }
            foreach (AppListItem target in targets)
            {
                if (target == null || string.IsNullOrEmpty(target.Id)) { return new ApprovalCheck(false, "unknown-app"); }
                if (!approvedById.TryGetValue(target.Id, out AppListItem bound))
                {
                    return new ApprovalCheck(false, "approval-mismatch");
                }
                if (bound.InstalledVersion != target.InstalledVersion ||
                    bound.LatestVersion != target.LatestVersion)
                {
                    return new ApprovalCheck(false, "approval-stale");
                }
                if (!currentById.TryGetValue(target.Id, out AppListItem live) ||
                    live.StatusKind != AppStatusKind.UpdateAvailable ||
                    live.InstalledVersion != target.InstalledVersion ||
                    live.LatestVersion != target.LatestVersion)
                {
                    return new ApprovalCheck(false, "approval-stale");
                }
            }
            return new ApprovalCheck(true, "approval-current");
        }
    }
}
