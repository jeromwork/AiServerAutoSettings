using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed partial class TrayContext
    {
        string rollbackVersion = "", rollbackInstallMutex;
        bool rollbackLoading, rollbackBusy;
        bool RollbackAvailable()
        { return !closing && !firstSetup && !rollbackBusy && !updateChecking && offeredUpdate == null && !engine.Pending && UpdateOccupiedReason().Length == 0; }
        TrayMenuEntry RollbackEntry()
        { return MainScreenModel.Rollback(rollbackVersion, !RollbackAvailable()); }
        async void RefreshPreviousVersion()
        {
            if (closing || rollbackLoading || rollbackBusy) return;
            rollbackLoading = true;
            try { rollbackVersion = await Task.Run(() => {
                try { return UpgradeInstaller.PreviousVersion(home, engine); }
                catch (Exception) { return ""; }
            }); }
            finally { rollbackLoading = false; if (!closing) RefreshMenu(); }
        }
        // CLI with a live tray follows exactly the same confirmation/worker/restart path as the menu.
        async void RollbackPrevious()
        {
            if (!RollbackAvailable()) { if (!closing) MessageBox.Show("Откат недоступен: идёт другое обновление или действие. Повторите позже.", Product.Name); return; }
            rollbackBusy = busy = true;
            RefreshMenu();
            try {
                string version = await Task.Run(() => UpgradeInstaller.PreviousVersion(home, engine));
                bool blockCurrent;
                if (!ConfirmPreviousRollback(version, out blockCurrent)) return;
                await Task.Run(() => UpgradeInstaller.RollbackPrevious(home, engine, blockCurrent, version, rollbackInstallMutex));
                try { PrepareUpdateRestart(); }
                catch (Exception ex) { log.Write("update.rollback.restart-state.failed kind=" + ex.GetType().Name); }
                RestartRequested = true; ExitThread();
            } catch (Exception ex) {
                log.Write("update.rollback.manual.failed kind=" + ex.GetType().Name);
                if (!closing) MessageBox.Show("Откат не завершён: " + ex.Message, Product.Name);
                // A durable transaction must be resumed before starting components with a different image.
                if (File.Exists(UpgradeInstaller.ManualRollbackPath(home))) { RestartRequested = true; ExitThread(); }
            } finally {
                rollbackBusy = busy = false;
                if (!closing) { RefreshPreviousVersion(); RefreshMenu(); }
            }
        }
        internal static bool ConfirmPreviousRollback(string version, out bool blockCurrent)
        {
            using (var form = new Form { Text = "RemoteAgents — возврат версии", Width = 540, Height = 240,
                StartPosition = FormStartPosition.CenterScreen, MinimizeBox = false, MaximizeBox = false }) {
                var text = new Label { Dock = DockStyle.Top, Height = 80, Padding = new Padding(12),
                    Text = "Вернуть предыдущую версию (" + version + ")? Программа перезапустится.\r\nПомощник останется текущим; его откат требует отдельного шага с UAC." };
                var block = new CheckBox { Text = "Больше не ставить эту версию", Dock = DockStyle.Top, Height = 36, Padding = new Padding(12, 0, 0, 0) };
                var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 46, FlowDirection = FlowDirection.RightToLeft };
                var cancel = new Button { Text = "Отмена", AutoSize = true, DialogResult = DialogResult.Cancel };
                var restore = new Button { Text = "Вернуть версию", AutoSize = true, DialogResult = DialogResult.OK };
                buttons.Controls.Add(cancel); buttons.Controls.Add(restore);
                form.Controls.Add(block); form.Controls.Add(text); form.Controls.Add(buttons); form.CancelButton = cancel; form.AcceptButton = cancel;
                bool confirmed = form.ShowDialog() == DialogResult.OK;
                blockCurrent = confirmed && block.Checked; return confirmed;
            }
        }
    }
}
