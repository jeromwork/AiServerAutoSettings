#!/usr/bin/env python3
"""Offline shims exercise diagnostic cleanup and secret handling, without network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = sys.argv[1] if len(sys.argv) > 1 else str(Path.home()/'.cache/pwsh-test/pwsh')


def executable(path, source):
    path.write_text('#!'+sys.executable+'\n'+source)
    path.chmod(0o700)


class DiagnosticsTests(unittest.TestCase):
    def test_bounded_stderr_captures_first_line_exit_and_short_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); child = root/'failure'
            executable(child, "import os,sys\nos.write(2,b'Connection refused: pw aa bb\\r\\n'+b'x'*1048576)\nsys.exit(42)\n")
            script = root/'test.ps1'
            script.write_text("""param($Common,$Exe,$Root)
. $Common
$child=Start-TransportProcess $Exe @()
try{
    if(-not $child.Process.WaitForExit(10000)){throw 'stderr pipe blocked'}
    $d=New-TransportDiagnostic $child 'entry-fixture' 'process-exited' ([pscustomobject]@{password='pw';secrets=@{hy2='aa';trojan='bb'}})
    Write-TransportLog $Root 'process-failed' $d
    if($child.ErrorBuffer.Snapshot().Length -gt 11000){throw 'unbounded stderr'}
    $bytes=[Text.Encoding]::UTF8.GetBytes("`nERROR inbound/direct[probe-entry-fixture]: dial tcp: i/o timeout password=pw`n")
    $child.ErrorBuffer.Write($bytes,0,$bytes.Length)
    $engine=Get-TransportEngineDiagnostic $child 'entry-fixture' ([pscustomobject]@{password='pw';secrets=@{hy2='aa';trojan='bb'}})
    if(-not $engine -or $engine.reason -ne 'timeout'){throw 'sing-box probe reason lost'}
    Write-TransportLog $Root 'probe-failed' $engine
}finally{Stop-TransportProcess $child}
""", encoding='utf-8-sig')
            result = subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(script),
                                     '-Common',str(ROOT/'transport/Transport.Common.ps1'),
                                     '-Exe',str(child),'-Root',tmp], stdin=subprocess.DEVNULL, capture_output=True, timeout=45)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            log=(root/'logs/transport.log').read_text()
            self.assertIn('candidate=entry-fixture reason=connection-refused exit=42 stderr=Connection refused: <redacted> <redacted> <redacted>',log)
            self.assertNotIn('pw',log)
            self.assertNotIn('aa',log)
            self.assertNotIn('bb',log)
            self.assertIn('probe-failed candidate=entry-fixture reason=timeout',log)
            self.assertIn('dial tcp: i/o timeout password=<redacted>',log)

    def test_refresh_cache_secrets_remain_redacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root/'context.ps1'
            script.write_text("""param($Common,$Root)
. $Common
$generation=Join-Path $Root 'generation'
Write-TransportJson (Join-Path $generation 'secrets/entries/edge.json') @{secrets=@{hy2='refreshed-secret'}} -Private
$settings=[pscustomobject]@{Transport=[pscustomobject]@{cacheRoot=$generation}}
$context=@(Get-TransportDiagnosticContext $settings $Root)
$text=Protect-TransportDiagnostic 'dial refused refreshed-secret' $context
if($text.Contains('refreshed-secret')){throw 'refresh cache secret was not redacted'}
if(-not $text.Contains('<redacted>')){throw 'no context from refresh cache'}
""", encoding='utf-8-sig')
            result = subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(script),
                                     '-Common',str(ROOT/'transport/Transport.Common.ps1'),'-Root',tmp],
                                     capture_output=True, timeout=45)
            self.assertEqual(result.returncode,0,result.stderr.decode())

    def test_update_entries_does_not_echo_invalid_secret_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); ssh = root/'ssh'
            marker = 'short-password-marker'
            executable(ssh, "print('{\"password\":\""+marker+"\" INVALID}')\n")
            (root/'profile.json').write_text(json.dumps(dict(sshExecutable=str(ssh))))
            (root/'config.json').write_text(json.dumps(dict(transport=dict(profilePath=str(root/'profile.json'), entries=[dict(name='test', ssh='example.invalid')]))))
            result = subprocess.run([PWSH, '-NoProfile', '-NonInteractive', '-File', str(ROOT/'transport/Update-Entries.ps1'), '-Home', tmp], capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(marker.encode(), result.stdout+result.stderr)

    def test_update_entries_writes_active_refresh_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); ssh = root/'ssh'
            entry = dict(server='entry.invalid', sni='entry.invalid', cover='entry.invalid',
                         ports=dict(hy2=443), secrets=dict(hy2='fixture-only'))
            executable(ssh, 'print('+repr(json.dumps(entry))+')\n')
            (root/'profile.json').write_text(json.dumps(dict(sshExecutable=str(ssh))))
            (root/'config.json').write_text(json.dumps(dict(transport=dict(profilePath=str(root/'profile.json'),
                cacheRoot=str(root/'generation'), entries=[dict(name='edge', ssh='edge')]))))
            result = subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(ROOT/'transport/Update-Entries.ps1'),
                                     '-Home',tmp], capture_output=True, timeout=20)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            self.assertEqual(json.loads((root/'generation/secrets/entries/edge.json').read_text('utf-8-sig')),entry)
            self.assertFalse((root/'secrets/entries/edge.json').exists())

    def test_diagnostic_uses_private_config_and_reaps_processes(self):
        with tempfile.TemporaryDirectory(prefix='diagnostic Пользователь ') as tmp:
            root = Path(tmp); disk = root/'RemoteAgents'; channel = disk/'transport-bin'; channel.mkdir(parents=True)
            ssh = root/'ssh'; sb = channel/'sing-box.exe'; capture = root/'capture.json'; ledger = root/'children'
            executable(ssh, """import os,sys,time
