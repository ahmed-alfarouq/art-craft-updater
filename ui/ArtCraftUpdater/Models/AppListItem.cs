namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Update states for one application row. Mirrors the controller's status
    /// strings so mock rows can later be replaced by live data unchanged.
    /// </summary>
    public enum AppStatusKind
    {
        UpdateAvailable,
        UpToDate,
        Checking,
        Failed,
        Unknown
    }

    /// <summary>
    /// Plain presentation data for one application row. No UI dependencies;
    /// the future live integration binds these same fields to real data.
    /// </summary>
    public sealed class AppListItem
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Initial { get; set; }
        public string InstalledVersion { get; set; }
        public string LatestVersion { get; set; }
        public AppStatusKind StatusKind { get; set; }
        public string StatusText { get; set; }
    }
}
