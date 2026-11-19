"""UI wiring contracts; live paint timing and Win32 job cleanup require Windows."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]


def source(name):
    return (ROOT / 'app/launcher' / name).read_text(encoding='utf-8-sig')


class FirstRunTests(unittest.TestCase):
    def test_bridge_page_defaults_on_without_a_separate_question(self):
        page = source('SetupWizard.cs').split('void BridgePage(', 1)[1].split('void VpnPage(', 1)[0]
        self.assertIn('Check(4,"Включить мост",95,Json.Bool(c,"enabled",true))', page)
        self.assertIn('Check(4,"Разрешить выполнение команд (shell)",135,Json.Bool(c,"allowShell",true))', page)
        self.assertNotIn('controlOn', page)
        self.assertNotIn('c.Count', page)
        self.assertNotIn('?', page)

    def test_detailed_disk_uses_profile_request_and_current_ui_paths(self):
        wizard = source('SetupWizard.cs')
        disk = wizard.split('case 2:', 1)[1].split('case 3:', 1)[0]
        self.assertIn('ConfigRequests.Disk(ConfigProfile.Load(home)', disk)
        self.assertIn('diskBase.Text.Trim(),reconnectDisk)', disk)
        self.assertIn('diskRequest["base"]=diskBase.Text.Trim()', disk)
        self.assertNotIn('diskRequest["reconnect"]', disk, 'reconnect safety belongs to the shared request builder')
        self.assertIn('Run("Disk",diskRequest)', disk)
        # No folder tree any more: the folders to accept come only from the profile's disk.folders (inside the request).
        for gone in ('paths', 'folders.', 'LoadTree', 'directions', 'external'):
            self.assertNotIn(gone, disk)

    def test_legacy_cleanup_checks_markers_after_confirming_installed_home(self):
        start = source('TrayContext.cs').split('void StartLegacyDiskCleanup()', 1)[1].split('void OpenDisk()', 1)[0]
        self.assertIn('LegacyDiskCleanup.Required(home)', start)
        self.assertNotIn('LegacyDiskCleanup.Done(home)', start)
        self.assertLess(start.index('Program.DefaultHome'), start.index('LegacyDiskCleanup.Required(home)'))
        self.assertIn('new DiskExplorerController(', start)
        controller = source('DiskExplorerController.cs')
        self.assertLess(controller.index('!cleanup()'), controller.index('initialized.TrySetResult'))

    def test_first_run_skips_synchronous_bootstrap(self):
        tray = source('TrayContext.cs')
        constructor = tray.split('public TrayContext(', 1)[1].split('void RunFirstSetup()', 1)[0]
        self.assertIn('&& FirstInstall.Required(home)', constructor)
        self.assertIn('if (!firstSetup) { engine.Recover(); Bootstrap(); LoadComponents();', constructor)
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
        self.assertIn('bool preserveVpn = RestartRequested && keepVpnOnRestart', shutdown)
        self.assertIn('foreach (var r in runtimes) r.Dispose(preserveVpn)', shutdown)
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
        self.assertIn('menuState.Refresh(TrayEntries()', menu)
        self.assertIn('foreach (var entry in entries)', menu)
        self.assertIn('TrayMenuModel.Build(config.Data, AccountState()', menu)
        # «Открыть» and the left click lead to Happier; «Настройки» is the program window; «Диск» is the Disk root.
        self.assertIn('if (id == "open") OpenHappier()', menu)
        self.assertIn('else if (id == "settings") ShowMain()', menu)
        self.assertIn('else if (id == "disk") OpenDisk()', menu)
        for gone in ('"folders"', '"progress"', 'ShowDiskProgress'):
            self.assertNotIn(gone, tray)
        self.assertIn('TrayMenuModel.HappierUrl(config.Data, AccountState(), home)', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('UseShellExecute = true', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('else if (id == "exit") RequestExit()', menu)
        main = source('ConfigWindow.Main.cs')
        pages = source('MainWindow.Settings.cs')
        for name in ['Главная', 'Настройки', 'Редактор конфига', 'Диагностика', 'Раздел настроек']:
            self.assertIn(name, pages)
        self.assertNotIn('TabControl', source('ConfigWindow.cs') + main + pages)
        self.assertNotIn('"Папки"', source('ConfigWindow.cs') + main + source('WindowModel.cs'))
        self.assertIn('new SetupWizard(home, bundle, false, false)', main)
        self.assertIn('mainWindow && !allowUnload', source('ConfigWindow.cs'))
        self.assertNotIn('icon.MouseDoubleClick +=', tray)
        self.assertIn('TrayMenuModel.AcceptLeftClick(e.Clicks', tray)

    def test_main_cards_use_model_and_keep_existing_action_boundaries(self):
        main = source('ConfigWindow.Main.cs')
        cards = source('MainWindow.Cards.cs')
        tray = source('TrayContext.cs')
        update = main.split('internal void UpdateMain(', 1)[1].split('void AddPath(', 1)[0]
        self.assertIn('MainScreenModel.Build(facts)', update)
        self.assertIn('RenderCards(view, facts)', update)
        self.assertIn('Clipboard.SetText(MainScreenModel.Report(screenFacts, screenTechnical))', main)
        self.assertNotIn('NotImplementedException', main + cards)
        self.assertNotIn('StatusView.Line(', cards)
        self.assertIn('VpnRequested(!vpnOn)', cards)
        self.assertIn('if (enabled) CheckVpn(vpn, true); else DisableVpn(vpn, true);', tray)
        self.assertIn('pathSelection.Choose(tag); if (choosePath != null) choosePath(tag)', main)
        self.assertIn('ScriptCommand("Set-TransportPath.ps1"', tray)
        for action in ['open-sync', 'open-disk', 'retry']:
            self.assertIn('action == "' + action + '"', tray)
        self.assertIn('if (action == "vpn-on")', cards)
        self.assertIn('mainBanner.DetailsClicked += (s, e) => OpenDiagnostics()', cards)
        self.assertIn('if (action == "details") { OpenDiagnostics(); return; }', cards)

    def test_main_facts_are_fresh_and_vpn_failures_stay_in_banner_for_card(self):
        tray = source('TrayContext.cs')
        facts = tray.split('void RefreshMain()', 1)[1].split('string TransportScript(', 1)[0]
        for call in ['StatusView.Read(home, "transport", maxAgeSec: 15)',
                     'VpnStatus.Read(home)',
                     'StatusView.Read(home, "control", maxAgeSec: 30)', 'ServerHealthView.Read(home)']:
            self.assertIn(call, facts)
        for member in ['VpnInstalled', 'VpnWanted', 'VpnBusy', 'VpnError', 'Operation', 'DiskEnabled',
                       'DiskSummary', 'DiskFolders', 'DiskServerOnly', 'HappierConfirmed', 'HappierUrl']:
            self.assertIn(member + ' =', facts)
        self.assertIn('session.FolderCount', tray)
        failure = tray.split('void VpnFailure(', 1)[1].split('async void DisableVpn(', 1)[0]
        self.assertIn('vpnError = message;', failure)
        self.assertIn('if (!fromCard && !closing) MessageBox.Show', failure)
        vpn = tray.split('async void CheckVpn(', 1)[1].split('internal static bool VpnConflictDialog', 1)[0]
        self.assertEqual(vpn.count('finally { actionBusy = vpnActionBusy = false;'), 2)
        self.assertNotIn('.Message', vpn)

    def test_background_checks_never_acquire_the_ui_action_lock(self):
        tray = source('TrayContext.cs')
        sync = tray.split('async void CheckSync()', 1)[1].split('void WriteStatus()', 1)[0]
        self.assertNotIn('actionBusy=true', sync)
        self.assertNotIn('actionBusy = true', sync)
        self.assertIn('syncSchedule.Due(', sync)
        self.assertIn('config.sync.unavailable ', sync)
        main = source('ConfigWindow.Main.cs')
        self.assertIn('WindowModel.CanOpen(name, operation)', source('MainWindow.Settings.cs'))
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
        self.assertIn('DiskApplyWait.Run(DiskStillCurrent', disk)
        self.assertIn('if (state == "finished") { outcome = await execute(); continue; }', apply)
        tray = source('TrayContext.cs')
        self.assertIn('BackgroundWork.Disk.Stop();', tray.split('protected override void ExitThreadCore()', 1)[1])
        self.assertIn('BackgroundWork.Disk.Changed +=', tray)
        self.assertIn('BackgroundWork.Disk.Changed -= diskChanged', window)
        # Disk scheduling no longer depends on the removed VPN product.
        self.assertNotIn('Product.IsVpn', window)
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
        self.assertIn('current.DiskCurrent = () => DiskApplyWait.Current(binding, ConfigProfile.Load(home))', start)
        self.assertIn('!ConfigSections.DiskDescribed(ConfigProfile.Load(home))', start)
        self.assertIn('Binding = binding', start)
        self.assertIn('=> Ui(() => { if (current.DiskCurrent()) Report(', start)
        changed = window.split('void OnDiskChanged()', 1)[1].split('void StartQueuedDisk()', 1)[0]
        # A result of an older server/config is ignored: only the current binding reports (and logs) a failure.
        self.assertLess(changed.index('!DiskApplyWait.Current(last.Binding,'), changed.index('Log("Диск не подключён: "'))
        run = source('ConfigApply.cs').split('SectionOutcome RunSection(', 1)[1].split('SectionOutcome Server(', 1)[0]
        self.assertEqual(run.count('s == ConfigSections.Disk && !DiskStillCurrent()'), 2)
        self.assertLess(run.rindex('s == ConfigSections.Disk && !DiskStillCurrent()'), run.index('ConfigProfile.MarkApplied'))
        apply = source('ConfigApply.cs')
        self.assertIn('bool DiskStillCurrent() { return DiskCurrent() && ConfigSections.DiskDescribed(ConfigProfile.Load(home)); }', apply)
        tray = source('TrayContext.cs').split('void DiskFinished()', 1)[1].split('void RequestExit()', 1)[0]
        self.assertLess(tray.index('!DiskApplyWait.Current(last.Binding,'), tray.index('icon.ShowBalloonTip'))

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
        editor = source('MainWindow.Settings.cs').split('var editor = new TableLayoutPanel', 1)[1].split('RegisterPage("Редактор конфига", editor)', 1)[0]
        self.assertIn('editor.Controls.Add(configPage, 0, 1)', editor)
        self.assertIn('journal.Dock = DockStyle.Fill; editor.Controls.Add(journal, 0, 2)', editor)
        self.assertIn('RowStyle(SizeType.Absolute, Font.Height * 6)', editor)
        self.assertIn('rowsHost.Controls.Add(rowsPanel)', editor)

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

    def test_old_folder_window_is_gone_and_explorer_is_local(self):
        # Explorer integration is restored over local REST; the removed folder tree / SSH monitor stay removed.
        disk = 'Disk'
        removed = [disk + x for x in ('FoldersView', 'FoldersModel', 'FolderTree', 'TreeSelection', 'SyncMonitor', 'SyncStatus', 'ProgressWindow',
                                      'EvictionSafety', 'ExplorerObservation', 'ExplorerPresentation')] + ['LocalFolder' + 'Browser', 'Local' + 'Folders']
        launcher = ROOT / 'app/launcher'
        for name in removed:
            self.assertFalse((launcher / (name + '.cs')).exists(), name)
        everything = '\n'.join(path.read_text(encoding='utf-8-sig') for path in sorted(launcher.glob('*.cs')))
        # DiskFolders is now read-only MainScreenFacts metadata, not a restored folder browser.
        for word in ['class ' + disk + 'Folders', disk + 'SyncStatus', disk + 'FolderTree',
                     'Show' + disk + 'Progress', 'Initialize' + 'Folders', 'Apply' + 'Folders', 'Folders' + 'Recommendation', 'Session' + 'Plan']:
            self.assertNotIn(word, everything, word)
        for name in ['DiskShellCommands.cs', 'DiskSyncthingClient.cs', 'DiskExplorerController.cs']:
            code = source(name)
            for forbidden in ['Process.Start', 'External.Run', 'ssh.exe', 'powershell.exe', 'Invoke-DiskServer']:
                self.assertNotIn(forbidden, code)
        self.assertIn('DiskShellRequest.Parse(args)', source('Program.cs'))
        self.assertIn('diskExplorer.Submit(diskShell)', source('TrayContext.cs'))

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
