#requires -Version 5.1
param([string]$TestHome)
# Proxy/LAN sections: fake ssh executes the root job locally with a fake python3; no root, no network.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
[void][IO.Directory]::CreateDirectory($TestHome)
$count=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:count++}
function Throws([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body}catch{$failed=$true};Assert $failed $Name}
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory((Join-Path $root 'secrets'))
$bin=Join-Path $TestHome 'bin';[void][IO.Directory]::CreateDirectory($bin)
$log=Join-Path $TestHome 'calls';[void][IO.Directory]::CreateDirectory($log)
# ssh: "-l root" + BatchMode works only when RA_ROOTKEY=1; the remote command runs in local bash.
Write-DiskUtf8 (Join-Path $bin 'ssh') @'
#!/usr/bin/python3
import json,os,subprocess,sys,uuid
from pathlib import Path
args=sys.argv[1:];log=Path(os.environ['RA_LOG'])
user=args[args.index('-l')+1] if '-l' in args else 'profile'
data=sys.stdin.buffer.read()
(log/('ssh-'+uuid.uuid4().hex+'.json')).write_text(json.dumps({'user':user,'args':args}))
if user=='root' and os.environ.get('RA_ROOTKEY')!='1':sys.exit(255)
if args[-1]=='true':sys.exit(0)
r=subprocess.run(['bash','-c',args[-1]],input=data,capture_output=True)
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
'@
# python3 records argv and stdin of the root job; it never touches the network.
Write-DiskUtf8 (Join-Path $bin 'python3') @'
#!/bin/bash
f="$RA_LOG/python-$$-$RANDOM"; printf '%s\n' "$@" > "$f.args"; cat > "$f.stdin"
for a in "$@"; do case "$a" in */*.py) cp "$a" "$f.script";; esac; done
exit "${RA_PY_EXIT:-0}"
'@
& chmod +x (Join-Path $bin 'ssh') (Join-Path $bin 'python3')
# Installed root copies are fakes that record their arguments.
$script:WizardNetBin=Join-Path $TestHome 'lib';foreach($d in @('lan/lan-vpn.sh','proxy-out/proxy-out.sh')){$f=Join-Path $script:WizardNetBin $d;[void][IO.Directory]::CreateDirectory((Split-Path $f -Parent));Write-DiskUtf8 $f ("#!/bin/bash`necho ""`$@"" >> ""`$RA_LOG/installed-"+(Split-Path $d -Leaf)+".txt""`n");& chmod +x $f}
$env:RA_LOG=$log;$env:PATH=$bin+[IO.Path]::PathSeparator+$env:PATH
$profileFile=Join-Path $TestHome 'profile.json'
Write-TransportJson $profileFile @{sshExecutable=(Join-Path $bin 'ssh');serverAddress='server.example.invalid';login='remoteagents';keyPath='k';knownHostsPath='kh';configPath='cfg';arguments=@('remoteagents@server.example.invalid')}
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{profilePath=$profileFile};components=@{}}
function Clear-Calls{Get-ChildItem $log|Remove-Item -Force}
function Get-Calls([string]$Pattern){@(Get-ChildItem $log -Filter $Pattern|Sort-Object LastWriteTime)}
$script:relayReads=0
function Read-WizardRelay([string]$Name){$script:relayReads++;if($Name -eq 'admin'){return 'touch PWNED-BY-PASSWORD'};return '{"username":"TEST_ONLY_LAN_USER","password":"TEST_ONLY_LAN_PASS"}'}
$secret='TEST_ONLY_PROXY_PASS'
Write-TransportJson (Join-Path $root 'secrets/proxy-out.json') @{username='TEST_ONLY_PROXY_USER';password=$secret}
$request=[pscustomobject]@{type='socks';server='proxy.example.invalid';port='1080';ipCheckUrl='https://ip.example.invalid/'}

# 1. Root key accepted: no password is ever requested.
$env:RA_ROOTKEY='1'
Assert ((Get-WizardAdminMode $root ([pscustomobject]@{})) -eq 'rootkey') 'root key works -> rootkey mode'
Clear-Calls;$r=Set-WizardProxy $root $repo $request
Assert ($r.ok -and $r.mode -eq 'rootkey' -and $script:relayReads -eq 0) 'root key: applied and confirmed without any password prompt'
Assert (([IO.File]::ReadAllText((Join-Path $log 'installed-proxy-out.sh.txt'))).Trim() -eq 'confirm --ssh-checked') 'confirm in a new SSH session'
$ssh=Get-Calls 'ssh-*'|ForEach-Object {[IO.File]::ReadAllText($_.FullName)|ConvertFrom-Json}
Assert (@($ssh|Where-Object {$_.user -eq 'root'}).Count -ge 3) 'probe, apply and confirm each in its own root SSH connection'
Assert (-not (@($ssh|ForEach-Object {$_.args})|Where-Object {$_ -match 'TEST_ONLY|sudo'})) 'no secret and no sudo in ssh argv'
$py=Get-Calls 'python-*.args'
Assert ($py.Count -eq 1) 'one root python job (confirm uses the installed root-owned copy)'
$argv=[IO.File]::ReadAllText($py[0].FullName);$stdin=[IO.File]::ReadAllText(($py[0].FullName -replace '\.args$','.stdin'))
Assert ($argv.Contains('apply') -and $argv.Contains('--credentials-stdin') -and -not $argv.Contains('TEST_ONLY')) 'proxy secrets not in argv'
Assert ($stdin.StartsWith($script:WizardNetMarker+"`n") -and $stdin.Contains($secret) -and $stdin.Contains('TEST_ONLY_PROXY_USER')) 'proxy secrets reach the script only on stdin after the marker'
Assert ([IO.File]::ReadAllText(($py[0].FullName -replace '\.args$','.script')) -ceq (Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $repo 'server/proxy_out.py'))))) 'exact bundled proxy_out.py in a root temp dir'
$c=Read-TransportJson (Join-Path $root 'config.json')
Assert ($c.proxy.confirmed -and $c.proxy.server -eq 'proxy.example.invalid' -and -not ([IO.File]::ReadAllText((Join-Path $root 'config.json')).Contains($secret))) 'config keeps settings, never the secret'
$env:RA_PY_EXIT='1';Throws {Set-WizardProxy $root $repo $request} 'failed root job is reported, not confirmed';$env:RA_PY_EXIT=''
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).proxy.confirmed) 'failure leaves proxy unconfirmed'

# 2. The existing profile is root.
$env:RA_ROOTKEY='0'
$p=Read-TransportJson $profileFile;$p.login='root';Write-TransportJson $profileFile $p
Assert ((Get-WizardAdminMode $root ([pscustomobject]@{})) -eq 'profile') 'root profile -> no password'
$p.login='remoteagents';Write-TransportJson $profileFile $p

# 3. No root key: password (if typed) else the administrator command.
Assert ((Get-WizardAdminMode $root ([pscustomobject]@{})) -eq 'command') 'no key, no password -> administrator command'
Assert ((Get-WizardAdminMode $root ([pscustomobject]@{passwordPipe='admin'})) -eq 'password') 'typed password -> password mode'
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){$script:uploaded+=$InputText;''}
$script:uploaded=''
$r=Set-WizardProxy $root $repo $request
Assert (-not $r.ok -and $r.command.StartsWith('sudo bash ~remoteagents/') -and $r.command.Contains('--ask-credentials') -and $r.command.Contains('confirm --ssh-checked')) 'administrator command, honest not-applied status'
Assert (-not $r.command.Contains($secret) -and -not $script:uploaded.Contains($secret)) 'administrator path carries no proxy secret'

# 4. sudo password: first stdin line for sudo; never executed if sudo does not read it (NOPASSWD).
$script:captured=$null
function Invoke-WizardAskpass($Profile,$User,$Command,$InputText,$Request,$Timeout){$script:captured=@{user=$User;command=$Command;input=$InputText};''}
[void](Invoke-WizardAdmin $root ([pscustomobject]@{passwordPipe='admin';adminLogin='admin'}) 'password' 'echo job-ran')
Assert ($script:captured.command.StartsWith("sudo -S -k -p '' bash -c ") -and $script:captured.input.StartsWith("touch PWNED-BY-PASSWORD`n")) 'sudo -S gets the password as first stdin line, not argv'
$reader=$script:captured.command.Substring("sudo -S -k -p '' ".Length)
Push-Location $TestHome
try{$out=Invoke-DiskProcess '/bin/bash' @('-c',$reader) $script:captured.input}finally{Pop-Location}
Assert ($out -eq 'job-ran' -and -not (Test-Path (Join-Path $TestHome 'PWNED-BY-PASSWORD'))) 'unread password line is skipped, never executed'
[void](Invoke-WizardAdmin $root ([pscustomobject]@{passwordPipe='admin'}) 'password' 'true')
Assert ($script:captured.user -eq 'root' -and -not $script:captured.command.Contains('sudo')) 'root password: SSH login as root, no sudo'

# 5. LAN: profile with bare auth-user-pass; credentials only on stdin; test+confirm in a new session.
Remove-Item Function:\Invoke-WizardSsh,Function:\Invoke-WizardAskpass
$keepBin=$script:WizardNetBin;. (Join-Path $repo 'build/Wizard.Common.ps1');$script:WizardNetBin=$keepBin
function Read-WizardRelay([string]$Name){$script:relayReads++;return '{"username":"TEST_ONLY_LAN_USER","password":"TEST_ONLY_LAN_PASS"}'}
$env:RA_ROOTKEY='1';Clear-Calls
$ovpn=Join-Path $TestHome 'office.ovpn'
[IO.File]::WriteAllText((Join-Path $TestHome 'ca.crt'),"fixture-CA`r`n")
[IO.File]::WriteAllText($ovpn,"client`r`nremote vpn.example.invalid 1194`r`nca ca.crt`r`nauth-user-pass`r`n")
$lan=[pscustomobject]@{kind='openvpn';name='office';file=$ovpn;ipCheckUrl='https://ip.example.invalid/';host='10.1.2.3';port='22'}
Throws {Add-WizardLan $root $repo $lan} 'profile needing credentials without them fails before any change'
Assert ((Get-Calls 'python-*.args').Count -eq 0) 'nothing ran on the server'
$lan|Add-Member secretPipe 'lan'
$r=Add-WizardLan $root $repo $lan
Assert ($r.ok -and $r.name -eq 'office') 'LAN added and confirmed'
$py=Get-Calls 'python-*.args';$argv=[IO.File]::ReadAllText($py[0].FullName);$stdin=[IO.File]::ReadAllText(($py[0].FullName -replace '\.args$','.stdin'))
Assert ($argv.Contains('add') -and $argv.Contains('--auth-stdin') -and -not $argv.Contains('TEST_ONLY')) 'LAN credentials not in argv'
Assert ($stdin.Contains('TEST_ONLY_LAN_PASS') -and $stdin.StartsWith($script:WizardNetMarker)) 'LAN credentials only on stdin'
$ssh=Get-Calls 'ssh-*'|ForEach-Object {[IO.File]::ReadAllText($_.FullName)|ConvertFrom-Json}
Assert (@($ssh|Where-Object {$_.args[-1] -match 'bash -c'}).Count -eq 2) 'add and test+confirm run in two separate SSH connections'
Assert ([IO.File]::ReadAllText((Join-Path $log 'installed-lan-vpn.sh.txt')) -match '(?m)^test office 10\.1\.2\.3 22\r?\n(?m)confirm office --ssh-checked') 'test then confirm via the installed root copy'
$lan2=[pscustomobject]@{kind='openvpn';name='home';file=$ovpn;ipCheckUrl='https://ip.example.invalid/';host='192.168.1.10';port='';secretPipe='lan'}
[void](Add-WizardLan $root $repo $lan2)
$c=Read-TransportJson (Join-Path $root 'config.json')
Assert (@($c.lan.connections).Count -eq 2 -and -not ([IO.File]::ReadAllText((Join-Path $root 'config.json')).Contains('TEST_ONLY'))) 'several LANs listed; config has no secrets'
Throws {Add-WizardLan $root $repo ([pscustomobject]@{kind='wireguard';file=$ovpn})} 'other kinds are refused honestly for now'
Throws {Add-WizardLan $root $repo ([pscustomobject]@{kind='openvpn';name='Bad-Name';file=$ovpn;ipCheckUrl='https://ip.example.invalid/';host='10.1.2.3'})} 'LAN name validated'
$r=Remove-WizardLan $root $repo ([pscustomobject]@{name='home'})
Assert ($r.ok -and @((Read-TransportJson (Join-Path $root 'config.json')).lan.connections).Count -eq 1) 'remove drops the LAN'

# 6. Status: server public status merged with the local list; honest states.
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){"{""name"":""office"",""enabled"":true,""ready"":true,""active"":true,""ok"":true,""summary"":""x""}`r`n{""name"":""lab"",""enabled"":true,""ready"":true,""active"":false,""ok"":false,""summary"":""клиент не активен""}`r`n#proxy`r`n{""state"":""pending"",""ok"":false,""summary"":""ждёт""}"}
$s=Get-WizardNetStatus $root
$rows=@{};foreach($row in $s.lans){$rows[$row.name]=$row}
Assert ($rows['office'].ok -and $rows['office'].state -eq 'подключена ✓') 'connected LAN shown as connected'
Assert (-not $rows['lab'].ok -and $rows['lab'].state.StartsWith('ошибка')) 'inactive LAN shown as error'
Assert ($s.proxy.state -eq 'pending' -and -not $s.proxy.ok) 'proxy status from server, CRLF tolerated'
Write-Output ('OK: '+$count+' proxy/LAN network checks (fake ssh/sudo/python, no root, no Windows)')
