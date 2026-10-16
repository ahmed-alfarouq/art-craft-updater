using System.Collections.Generic;
using System.Linq;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Testable selection model, separate from any visual row component.
    /// Tracks selected row ids and derives button enablement. No WPF types.
    /// </summary>
    public sealed class AppListState
    {
        private readonly HashSet<string> _selectedIds = new HashSet<string>();

        public IReadOnlyCollection<string> SelectedIds => _selectedIds;

        public void Toggle(string id)
        {
            if (string.IsNullOrEmpty(id)) { return; }
            if (!_selectedIds.Add(id)) { _selectedIds.Remove(id); }
        }

        public void Clear()
        {
            _selectedIds.Clear();
        }

        public bool HasSelection => _selectedIds.Count > 0;

        public bool HasUpdates(IEnumerable<AppListItem> items)
        {
            if (items == null) { return false; }
            return items.Any(i => i.StatusKind == AppStatusKind.UpdateAvailable);
        }

        public bool CanUpdateSelected(IEnumerable<AppListItem> items, bool globallyDisabled)
        {
            if (globallyDisabled) { return false; }
            return HasSelection;
        }

        public bool CanUpdateAll(IEnumerable<AppListItem> items, bool globallyDisabled)
        {
            if (globallyDisabled) { return false; }
            return HasUpdates(items);
        }
    }
}
