"""UI wiring contracts; live paint timing and Win32 job cleanup require Windows."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]


def source(name):
    return (ROOT / 'app/launcher' / name).read_text(encoding='utf-8-sig')


class FirstRunTests(unittest.TestCase):
    def test_detailed_disk_uses_profile_request_and_current_ui_paths(self):
        wizard = source('SetupWizard.cs')
        disk = wizard.split('case 2:', 1)[1].split('case 3:', 1)[0]
        self.assertIn('ConfigRequests.Disk(ConfigProfile.Load(home)', disk)
        for field in ('base', 'reconnect'):
            self.assertIn('diskRequest["' + field + '"]', disk)
        self.assertIn('Run("Disk",diskRequest)', disk)
        # No folder tree any more: the folders to accept come only from the profile's disk.folders (inside the request).
        for gone in ('paths', 'folders.', 'LoadTree', 'directions', 'external'):
            self.assertNotIn(gone, disk)

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
        self.assertIn('Stop-ManagedDisk $disk', tray)

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
        # «Открыть» and the left click lead to Happier; «Настройки» is the program window; «Диск» is the Disk root.
        self.assertIn('if (id == "open") OpenHappier()', menu)
        self.assertIn('else if (id == "settings") ShowMain()', menu)
        self.assertIn('else if (id == "disk") OpenDisk()', menu)
        for gone in ('"folders"', '"progress"', 'ShowDiskProgress'):
            self.assertNotIn(gone, tray)
        self.assertIn('TrayMenuModel.HappierUrl(config.Data, AccountState())', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('UseShellExecute = true', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('else if (id == "exit") RequestExit()', menu)
        main = source('ConfigWindow.Main.cs')
        for name in ['Конфиг', 'Подробно', 'Сервис']:
            self.assertIn(name, source('ConfigWindow.cs') + main)
        self.assertNotIn('"Папки"', source('ConfigWindow.cs') + main + source('WindowModel.cs'))
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

    def test_disk_runs_in_background_and_outlives_the_window(self):
        window = source('ConfigWindow.cs')
        run = window.split('async Task RunSession(', 1)[1].split('void FollowSession()', 1)[0]
        self.assertIn('diskQueued = plan.Remove(ConfigSections.Disk);', run)
        self.assertIn('StartQueuedDisk();', window.split('void Report(', 1)[1].split('void SetBusy(', 1)[0])
        apply = source('ConfigApply.cs')
        follow = apply.split('internal async Task FollowPending(', 1)[1].split('internal async Task<SectionOutcome> ApplyDisk(', 1)[0]
        self.assertIn('o.Key != ConfigSections.Disk', follow)
        disk = apply.split('internal async Task<SectionOutcome> ApplyDisk(', 1)[1].split('internal async Task<SectionOutcome> Activate(', 1)[0]
        self.assertIn('"Operation"', disk)
        self.assertIn('DiskApplyWait.Run(DiskCurrent', disk)
        self.assertIn('if (state == "finished") { outcome = await execute(); continue; }', apply)
        tray = source('TrayContext.cs')
        self.assertIn('BackgroundWork.Disk.Stop();', tray.split('protected override void ExitThreadCore()', 1)[1])
        self.assertIn('BackgroundWork.Disk.Changed +=', tray)
        self.assertIn('BackgroundWork.Disk.Changed -= diskChanged', window)
        # RemoteVPN has no Disk; for RemoteAgents the install leaves the plan instead of holding the other sections.
        self.assertIn('if (Product.IsVpn) plan.Remove(ConfigSections.Disk);', run)
        start = window.split('void StartDisk()', 1)[1].split('async Task RetrySection(', 1)[0]
        self.assertIn('BackgroundWork.Disk.Start(', start)
        self.assertIn('current.ApplyDisk(token)', start)
        self.assertNotIn('cancel.Token', start, 'the Disk run must outlive the window')
        retry = window.split('async Task RetrySection(', 1)[1].split('async Task Finish()', 1)[0]
        self.assertIn('if (section == ConfigSections.Disk) { StartDisk(); return; }', retry)

    def test_disk_completion_is_bound_to_its_server_and_choice(self):
        window = source('ConfigWindow.cs')
        start = window.split('void StartDisk()', 1)[1].split('async Task RetrySection(', 1)[0]
        self.assertIn('var current = new ConfigSession(home, Bundle)', start)
        self.assertIn('current.DiskCurrent = () => binding == DiskApplyWait.Binding(ConfigProfile.Load(home))', start)
        self.assertIn('Binding = binding', start)
        self.assertIn('=> Ui(() => { if (current.DiskCurrent()) Report(', start)
        changed = window.split('void OnDiskChanged()', 1)[1].split('void StartQueuedDisk()', 1)[0]
        # A result of an older server/config is ignored: only the current binding reports (and logs) a failure.
        self.assertLess(changed.index('last.Binding != DiskApplyWait.Binding'), changed.index('Log("Диск не подключён: "'))
        run = source('ConfigApply.cs').split('SectionOutcome RunSection(', 1)[1].split('SectionOutcome Server(', 1)[0]
        self.assertEqual(run.count('s == ConfigSections.Disk && !DiskCurrent()'), 2)
        self.assertLess(run.rindex('s == ConfigSections.Disk && !DiskCurrent()'), run.index('ConfigProfile.MarkApplied'))

    def test_wheel_layout_and_window_order(self):
        window = source('ConfigWindow.cs')
        self.assertIn('class WheelRouter : IMessageFilter', window)
        self.assertIn('Application.AddMessageFilter(wheel)', window)
        self.assertIn('Application.RemoveMessageFilter(wheel)', window)
        self.assertIn('WindowFromPoint', window)
        self.assertNotIn('TopMost', window)
        rows = window.split('void LayoutRows()', 1)[1].split('void Ui(', 1)[0]
        self.assertIn('new RowStyle(SizeType.Percent, 100)', rows)
        self.assertIn('SizeType.Absolute, journal.Visible ? JournalHeight : 0', rows)
        # Status rows, journal and the footer with «Готово»: three rows, no folder pane any more.
        self.assertIn('windowLayout.Controls.Add(journal, 0, 1)', window)
        self.assertIn('windowLayout.Controls.Add(bottom, 0, 2)', window)
        self.assertIn('AutoScroll = true', window)
        self.assertIn('Resize += (a, b) => LayoutRows();', window)
        main = source('ConfigWindow.Main.cs')
        self.assertIn('journal.Dock = DockStyle.Bottom;', main.split('void BuildMain()', 1)[1].split('configPage.Controls.Add(journal)', 1)[0])

    def test_window_mutation_guard_and_exit_confirmation(self):
        window = source('ConfigWindow.cs')
        guard = window.split('async Task Guard(', 1)[1].split('async Task StartFromText', 1)[0]
        self.assertLess(guard.index('MutationConflict()'), guard.index('SetBusy(true)'))
        self.assertLess(guard.index('SetBusy(true)'), guard.index('await action()'))
        self.assertIn('running = value;', window)
        exit_ = source('TrayContext.cs').split('void RequestExit()', 1)[1]
        self.assertIn('((ConfigWindow)f).IsApplying', exit_)
        # A running Disk install also asks before the tray exits: exit cancels it.
        self.assertIn('BackgroundWork.Disk.Busy', exit_.split('MessageBox', 1)[0])
        self.assertIn('WindowModel.CanFinish(', window)

    def test_folder_ui_and_explorer_integration_are_gone(self):
        # Syncthing Tray is the only folder interface: no folder window, tree, Explorer menu/icons or status polling remain.
        launcher = ROOT / 'app/launcher'
        for name in ['DiskFoldersView', 'DiskFoldersModel', 'DiskFolderTree', 'DiskTreeSelection', 'LocalFolderBrowser', 'LocalFolders',
                     'DiskExplorerController', 'DiskExplorerMetadata', 'DiskExplorerNative', 'DiskExplorerObservation', 'DiskExplorerPresentation',
                     'DiskExplorerRegistry', 'DiskShellCommands', 'DiskShellModel', 'DiskProgressWindow', 'DiskEvictionSafety', 'DiskSyncMonitor', 'DiskSyncStatus']:
            self.assertFalse((launcher / (name + '.cs')).exists(), name)
        everything = '\n'.join(path.read_text(encoding='utf-8-sig') for path in sorted(launcher.glob('*.cs')))
        for word in ['DiskExplorer', 'DiskFolders', 'DiskSyncStatus', 'DiskFolderTree', 'DiskShell', 'disk-shell', 'ShowDiskProgress',
                     'InitializeFolders', 'ApplyFolders', 'FoldersRecommendation', 'SessionPlan']:
            self.assertNotIn(word, everything, word)

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
        self.assertIn('connected=ApplyResult(3,r) && Json.Bool(r,"ok")', resume)
        self.assertIn('},3) && connected) resumeAccount=false', resume)

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
