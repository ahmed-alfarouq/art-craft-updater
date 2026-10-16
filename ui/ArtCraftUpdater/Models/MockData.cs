using System.Collections.Generic;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Clearly-marked MOCK data for Phase 2B presentation work only.
    /// Covers all four required states. Never touches live application data.
    /// </summary>
    public static class MockData
    {
        public static List<AppListItem> GetApps()
        {
            return new List<AppListItem>
            {
                new AppListItem
                {
                    Id = "photocraft",
                    Name = "PhotoCraft",
                    Initial = "P",
                    InstalledVersion = "0.9.0",
                    LatestVersion = "0.9.1",
                    StatusKind = AppStatusKind.UpdateAvailable,
                    StatusText = "Update available"
                },
                new AppListItem
                {
                    Id = "filmcraft",
                    Name = "FilmCraft",
                    Initial = "F",
                    InstalledVersion = "0.8.0",
                    LatestVersion = "0.8.0",
                    StatusKind = AppStatusKind.UpToDate,
                    StatusText = "Up to date"
                },
                new AppListItem
                {
                    Id = "effectcraft",
                    Name = "EffectCraft",
                    Initial = "E",
                    InstalledVersion = "0.10.0",
                    LatestVersion = "-",
                    StatusKind = AppStatusKind.Checking,
                    StatusText = "Checking for updates..."
                },
                new AppListItem
                {
                    Id = "vectorcraft",
                    Name = "VectorCraft",
                    Initial = "V",
                    InstalledVersion = "-",
                    LatestVersion = "-",
                    StatusKind = AppStatusKind.Failed,
                    StatusText = "Check failed"
                }
            };
        }
    }
}
