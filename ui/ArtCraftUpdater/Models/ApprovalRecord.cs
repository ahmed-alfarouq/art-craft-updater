using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// UI-only record of a confirmed review. Confirm records approval only;
    /// installing happens separately through the install dialog and only
    /// after its own explicit confirmation, validated against this record.
    /// </summary>
    public sealed class ApprovalRecord
    {
        public ApprovalRecord(IEnumerable<AppListItem> items)
        {
            Applications = items.ToList();
            ApprovedAtUtc = DateTime.UtcNow;
        }

        public List<AppListItem> Applications { get; private set; }
        public DateTime ApprovedAtUtc { get; private set; }
    }
}