from pathlib import Path
with Path(os.environ['DIAGNOSTIC_CHILDREN']).open('a') as f: f.write(str(os.getpid())+'\\n')
if '-N' in sys.argv:
    while True: time.sleep(.1)
if '-G' in sys.argv or sys.argv[-1].startswith('cat '): raise RuntimeError('unexpected personal default')
n=int(sys.argv[-1].split()[2]); os.write(1,b'x'*n)
""")
            executable(sb, """import json,os,sys,time,stat
from pathlib import Path
file=Path(sys.argv[sys.argv.index('-c')+1]); cfg=json.loads(file.read_text('utf-8-sig'))
if sys.argv[1]=='check': sys.exit(0)
Path(os.environ['DIAGNOSTIC_CAPTURE']).write_text(json.dumps(dict(fileMode=stat.S_IMODE(file.stat().st_mode),dirMode=stat.S_IMODE(file.parent.stat().st_mode),disabled=cfg['log']['disabled'])))
with Path(os.environ['DIAGNOSTIC_CHILDREN']).open('a') as f: f.write(str(os.getpid())+'\\n')
while True: time.sleep(.1)
""")
            profile = root/'profile.json'
            profile.write_text(json.dumps(dict(sshExecutable=str(ssh), arguments=['-p','22','tester@example.invalid'], serverAddress='example.invalid', login='tester', keyPath=str(root/'unused key'), knownHostsPath=str(root/'known hosts'), configPath=str(root/'unused config'))))
            (disk/'config.json').write_text(json.dumps(dict(transport=dict(profilePath=str(profile), channelPath=str(disk/'channel.json'), singBoxPath=str(sb))))+'\r\n')
            (disk/'channel.json').write_text(json.dumps(dict(outbounds=[dict(type='vless', tag='server', server='example.invalid', server_port=443, uuid='00000000-0000-4000-8000-000000000001'),dict(type='ssh', tag='old', server='example.invalid', server_port=22, user='tester', private_key_path=str(root/'key'), host_key=['ssh-ed25519 test-fixture'])])))
            env=dict(os.environ, LOCALAPPDATA=tmp, USERPROFILE=tmp, TEMP=tmp, DIAGNOSTIC_CAPTURE=str(capture), DIAGNOSTIC_CHILDREN=str(ledger))
            result=subprocess.run([PWSH, '-NoProfile', '-NonInteractive', '-File', str(ROOT/'transport/Test-Transports.ps1'), '-ProbeBytes','32','-AliveBytes','16','-ProbeSeconds','1','-SpeedBytes','64','-SpeedSeconds','1'], capture_output=True, env=env, timeout=30)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            info=json.loads(capture.read_text())
            self.assertEqual(info['fileMode'] & 0o077,0)
            self.assertEqual(info['dirMode'] & 0o077,0)
            self.assertTrue(info['disabled'])
            report=json.loads((disk/'transport-test.json').read_text())
            self.assertTrue(all(row['kbps'] > 0 for row in report['results']), 'short fast probes must not report zero speed')
            self.assertTrue(all(row['error'] is None for row in report['results']), 'healthy diagnostic rows must not contain an error')
            for value in ledger.read_text().splitlines():
                self.assertFalse(Path('/proc',value).exists(), 'diagnostic child leaked: '+value)
            self.assertFalse(list(root.glob('rd-transports-*')))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
