"""Offline instruction handoff tests. No server, model, auth or account files."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("handoff", Path(__file__).with_name("server-agent-handoff.py"))
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class InstructionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "AGENTS.md"
        self.pointer = Path("/home/remoteagents/handoff/instructions.md")
        # Only the Unix ownership primitive is substituted on Windows.
        self.owner = patch.object(handoff, "owned")
        self.owner.start()
        self.addCleanup(self.owner.stop)
        self.flags = patch.object(os, "O_NOFOLLOW", getattr(os, "O_NOFOLLOW", 0), create=True)
        self.flags.start()
        self.addCleanup(self.flags.stop)

    def test_preserves_existing_rules_and_reruns_without_duplicate_blocks(self):
        original = "# Project rules\nUse the existing test command.\n"
        self.path.write_text(original, encoding="utf-8")
        handoff.install_instruction_pointer(self.path, self.pointer)
        first = self.path.read_text(encoding="utf-8")
        self.assertTrue(first.startswith(original))
        self.assertIn(str(self.pointer), first)
        handoff.install_instruction_pointer(self.path, self.pointer)
        self.assertEqual(self.path.read_text(encoding="utf-8"), first)

    def test_failed_replace_preserves_original_and_cleans_temporary(self):
        self.path.write_text("Original instructions", encoding="utf-8")
        with patch.object(os, "replace", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                handoff.install_instruction_pointer(self.path, self.pointer)
        self.assertEqual(self.path.read_text(encoding="utf-8"), "Original instructions")
        self.assertEqual(list(self.path.parent.glob("*.tmp")), [])

    def test_ambiguous_block_is_left_unchanged(self):
        original = "<!-- RemoteAgents handoff begin -->\nIncomplete block"
        self.path.write_text(original, encoding="utf-8")
        with self.assertRaises(ValueError):
            handoff.install_instruction_pointer(self.path, self.pointer)
        self.assertEqual(self.path.read_text(encoding="utf-8"), original)

    def test_two_handoffs_keep_shared_instructions_without_implicit_last_host(self):
        home=Path(self.temp.name)/'managed-home';workspace=home/'work/projects/p-shared';workspace.mkdir(parents=True)
        rules=workspace/'AGENTS.md';rules.write_text('# Owner rules\nPreserve these rules.\n','utf-8')
        with patch.object(handoff,'USER_HOME',home):
            for index,host in enumerate(('home','laptop')):
                label='win-'+str(index)*28
                data={'schema':1,'projectId':'p-shared','hostId':host,'deviceLabel':label,'deviceName':host,'serverWorkspace':str(workspace),'windowsReplica':'C:\\replica\\'+host,'socketPath':str(home/'.local/state/codex-remote'/(label+'.sock')),'agents':'3','allowShell':True}
                handoff.prepare(data)
            shared=home/'.local/share/remote-agent-handoff/p-shared/instructions.md'
            text=rules.read_text('utf-8')
            self.assertTrue(text.startswith('# Owner rules\nPreserve these rules.\n'))
            self.assertIn(str(shared),text)
            self.assertNotIn('/home/instructions.md',text)
            self.assertNotIn('/laptop/instructions.md',text)
            content=shared.read_text('utf-8')
            self.assertIn('windows_devices',content)
            self.assertIn('taskId',content)
            self.assertIn('не выбирают цель',content)
            for relative in ('AGENTS.md','CLAUDE.md','.codex/AGENTS.md','.claude/CLAUDE.md'):
                self.assertIn(str(home/'.local/share/remote-agent-handoff/instructions.md'),(home/relative).read_text('utf-8'))
            self.assertIn('Не требуй служебного первого сообщения',content)


if __name__ == "__main__":
    unittest.main()
