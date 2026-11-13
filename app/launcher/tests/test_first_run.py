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
        for field in ('base', 'paths', 'reconnect'):
            self.assertIn('diskRequest["' + field + '"]', disk)
        self.assertIn('Run("Disk",diskRequest)', disk)

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
        self.assertIn('if (id == "open") ShowMain()', menu)
        self.assertIn('if (id == "folders") ShowMain(true)', menu)
        self.assertIn('OpenHappier();', menu)
        self.assertIn('TrayMenuModel.HappierUrl(config.Data, AccountState())', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('UseShellExecute = true', tray.split('void OpenHappier()', 1)[1].split('void RefreshMenu()', 1)[0])
        self.assertIn('if (id == "exit") RequestExit()', menu)
        main = source('ConfigWindow.Main.cs')
        for name in ['Папки', 'Конфиг', 'Подробно', 'Сервис']:
            self.assertIn(name, source('ConfigWindow.cs') + main)
        self.assertIn('new SetupWizard(home, bundle, false, false)', main)
        self.assertIn('new DiskFoldersView(', source('ConfigWindow.cs'))
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

    def test_folder_hosts_share_checkbox_tree_and_apply_status(self):
        window = source('ConfigWindow.cs')
        self.assertEqual(window.count('new DiskFoldersView('), 1)
        self.assertIn('foldersPanel.Controls.Add(folders)', window)
        self.assertIn('foldersTab.Controls.Add(folders)', window)
        self.assertIn('else if (id == "folders") ShowMain(true)', source('TrayContext.cs'))
        self.assertIn('if (folders) mainWindow.OpenFolders()', source('TrayContext.cs'))
        self.assertIn('tabs.TabPages.Add(foldersPage)', source('ConfigWindow.Main.cs'))
        view = source('DiskFoldersView.cs')
        self.assertIn('Все папки сервера, включая новые', view)
        self.assertNotIn('RadioButton', view)
        self.assertNotIn('ListView', view)
        self.assertIn('TreeViewDrawMode.OwnerDrawText', source('DiskFolderTree.cs'))
        self.assertIn('new TreeNode("С этого компьютера")', source('DiskFolderTree.cs'))
        self.assertIn('TextFormatFlags.EndEllipsis', source('DiskFolderTree.cs'))
        self.assertIn('Model.CanRevert(top)', view)
        self.assertIn('skip.Visible = allowSkip', view)
        self.assertIn('Text = "На этом компьютере"', view)
        self.assertIn('Text = "На сервере"', view)
        self.assertIn('localPath.LinkClicked', view)
        self.assertIn('WireDrag(current)', view)
        self.assertIn('pane.Tree.DragDrop', view)
        self.assertIn('Model.TakeToComputer(data.Path)', view)
        self.assertIn('Model.SendToServer(data.Path)', view)
        self.assertIn('Model.StopSynchronizing(SelectedPath(activeFolders))', view)
        self.assertIn('new LinkLabel', view)
        self.assertIn('Button("Синхронизировать выбранные папки")', view)
        self.assertIn('await Apply()', view)
        self.assertIn('run("DiskNavPane",', view)
        self.assertIn('var nav = folders.RefreshNavPane();', window)
        # MarkApplied uses what the finished background run applied, not the live (possibly edited) model.
        changed = window.split('void OnDiskChanged()', 1)[1].split('void StartQueuedDisk()', 1)[0]
        self.assertIn('if (last.Ok)', changed)
        self.assertIn('folders.MarkApplied(last.Choice)', changed)
        self.assertNotIn('MarkApplied', window.split('void Report(', 1)[1].split('void SetBusy(', 1)[0])

    def test_folder_review_wiring_and_honest_removal_hint(self):
        view = source('DiskFoldersView.cs')
        self.assertIn('Снятие папки останавливает синхронизацию; файлы на компьютере остаются, их можно удалить вручную.', view)
        self.assertNotIn('не занимают место здесь', view)
        tree = source('DiskFolderTree.cs')
        self.assertIn('Model.ExternalFor(SelectedPath)', tree.split('internal DiskExternalChoice SelectedExternal', 1)[1].split('internal string SelectedStatus', 1)[0])
        window = source('ConfigWindow.cs')
        initialize = window.split('folders.Initialize(', 1)[1].split('foldersInitialized = true', 1)[0]
        self.assertIn('ConfigProfile.AppliedDiskChoice(home, profile)', initialize)
        self.assertIn('ConfigProfile.DiskExclusions(', initialize)
        self.assertIn('Model.MarkApplied(ConfigProfile.DiskExclusions(), applied)', view)

    def test_disk_revert_uses_mutation_guard_and_counts_as_applying(self):
        window = source('ConfigWindow.cs')
        self.assertIn('RunFolderAction, ReadFolders, GuardFolders, () => diskApplying || folderActionRunning', window)
        view = source('DiskFoldersView.cs')
        revert = view.split('async Task Revert()', 1)[1]
        self.assertLess(revert.index('await mutate('), revert.index('run("DiskRevert"'))
        self.assertIn('path }), read, isBusy, log)', view)
        guard = window.split('async Task Guard(', 1)[1].split('async Task StartFromText', 1)[0]
        self.assertLess(guard.index('MutationConflict()'), guard.index('SetBusy(true)'))
        self.assertLess(guard.index('SetBusy(true)'), guard.index('await action()'))
        self.assertIn('running = value;', window)
        # A background Disk run is not «applying settings» of the window: config Apply and other sections go on.
        self.assertIn('return running || folderActionRunning || detailsWindow', source('ConfigWindow.Main.cs'))
        exit_ = source('TrayContext.cs').split('void RequestExit()', 1)[1]
        self.assertIn('((ConfigWindow)f).IsApplying', exit_)
        self.assertIn('BackgroundWork.Disk.Busy', exit_.split('MessageBox', 1)[0])

    def test_folder_confirmation_is_independent_of_the_plan_and_tree_reads(self):
        window = source('ConfigWindow.cs')
        self.assertNotIn('deferredSections', window)
        self.assertNotIn('FolderContinuation', window)
        self.assertNotIn('после выбора папок', window)
        self.assertIn('WindowModel.SessionPlan(plan, folderStepRequired, chosen)', window)
        report = window.split('void Report(', 1)[1].split('void SetBusy(', 1)[0]
        self.assertIn('section == ConfigSections.Connection && state == SectionState.Done', report)
        self.assertIn('ShowFoldersEarly();', report)
        early = window.split('void ShowFoldersEarly()', 1)[1].split('void SkipFolders()', 1)[0]
        self.assertIn('foldersPanel.Visible = true', early)
        self.assertIn('var load = LoadFolders()', early)
        self.assertNotIn('await ', early)
        read = window.split('async Task ReadFolders(', 1)[1].split('bool loadingFolders', 1)[0]
        self.assertNotIn('Guard(', read)
        apply = window.split('Task ApplyFolders()', 1)[1].split('async Task Finish()', 1)[0]
        self.assertNotIn('await ', apply, 'apply only stores the choice and returns at once')
        self.assertIn('StartDisk();', apply)
        self.assertNotIn('RunSession(', apply)
        start = window.split('void StartDisk()', 1)[1].split('static bool DiskChosen(', 1)[0]
        self.assertIn('BackgroundWork.Disk.Start(', start)
        self.assertIn('current.ApplyDisk(token)', start)
        self.assertNotIn('cancel.Token', start, 'the Disk run must outlive the window')
        retry = window.split('async Task RetrySection(', 1)[1].split('async Task<Dictionary', 1)[0]
        self.assertIn('if (section == ConfigSections.Disk) { StartDisk(); return; }', retry)
        self.assertNotIn('ApplyFolders', retry)
        finish = window.split('async Task Finish()', 1)[1].split('async Task RenameDevice()', 1)[0]
        self.assertIn('else SkipFolders()', finish)
        self.assertIn('AnyFolders(folders.Model.ToChoice())', finish)
        self.assertNotIn('allowPendingDisk', window)
        self.assertIn('WindowModel.CanFinish(', window)
        self.assertIn('FolderMutationConflict = () => MutationConflict(mainWindow)', source('TrayContext.cs'))

    def test_folder_footer_has_reserved_layout_rows_in_both_hosts(self):
        window = source('ConfigWindow.cs')
        self.assertNotIn('Dock = DockStyle.Fill, Height = 520', window)
        self.assertIn('windowLayout.Controls.Add(settings ? (Control)tabs : foldersPanel, 0, 1)', window)
        self.assertIn('windowLayout.Controls.Add(journal, 0, 2)', window)
        self.assertIn('AutoScroll = true', window)
        view = source('DiskFoldersView.cs')
        self.assertIn('frame.RowStyles.Add(new RowStyle(SizeType.Percent, 100))', view)
        self.assertIn('frame.RowStyles.Add(new RowStyle(SizeType.AutoSize))', view)
        self.assertIn('frame.Controls.Add(content, 0, 0); frame.Controls.Add(footer, 0, 1)', view)
        self.assertIn('Dock = DockStyle.Fill, AutoScroll = true', view)
        self.assertIn('AutoScaleMode = AutoScaleMode.Inherit', view)

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
        self.assertIn('if (state == "finished") await Execute(new[] { ConfigSections.Disk }, token);', disk)
        tray = source('TrayContext.cs')
        self.assertIn('BackgroundWork.Disk.Stop();', tray.split('protected override void ExitThreadCore()', 1)[1])
        self.assertIn('BackgroundWork.Disk.Changed +=', tray)
        self.assertIn('BackgroundWork.Disk.Changed -= diskChanged', window)
        # Imported config: the folder model follows the stored profile at once (no stale overwrite).
        self.assertIn('if (settings) InitializeFolders();', window.split('async Task StartFromText(', 1)[1])

    def test_folder_ui_never_disabled_or_waiting(self):
        view = source('DiskFoldersView.cs')
        set_busy = view.split('internal void SetBusy(bool value)', 1)[1].split('\n', 1)[0]
        self.assertNotIn('Enabled', set_busy)
        self.assertNotIn('tree.Enabled', view)
        self.assertNotIn('computerTree.Enabled', view)
        for guarded in ['if (busy) return;', 'if (!busy && Apply', 'if (!busy && Reload', 'take.Enabled = !busy', 'send.Enabled = !busy']:
            self.assertNotIn(guarded, view)
        tree = source('DiskFolderTree.cs')
        self.assertNotIn('busy()', tree)
        self.assertIn('Загружаю…', tree)
        self.assertIn('internal void ShowMessage(string text)', tree)
        self.assertIn('Tree.SelectedNode = e.Node', tree.split('Tree.AfterCheck +=', 1)[1].split('Tree.BeforeExpand', 1)[0])
        window = source('ConfigWindow.cs')
        load = window.split('async Task LoadFolders()', 1)[1].split('void InitializeFolders()', 1)[0]
        self.assertNotIn('diskApplying', load)
        inner = window.split('async Task LoadFoldersInner()', 1)[1].split('Task ApplyFolders()', 1)[0]
        self.assertLess(inner.index('folders.ShowLoading()'), inner.index('await Bundle()'))
        self.assertLess(inner.index('var nav = folders.RefreshNavPane();'), inner.index('await tree'))
        self.assertIn('folders.ShowLoadFailed()', inner)
        self.assertIn('WindowModel.FoldersRecommendation', window)

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
        self.assertIn('Resize += (a, b) => LayoutRows();', window)
        view = source('DiskFoldersView.cs')
        self.assertNotIn('Font.Height * 12', view)
        self.assertIn('layout.RowStyles[layout.RowCount - 1] = new RowStyle(SizeType.Percent, 100)', view)
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
