"""Изолированные тесты набора: ни Gemini, ни сети, ни настоящих worktree."""
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'agent-tools/gemini-bench/gemini-bench'
loader = importlib.machinery.SourceFileLoader('gemini_bench', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
bench = importlib.util.module_from_spec(spec)
loader.exec_module(bench)

FAKE = r'''import argparse, fcntl, json, os, time
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('-C'); p.add_argument('-f'); p.add_argument('--model')
p.add_argument('--name'); p.add_argument('--max-min')
a = p.parse_args()
work = Path(a.C)
assert str(work) in Path(a.f).read_text()
def event(kind):
    with open(os.environ['FAKE_EVENTS'], 'a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(kind + '\n')
event('start')
time.sleep(0.04)
(work / 'old.txt').write_text('after\nextra\n')
(work / 'new file.txt').write_text('one\ntwo')
if os.environ.get('FAKE_FORBIDDEN'):
    (work / 'forbidden.txt').write_text('outside scope\n')
logs = Path(os.environ['FAKE_LOG_HOME'])
logs.mkdir(exist_ok=True)
progress = logs / (a.name + '.progress')
status = os.environ.get('FAKE_STATUS', 'ГОТОВО')
text = '[00:00] → read_file old.txt\n[00:01] → run_command edit\n[00:02] ' + status + '\n'
progress.write_text(text)
progress.with_suffix('.jsonl').write_text(json.dumps({'result': {'usage': {'total_tokens': 123}}}) + '\n')
print('[00:00] журнал: ' + str(progress), flush=True)
print(text, end='', flush=True)
event('end')
raise SystemExit(0 if status == 'ГОТОВО' else 1)
'''


class BenchTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='gemini-bench-test-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.repository = self.root / 'repo'
        self.repository.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Bench Test')
        self.git('config', 'user.email', 'bench@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'core.hooksPath', '/dev/null')
        (self.repository / 'old.txt').write_text('before\n')
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')
        self.base = self.git('rev-parse', 'HEAD')
        self.storage = self.root / 'results'
        self.kit = self.root / 'kit'
        self.task_id = '01-fixture'
        folder = self.kit / 'tasks' / self.task_id
        folder.mkdir(parents=True)
        (folder / 'task.md').write_text('Работать только в WORKDIR. Не коммитить.')
        (folder / 'check.sh').write_text('#!/bin/bash\nset -eu\ntest -f "new file.txt"\necho acceptance-details\n')
        self.meta = dict(id=self.task_id, type='тест', size='3 строки', description='fixture',
                         allowed_files=['old.txt', 'new file.txt'])
        (folder / 'meta.json').write_text(json.dumps(self.meta))
        fake = self.root / 'gemini-task-fake'
        fake.write_text(f'#!{sys.executable}\n' + FAKE)
        fake.chmod(0o755)
        self.events = self.root / 'events'
        env = dict(GEMINI_BENCH_HOME=str(self.storage), GEMINI_BENCH_REPO=str(self.repository),
                   GEMINI_TASK_BIN=str(fake), FAKE_LOG_HOME=str(self.root / 'logs'),
                   FAKE_EVENTS=str(self.events), FAKE_STATUS='ГОТОВО', FAKE_FORBIDDEN='')
        self.env = patch.dict(os.environ, env)
        self.env.start()
        self.addCleanup(self.env.stop)
        kit_patch = patch.object(bench, 'KIT', self.kit)
        kit_patch.start()
        self.addCleanup(kit_patch.stop)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repository), *args],
                                       stderr=subprocess.PIPE, text=True).strip()

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = bench.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def rows(self):
        return bench.read_jsonl(self.storage / 'results.jsonl')

    def test_status_and_error_samples(self):
        samples = [
            ('[01:12] ГОТОВО; продолжить: ...', '', 0, False, 'ГОТОВО', None),
            ('[02:00] ЗАВИС: нет активности', '', 2, False, 'ЗАВИС', 'прочее'),
            ('[20:00] ПРЕДЕЛ ВРЕМЕНИ 20 мин', '', 3, False, 'ЗАВИС', 'print_timeout'),
            ('[00:12] ОШИБКА agy', '{"error":"print_timeout exceeded"}', 1, False, 'ОШИБКА', 'print_timeout'),
            ('[00:12] ОШИБКА agy', '{"error":"unexpected EOF"}', 1, False, 'ОШИБКА', 'EOF'),
            ('[00:12] ОШИБКА agy', '{"error":{"code":503,"message":"no capacity"}}', 1, False, 'ОШИБКА', '503 no capacity'),
            ('[00:12] ОШИБКА agy interrupted', '', 130, False, 'ОШИБКА', 'interrupted'),
            ('', '', -9, True, 'ЗАВИС', 'print_timeout'),
            ('Ответ: ГОТОВО', '', 0, False, 'ОШИБКА', 'прочее'),
            ('[00:01] ГОТОВО\n[00:02] ОШИБКА agy', '', 1, False, 'ОШИБКА', 'прочее'),
            ('[00:01] ГОТОВО', '', 1, False, 'ОШИБКА', 'прочее'),
        ]
        for progress, raw, code, expired, status, kind in samples:
            with self.subTest(progress=progress, raw=raw):
                parsed = bench.parse_logs(progress, raw, code, expired)
                self.assertEqual((parsed['status'], parsed['error_kind']), (status, kind))

    def test_turns_tokens_and_success_quoting_errors(self):
        parsed = bench.parse_logs('[00:00] → read_file a\n[00:02] → run_command b\nEOF in response\n[00:03] ГОТОВО',
                                  '{"result":{"usage":{"input_tokens":30,"output_tokens":12}}}\ninvalid json')
        self.assertEqual(parsed['turns'], 2)
        self.assertEqual(parsed['tokens']['result.usage.input_tokens'], 30)
        self.assertIsNone(parsed['error_kind'])

    def test_count_staged_untracked_binary_and_committed_changes(self):
        (self.repository / 'old.txt').write_text('after\nextra\n')
        self.git('add', 'old.txt')
        self.git('commit', '-m', 'agent commit')
        (self.repository / 'new file.txt').write_text('one\ntwo')
        (self.repository / 'binary').write_bytes(b'a\x00b')
        (self.repository / 'outside-link').symlink_to('/does/not/exist')
        stats = bench.change_stats(self.repository, self.base, self.meta['allowed_files'])
        self.assertEqual(stats['files_changed'], 4)
        self.assertEqual((stats['lines_added'], stats['lines_removed']), (5, 1))
        self.assertEqual(stats['forbidden_files'], ['binary', 'outside-link'])

    def test_deleted_and_renamed_files(self):
        self.git('mv', 'old.txt', 'renamed.txt')
        stats = bench.change_stats(self.repository, self.base, ['old.txt'])
        self.assertEqual((stats['files_changed'], stats['lines_added'], stats['lines_removed']), (2, 1, 1))
        self.assertEqual(stats['forbidden_files'], ['renamed.txt'])

    def test_run_results_and_cleanup(self):
        code, output, error = self.cli('run', '--modes', 'low', '--label', 'night')
        self.assertEqual((code, error), (0, ''))
        self.assertIn('механика=да', output)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        required = 'runid ts weekday hour task mode repeat label status error_kind seconds turns check_ok check_detail files_changed lines_added lines_removed forbidden_files worktree progress_file'.split()
        self.assertTrue(set(required).issubset(row))
        self.assertEqual((row['status'], row['check_ok'], row['turns']), ('ГОТОВО', True, 2))
        self.assertEqual((row['files_changed'], row['lines_added'], row['lines_removed']), (2, 4, 1))
        self.assertEqual(row['label'], 'night')
        self.assertIn('acceptance-details', row['check_detail'])
        self.assertEqual(row['tokens']['result.usage.total_tokens'], 123)
        self.assertTrue(Path(row['plan_file']).is_file())
        self.assertTrue(Path(row['progress_file']).is_file())
        self.assertFalse(Path(row['worktree']).exists())
        self.assertEqual(self.git('branch', '--format=%(refname:short)'), 'main')
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(row['weekday'], datetime.fromisoformat(row['ts']).weekday())

    def test_forbidden_files_refuse_acceptance_keep_failed(self):
        with patch.dict(os.environ, FAKE_FORBIDDEN='1'):
            code, _, _ = self.cli('run', '--modes', 'medium', '--keep-failed')
        self.assertEqual(code, 1)
        row = self.rows()[0]
        self.assertEqual(row['status'], 'ГОТОВО')
        self.assertFalse(row['check_ok'])
        self.assertEqual(row['forbidden_files'], ['forbidden.txt'])
        self.assertTrue(row['retained'])
        self.assertTrue(Path(row['worktree']).is_dir())
        self.assertIn('Запрещённые файлы', row['check_detail'])

    def test_failure_no_retry_and_cleanup(self):
        with patch.dict(os.environ, FAKE_STATUS='ОШИБКА EOF'):
            code, _, _ = self.cli('run', '--modes', 'high')
        self.assertEqual(code, 1)
        row = self.rows()[0]
        self.assertEqual(row['error_kind'], 'EOF')
        self.assertTrue(row['check_ok'])  # механика и статус независимы
        self.assertEqual(self.events.read_text().splitlines(), ['start', 'end'])
        self.assertFalse(Path(row['worktree']).exists())

    def test_failed_check_and_keep_all_review_verdict(self):
        check = self.kit / 'tasks' / self.task_id / 'check.sh'
        check.write_text('echo check-failed\nexit 7\n')
        code, _, _ = self.cli('run', '--modes', 'low', '--keep-all')
        self.assertEqual(code, 1)
        row = self.rows()[0]
        self.assertFalse(row['check_ok'])
        self.assertTrue(row['retained'])
        self.assertEqual(self.cli('review', row['runid'])[0], 0)
        review = (self.storage / f'review-{row["runid"]}.md').read_text()
        self.assertIn(row['plan_file'], review)
        self.assertIn(row['worktree'], review)
        self.assertIn('Только чтение', review)
        self.assertEqual(self.cli('add-verdict', row['runid'], self.task_id, 'low', 'ЗАМЕЧАНИЯ', 'нет покрытия')[0], 0)
        self.assertEqual(bench.verdict_map()[(row['runid'], self.task_id, 'low')], 'ЗАМЕЧАНИЯ')
        self.assertEqual(self.cli('add-verdict', 'missing', self.task_id, 'low', 'ПРИНЯТО')[0], 2)
        self.assertEqual(self.cli('review', '../../missing')[0], 2)

    def test_keep_all_success_and_parallel_limit(self):
        code, _, _ = self.cli('run', '--modes', 'low,high', '--repeat', '3', '--parallel', '2', '--keep-all')
        self.assertEqual(code, 0)
        self.assertEqual(len(self.rows()), 6)
        active = maximum = 0
        for event in self.events.read_text().splitlines():
            active += 1 if event == 'start' else -1
            maximum = max(maximum, active)
            self.assertLessEqual(active, 2)
        self.assertEqual(active, 0)
        self.assertGreaterEqual(maximum, 1)
        for row in self.rows():
            self.assertTrue(row['retained'])
            self.assertTrue(Path(row['worktree']).is_relative_to(self.storage))
            self.assertTrue(Path(row['worktree']).is_dir())

    def test_infrastructure_failure_is_recorded(self):
        with patch.dict(os.environ, GEMINI_TASK_BIN=str(self.root / 'missing')):
            code, _, _ = self.cli('run', '--modes', 'low')
        self.assertEqual(code, 1)
        row = self.rows()[0]
        self.assertEqual(row['status'], 'ОШИБКА')
        self.assertFalse(row['check_ok'])
        self.assertIn('FileNotFoundError', row['check_detail'])
        self.assertFalse(Path(row['worktree']).exists())

    def test_report_filters_verdicts_and_slow_runs(self):
        common = dict(runid='sample', ts='2026-11-21T12:00:00+01:00', weekday=5, hour=12,
                      task=self.task_id, repeat=1, label='batch', status='ГОТОВО', error_kind=None)
        for mode, seconds, ok, kind in [('low', 10, True, None), ('low', 30, False, 'EOF'),
                                         ('high', 601, True, None)]:
            bench.append_json(self.storage / 'results.jsonl', dict(common, mode=mode, seconds=seconds,
                              check_ok=ok, error_kind=kind))
        self.cli('add-verdict', 'sample', self.task_id, 'low', 'ПРИНЯТО')
        self.cli('add-verdict', 'sample', self.task_id, 'low', 'ОТВЕРГНУТО', 'последний')
        code, text, err = self.cli('report', '--since', '2026-11-20', '--label', 'batch')
        self.assertEqual((code, err), (0, ''))
        self.assertIn('| 01-fixture | low | 1/2 | 0/2 | 20.0 | EOF: 1 |', text)
        self.assertIn('| 01-fixture | high | 1/1 | 0/0 | 601 |', text)
        self.assertIn('12:00', text)
        self.assertIn('Сб', text)
        self.assertIn('| sample | 01-fixture | high | 1 | 601 |', text)
        self.assertIn('Нет результатов', self.cli('report', '--label', 'absent')[1])
        self.assertIn('Нет результатов', self.cli('report', '--since', '2027-01-01')[1])

    def test_empty_report_bad_json_and_import_stub(self):
        self.assertIn('Нет результатов', self.cli('report')[1])
        self.storage.mkdir(exist_ok=True)
        (self.storage / 'results.jsonl').write_text('not-json\n{}\n')
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(bench.read_jsonl(self.storage / 'results.jsonl'), [{}])
        self.assertIn(':1:', err.getvalue())
        code, _, message = self.cli('import', str(self.root))
        self.assertEqual(code, 2)
        self.assertIn('Ничего не создано', message)

    def test_bad_selection_never_starts_agent(self):
        for args in [('run', '--tasks', 'missing'), ('run', '--modes', 'low,low'),
                     ('run', '--tasks', f'{self.task_id},{self.task_id}')]:
            with self.subTest(args=args):
                self.assertEqual(self.cli(*args)[0], 2)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.storage / 'results.jsonl').exists())

    def test_timeout_kills_child_in_separate_session(self):
        child_pid = self.root / 'child-pid'
        script = self.root / 'hang.py'
        script.write_text('import subprocess, sys, time\nfrom pathlib import Path\n'
                          'p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)\n'
                          f'Path({str(child_pid)!r}).write_text(str(p.pid))\n'
                          'time.sleep(60)\n')
        code, expired = bench.execute([sys.executable, str(script)], self.root, self.root / 'out', 1)
        self.assertTrue(expired)
        self.assertLess(code, 0)
        self.assertTrue(child_pid.exists())
        stat = Path('/proc') / child_pid.read_text() / 'stat'
        if stat.exists():
            self.assertEqual(stat.read_text().rsplit(')', 1)[1].split()[0], 'Z')


if __name__ == '__main__':
    unittest.main()
