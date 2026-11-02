"""Offline tests: no GUI, server, account files or credentials."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("onboarding", Path(__file__).with_name("server-desktop-onboarding.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OnboardingTests(unittest.TestCase):
    def test_launches_one_selected_app_with_managed_display(self):
        for agents, command in (("1", "chatgpt"), ("2", "claude-desktop"), ("3", "chatgpt")):
            runner = Mock()
            with patch.object(module, "prepare") as prepare, patch.object(module.shutil, "which", return_value="/usr/bin/" + command):
                module.launch(agents, Path("/home/remoteagents"), runner)
            prepare.assert_called_once()
            runner.assert_called_once()
            args, options = runner.call_args
            self.assertEqual(args[0], ["/usr/bin/" + command])
            self.assertEqual(options["env"]["DISPLAY"], ":98")
            self.assertEqual(options["cwd"], Path("/home/remoteagents/work"))
            self.assertTrue(options["start_new_session"])

    def test_missing_app_does_not_launch_browser_or_password_flow(self):
        runner = Mock()
        with patch.object(module, "prepare"), patch.object(module.shutil, "which", return_value=None):
            with self.assertRaises(ValueError):
                module.launch("1", Path("/home/remoteagents"), runner)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
