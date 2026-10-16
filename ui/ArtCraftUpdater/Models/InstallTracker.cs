using System;
using System.Collections.Generic;

namespace ArtCraftUpdater.Wpf
{
    /// <summary>
    /// Guards against duplicate or overlapping installs. The engine runs one
    /// blocking operation per bridge process, so the UI additionally refuses
    /// to start an install for an application that already has one in flight
    /// and runs approved applications strictly sequentially. No I/O, no UI.
    /// </summary>
    public sealed class InstallTracker
    {
        private readonly object _gate = new object();
        private readonly HashSet<string> _active = new HashSet<string>(StringComparer.Ordinal);

        public bool TryBegin(string appId)
        {
            if (string.IsNullOrEmpty(appId)) { return false; }
            lock (_gate)
            {
                if (_active.Contains(appId)) { return false; }
                _active.Add(appId);
                return true;
            }
        }

        public void End(string appId)
        {
            if (string.IsNullOrEmpty(appId)) { return; }
            lock (_gate)
            {
                _active.Remove(appId);
            }
        }

        public bool IsActive(string appId)
        {
            if (string.IsNullOrEmpty(appId)) { return false; }
            lock (_gate)
            {
                return _active.Contains(appId);
            }
        }

        public bool AnyActive
        {
            get
            {
                lock (_gate)
                {
                    return _active.Count > 0;
                }
            }
        }
    }
}
