"""Contracts for the WinForms wiring that cannot run in the portable Linux harness."""
from pathlib import Path
import unittest

LAUNCHER = Path(__file__).resolve().parents[1]


class HappierAccountUiTests(unittest.TestCase):
    def test_key_is_hidden_read_only_and_cleared_on_hide(self):
        ui = (LAUNCHER / 'ConfigWindow.Main.cs').read_text()
        self.assertIn('TextBox happierKey = new TextBox { ReadOnly = true, Visible = false', ui)
        self.assertIn('happierKey.Clear(); happierKey.Visible = false;', ui)
        self.assertIn('if (!Visible) HideHappierKey()', ui)
        self.assertIn('if (name != "Главная") HideHappierKey()', (LAUNCHER / 'MainWindow.Settings.cs').read_text())
        self.assertIn('showHappierKey.Visible = copyHappierKey.Visible = current.HasKey;', ui)
        self.assertIn('HappierWebResolver.LocalUrl(', ui)
        self.assertIn('openHappier.Enabled =', ui)
        self.assertIn('RenderCard(view.Happier, happierCard, happierTitle, happierState, happierDetail)', (LAUNCHER / 'MainWindow.Cards.cs').read_text())

    def test_clipboard_and_show_run_on_ui_thread_without_logging_secrets(self):
        ui = (LAUNCHER / 'ConfigWindow.Main.cs').read_text()
        handlers = ui.split('showHappierKey.Click +=', 1)[1].split('VisibleChanged +=', 1)[0]
        self.assertIn('Clipboard.SetText(ReadHappierKey());', handlers)
        self.assertIn('happierKey.Text = key;', handlers)
        self.assertIn('openHappier.Click += async', ui)
        self.assertIn('await HappierWebResolver.ResolveAsync(', handlers)
        for forbidden in ('Task.Run', 'Log(', 'Journal', '.Message', '.ToString()', 'throw'):
            self.assertNotIn(forbidden, handlers)
        self.assertIn('[STAThread]', (LAUNCHER / 'EntryPoint.cs').read_text())
        read = ui.split('string ReadHappierKey()', 1)[1].split('void HappierActionFailed', 1)[0]
        self.assertIn('SecretVault.Get(home, happierModel.SecretName)', read)
        self.assertNotIn('Log(', read)
        failure = ui.split('void HappierActionFailed', 1)[1].split('void ShowHappierAccountCreated', 1)[0]
        self.assertNotIn('Log(', failure)

    def test_all_browser_entry_points_supply_secret_home_without_logging_url(self):
        main = (LAUNCHER / 'ConfigWindow.Main.cs').read_text()
        self.assertIn('{ "webappUrl", happierModel.WebUrl } }, home)', main)
        tray = (LAUNCHER / 'TrayContext.cs').read_text()
        self.assertIn('TrayMenuModel.HappierUrl(config.Data, AccountState(), home)', tray)
        wizard = (LAUNCHER / 'SetupWizard.cs').read_text()
        handler = wizard.split('openHappier.Click+=', 1)[1].split('// A new key', 1)[0]
        self.assertIn('await HappierWebResolver.ResolveAsync(', handler)
        self.assertIn('web.Text.Trim()}},home)', handler)
        self.assertNotIn('ConfigRequests.Origin(', handler)
        self.assertNotIn('.Message', handler)
        self.assertNotIn('Journal', handler)

    def test_creation_notification_is_marshaled_and_not_just_a_log(self):
        window = (LAUNCHER / 'ConfigWindow.cs').read_text()
        ui = (LAUNCHER / 'ConfigWindow.Main.cs').read_text()
        session = (LAUNCHER / 'ConfigApply.cs').read_text()
        self.assertIn('session.AccountCreated = message => Ui(() => ShowHappierAccountCreated(message));', window)
        self.assertIn('happierCreated.Text = message; happierCreated.Visible = true;', ui)
        self.assertIn('ShowPage("Главная");', ui.split('internal void ShowHappierAccountCreated', 1)[1].split('internal void ServiceActions', 1)[0])
        account = session.split('SectionOutcome Account(', 1)[1].split('// Root on the server', 1)[0]
        self.assertLess(account.index('SecretVault.Set(home, name, key)'), account.index('accountCreation.Remember(Json.Str(request, "label"))'))
        self.assertIn('NotifyAccountCreated(outcome);', account)
        self.assertIn('if (message.Length > 0) AccountCreated(message);', account)
        resume = session.split('internal async Task FollowPending', 1)[1]
        self.assertIn('NotifyAccountCreated(o);', resume)
        self.assertIn('accountCreation = new HappierAccountCreation(home)', session)
        tray = (LAUNCHER / 'TrayContext.cs').read_text()
        resume_tray = tray.split('"ResumeAccount"', 1)[1].split('ServerOperations.Save(home', 1)[0]
        self.assertLess(resume_tray.index('if (Json.Bool(account, "ok"))'), resume_tray.index('new HappierAccountCreation(home).Complete('))
        self.assertIn('mainWindow.ShowHappierAccountCreated(message)', resume_tray)
        self.assertIn('MessageBox.Show(message +', resume_tray)
        for line in account.splitlines():
            if 'Log(' in line:
                self.assertNotIn('+ key', line)
                self.assertNotIn('+ name', line)


if __name__ == '__main__':
    unittest.main(verbosity=2)
