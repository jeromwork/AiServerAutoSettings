using System;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal enum DiskExplorerKind { Local, ServerOnly, Pending, Syncing, Synced, Paused, Error, Offline, Unavailable }
    internal sealed class DiskExplorerFolder
    {
        internal string Name = "";
        internal bool Selected, ServerOnly;
    }
    // Presentation is deliberately a projection of the same REST observation used by the app.
    internal sealed class DiskExplorerPresentation
    {
        internal DiskExplorerKind Kind;
        internal string Tooltip;
        internal string Icon { get { return DiskExplorerService.Owner + "." + Kind + ".ico"; } }
        internal string[] MenuActions
        {
            get {
                if (Kind == DiskExplorerKind.ServerOnly) return new[] { "download" };
                if (Kind == DiskExplorerKind.Local) return new[] { "sync" };
                return new[] { "keep-server", "progress" };
            }
        }
        internal static DiskExplorerPresentation From(DiskSyncSnapshot snapshot, DiskSyncFolder folder, bool selected, bool placeholder)
        {
            if (!selected) return new DiskExplorerPresentation { Kind = placeholder ? DiskExplorerKind.ServerOnly : DiskExplorerKind.Local,
                Tooltip = placeholder ? "Только на сервере. Правый клик → Скачать на компьютер" : "Не синхронизируется. Правый клик → Добавить в Диск" };
            snapshot = snapshot ?? DiskSyncSnapshot.Unavailable("ожидаю ответ");
            var result = new DiskExplorerPresentation { Tooltip = DiskSyncStatus.Text(snapshot, folder), Kind = DiskExplorerKind.Pending };
            if (snapshot.Failure.Length > 0) result.Kind = DiskExplorerKind.Unavailable;
            else if (folder != null && (DiskSyncStatus.FirstError(folder).Length > 0 || Json.Str(folder.Status, "state") == "error" || Json.Str(folder.Status, "error").Length > 0 || DiskSyncStatus.Number(folder.Status, "errors", 0) > 0 || DiskSyncStatus.Number(folder.Status, "pullErrors", 0) > 0)) result.Kind = DiskExplorerKind.Error;
            else if (folder != null && (folder.Paused || Json.Str(folder.Status, "state") == "paused")) result.Kind = DiskExplorerKind.Paused;
            else if (!snapshot.Connected) result.Kind = DiskExplorerKind.Offline;
            else if (DiskSyncStatus.Complete(snapshot, folder)) result.Kind = DiskExplorerKind.Synced;
            else if (folder != null && folder.Shared && !folder.Pending && new[] { "syncing", "sync-preparing", "scanning", "scan-waiting", "sync-waiting", "idle", "cleaning", "clean-waiting" }.Contains(Json.Str(folder.Status, "state"))) result.Kind = DiskExplorerKind.Syncing;
            if (result.Kind == DiskExplorerKind.Synced) result.Tooltip = "На компьютере и на сервере";
            else if (result.Kind == DiskExplorerKind.Syncing) result.Tooltip = "Синхронизация " + result.Tooltip.TrimStart('⟳', ' ');
            return result;
        }
    }
}
