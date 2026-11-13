"""UI wiring contracts; live paint timing and Win32 job cleanup require Windows."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]


def source(name):
    return (ROOT / 'app/launcher' / name).read_text(encoding='utf-8-sig')


class FirstRunTests(unittest.TestCase):

    def test_first_run_skips_synchronous_bootstrap(self):
        tray = source('TrayContext.cs')
        constructor = tray.split('public TrayContext(', 1)[1].split('void RunFirstSetup()', 1)[0]
        self.assertIn('&& FirstInstall.Required(home)', constructor)
        self.assertIn('if (!firstSetup) { engine.Recover(); Bootstrap(); LoadComponents(); }', constructor)
        self.assertIn('if (firstSetup) { RunFirstSetup(); return; }', constructor)
        self.assertIn('Visible = !firstSetup', constructor)

    def test_downloaded_first_exe_defers_installation_too(self):
        program = source('Program.cs')
        first = program.split('if (install && home.Equals(DefaultHome', 1)[1].split('else if (install)', 1)[0]
        self.assertIn('FirstInstall.Required(home)', first)
        self.assertIn('firstInstallSource=Exe', first)
        self.assertNotIn('ExtractEmbedded', first)
        self.assertNotIn('UpgradeInstaller.Apply', first)
        self.assertIn('new TrayContext(home, log, name, sid, args, firstInstallSource)', program)
        self.assertIn('UpgradeInstaller.Apply(home,installSource', source('TrayContext.cs'))
        self.assertIn('current==version && File.Exists(target) && Files.Hash(target)==Files.Hash(installSource)', source('TrayContext.cs'))
        self.assertIn('bundle.bootstrap.resume', source('TrayContext.cs'))

    def test_preparation_starts_from_shown_and_gates_steps(self):
        wizard = source('SetupWizard.cs')
        self.assertIn('Shown+=async(a,b)=> {if(prepare!=null)await Prepare();', wizard)
        self.assertIn('steps.Enabled=pages.Enabled=back.Enabled=false;next.Enabled=!running', wizard)
        self.assertIn('if(bundle==null || polling', wizard)
        self.assertIn('bool manual=ConfigWindow.First(home,once);', source('TrayContext.cs'))
        self.assertIn('if(manual && !closing)SetupWizard.Display(home,null,true,prepare:once);', source('TrayContext.cs'))
        self.assertIn('if (prepare != null) preparing = prepare();', source('ConfigWindow.cs'))
        self.assertIn('worker=Task.Run(()=> {engine.Recover();Bootstrap();});await worker;', source('TrayContext.cs'))

    def test_preparation_failure_can_retry_or_close(self):
        wizard = source('SetupWizard.cs')
        preparation = wizard.split('void PreparationState(', 1)[1].split('void SelectPage(', 1)[0]
        self.assertIn('Подготавливаю программу…', preparation)
        self.assertIn('Ошибка подготовки', preparation)
        self.assertIn('next.Text="Повторить"', preparation)
        self.assertIn('if(preparing || closingRequested)return', preparation)
        self.assertIn('if(IsDisposed || closingRequested)return', preparation)
        self.assertNotIn('MessageBox', preparation)
        # The constructor parameter 'bundle' is always null for first setup; the click must read the field.
        self.assertIn('if(prepare!=null && this.bundle==null){await Prepare();return;}', wizard)
        self.assertIn('token, downgrade || accept || old.Length==0', source('UpgradeInstaller.cs'))

    def test_unfinished_close_exits_before_showing_tray(self):
        tray = source('TrayContext.cs')
        first = tray.split('void RunFirstSetup()', 1)[1].split('void Bootstrap()', 1)[0]
        self.assertLess(first.index('if(FirstInstall.Required(home)){ExitThread();return;}'), first.index('icon.Visible=true'))
        shutdown = tray.split('protected override void ExitThreadCore()', 1)[1]
        self.assertIn('stop.Cancel()', shutdown)
        self.assertIn('foreach (var r in runtimes) r.Dispose()', shutdown)
        self.assertIn('icon.Dispose()', shutdown)
        self.assertIn('StopManagedComponents()', shutdown)
        self.assertIn('Stop-ManagedControl $Root', tray)

    def test_secondary_launch_activates_first_wizard(self):
        tray = source('TrayContext.cs')
        handle = tray.split('void Handle(string[] args)', 1)[1].split('void Safe(', 1)[0]
        gate = handle.index('if(firstSetup && !icon.Visible)')
        self.assertIn('ActivateWindow(form)', handle[gate:])
        self.assertLess(gate, handle.index('case WindowCommand.Restart:'))
        self.assertLess(handle.index('args.Contains("--exit")'), gate)
        self.assertIn('f is SetupWizard || f is ConfigWindow', handle[gate:])

    def test_hand_start_routes_to_main_window_and_transfers_foreground(self):
        program = source('Program.cs')
        self.assertIn('bool interactive = WindowModel.ShouldShow(args);', program)
        self.assertNotIn('StartWindow.Confirm()', program)
        self.assertIn('WindowModel.ForwardArguments(args)', program)
        self.assertIn('AllowSetForegroundWindow((uint)pid)', program)
        self.assertIn('(started ? " --started" : "")', program)
        tray = source('TrayContext.cs')
        self.assertIn('case WindowCommand.Show: ShowMain();', tray)
        self.assertIn('form.BringToFront(); form.Activate(); SetForegroundWindow(form.Handle)', tray)

    def test_main_window_and_minimal_tray_are_wired_to_existing_views(self):
        tray = source('TrayContext.cs')
        menu = tray.split('void RefreshMenu()', 1)[1].split('bool Configured()', 1)[0]
        self.assertIn('foreach (var entry in TrayEntries())', menu)
        self.assertIn('TrayMenuModel.Build(config.Data, AccountState()', menu)
        self.assertIn('if (id == "settings") ShowMain()', menu)
        self.assertIn('if (id == "cloud") OpenDisk()', menu)
        self.assertIn('OpenHappier();', menu)
        self.assertIn('TrayMenuModel.HappierUrl(config.Data, AccountState())', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('UseShellExecute = true', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('if (id == "exit") RequestExit()', menu)
        main = source('ConfigWindow.Main.cs')
        for name in ['Конфиг', 'Подробно', 'Сервис']:
            self.assertIn(name, source('ConfigWindow.cs') + main)
        self.assertIn('new SetupWizard(home, bundle, false, false)', main)
        self.assertIn('mainWindow && !allowUnload', source('ConfigWindow.cs'))
        self.assertNotIn('icon.MouseDoubleClick +=', tray)
        self.assertIn('TrayMenuModel.AcceptLeftClick(e.Clicks', tray)

    def test_background_checks_never_acquire_the_ui_action_lock(self):
        tray = source('TrayContext.cs')
        sync = tray.split('async void CheckSync()', 1)[1].split('void WriteStatus()', 1)[0]
        self.assertNotIn('actionBusy=true', sync)
        self.assertNotIn('actionBusy = true', sync)
        self.assertIn('syncSchedule.Due(', sync)
        self.assertIn('config.sync.unavailable ', sync)
        main = source('ConfigWindow.Main.cs')
        self.assertIn('WindowModel.CanOpen(page.Text, operation)', main)
        inspect = source('SetupWizard.cs').split('async Task Inspect()', 1)[1].split('async Task<bool> Guard(', 1)[0]
        self.assertNotIn('await Guard(', inspect)
        self.assertNotIn('.Enabled=false', inspect)

    def test_legacy_sync_is_retired_before_timer_and_again_on_exit(self):
        tray = source('TrayContext.cs')
        tick = tray.split('void Tick()', 1)[1].split('async void CheckOperations()', 1)[0]
        self.assertIn('RetireConfigSyncTask();', tick)
        sync = tray.split('async void CheckSync()', 1)[1].split('async void CheckServerHealth()', 1)[0]
        self.assertIn('!syncTaskRetired || syncRunning', sync)
        retire = tray.split('async void RetireConfigSyncTask()', 1)[1].split('async void CheckSync()', 1)[0]
        self.assertLess(retire.index('"RetireConfigSync"'), retire.index('syncTaskRetired = true'))
        self.assertIn('nextSyncTaskRetirement = DateTime.UtcNow.AddSeconds(30)', retire)
        shutdown = tray.split('void StopManagedComponents()', 1)[1]
        self.assertIn('Remove-LegacyConfigSyncTask $Root', shutdown)
        common = (ROOT / 'build/Wizard.Common.ps1').read_text(encoding='utf-8-sig')
        self.assertNotIn('Install-WizardConfigSync', common)
        self.assertIn('Remove-LegacyConfigSyncTask $Root', common.split("'Server' {", 1)[1].split("'Lan' {", 1)[0])








    def test_active_selection_owns_stop_status_and_local_path(self):
        main = source('ConfigWindow.Main.cs')
        self.assertIn('journal.Dock = DockStyle.Bottom;', main.split('void BuildMain()', 1)[1].split('configPage.Controls.Add(journal)', 1)[0])

    def test_pending_account_survives_rejected_or_failed_guard(self):
        wizard = source('SetupWizard.cs')
        guard = wizard.split('async Task<bool> Guard(', 1)[1].split('async Task<Dictionary', 1)[0]
        self.assertIn('lastSuccess = false;', guard)
        self.assertIn('Append(conflict); return false;', guard)
        self.assertIn('return lastSuccess;', guard)
        poll = wizard.split('async Task PollOperations(', 1)[1].split('void ShowInstall()', 1)[0]
        self.assertIn('if(!pendingAccount)resumeAccount=false;', poll)
        resume = poll.split('if(!busy && !closingRequested && resumeAccount)', 1)[1].split('if(!busy && !closingRequested && retryConnection)', 1)[0]
        self.assertEqual(resume.count('resumeAccount=false'), 1)
        self.assertIn('if(await Guard(', resume)
        self.assertIn('connected=ApplyResult(2,r) && Json.Bool(r,"ok")', resume)
        self.assertIn('},2) && connected) resumeAccount=false', resume)

    def test_bundle_switch_rebinds_editor_wizard_and_cached_sessions(self):
        load = source('TrayContext.cs').split('void LoadComponents()', 1)[1].split('bool Wanted(', 1)[0]
        self.assertIn('mainWindow.RebindBundle(engine.Folder(engine.Current))', load)
        rebind = source('ConfigWindow.Main.cs').split('internal void RebindBundle(', 1)[1].split('void BuildMain()', 1)[0]
        for statement in ['bundle = current;', 'session.RebindBundle(current)', 'followingSession.RebindBundle(current)', 'detailsWindow.RebindBundle(current)']:
            self.assertIn(statement, rebind)
        for destructive in ['RefreshConfigText', 'Initialize(', 'Dispose(', 'new SetupWizard', 'new ConfigSession']:
            self.assertNotIn(destructive, rebind, 'must preserve unsaved editor, folder and wizard values')
        for name in ['ConfigApply.cs', 'SetupWizard.Main.cs']:
            self.assertIn('internal void RebindBundle(string current) { bundle = current; }', source(name))

    def test_invitations_removed(self):
        for name in ['Program.cs', 'TrayContext.cs', 'SetupWizard.cs', 'EntryPoint.cs', 'UpgradeInstaller.cs', 'Data.cs']:
            text = source(name)
            for word in ['Invitation', 'InviteWindow', 'InviteHop', 'HopRelay', 'RefreshPackage', 'rainvite', 'invite-hop']:
                self.assertNotIn(word, text, name + ': ' + word)


if __name__ == '__main__':
    unittest.main()
