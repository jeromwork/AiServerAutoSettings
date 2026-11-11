#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
[void][IO.Directory]::CreateDirectory($TestHome)
$count=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:count++}
function Throws([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body}catch{$failed=$true};Assert $failed $Name}
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
$env:LOCALAPPDATA=$TestHome
$script:WizardProgressFile=Join-Path $TestHome 'live.jsonl'
# Production key creation and profile persistence; SSH is a disposable executable fixture.
$bin=Join-Path $TestHome 'bin';[void][IO.Directory]::CreateDirectory($bin)
$fake=Join-Path $bin 'ssh'
$scriptText=@'
#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
args=sys.argv[1:];home=Path(os.environ['RA_TEST_SSH'])
user=args[args.index('-l')+1]
password=any(a.startswith('PreferredAuthentications=password') for a in args)
if password and 'PreferredAuthentications=password,keyboard-interactive' not in args:sys.exit(201)
payload=sys.stdin.read().replace('\r','')
with (home/'calls.jsonl').open('a') as f:f.write(json.dumps({'user':user,'password':password,'payload':payload,'args':args})+'\n')
if os.environ.get('RA_TEST_DENY')=='1':sys.exit(255)
if args[-1]=='true':sys.exit(0 if (home/'installed').exists() else 255)
if 'ra_user' in args[-1]:
 if not password and args[args.index('-i')+1]!=os.environ.get('RA_TEST_GOOD_KEY',''):sys.exit(255)
 if os.environ.get('RA_TEST_HELPER_FAIL')=='1':sys.stderr.write('useradd: cannot lock /etc/passwd\r\n');sys.exit(1)
 (home/'installed').touch();sys.exit(0)
sys.exit(0)
'@
Write-DiskUtf8 $fake $scriptText
& chmod +x $fake
$env:USERPROFILE=Join-Path $TestHome 'user';$env:RA_TEST_SSH=$TestHome;$env:PATH=$bin+[IO.Path]::PathSeparator+$env:PATH
$request=[pscustomobject]@{address='fixture.example.invalid';login='root';passwordPipe='fixture-memory-channel';askpassExecutable='fixture-askpass'}
$file=Connect-WizardServer $root $repo $request
$p=Read-TransportJson $file
Assert ($p.login -ceq 'remoteagents' -and $p.serverAddress -ceq $request.address) 'root bootstrap saves only worker profile'
Assert ((Read-TransportJson (Join-Path $root 'config.json')).transport.profilePath -ceq $file) 'one active profile selected explicitly'
Assert (Test-Path $p.keyPath) 'real local Ed25519 key generated'
$calls=@([IO.File]::ReadAllLines((Join-Path $TestHome 'calls.jsonl'))|ForEach-Object {ConvertFrom-Json $_})
Assert (@($calls|Where-Object {$_.password}).Count -eq 1) 'exactly one password SSH invocation'
$bootstrap=@($calls|Where-Object {$_.password})[0]
Assert ($bootstrap.user -ceq 'root' -and $bootstrap.payload.Contains('loginctl enable-linger') -and $bootstrap.payload.Contains('useradd -m')) 'one root call installs worker and linger'
Assert ($bootstrap.payload.Contains('grep -qxF') -and -not $bootstrap.payload.Contains("`r")) 'idempotent public key helper receives LF'
Assert (-not ([IO.File]::ReadAllText($file)).Contains('password')) 'profile contains no password or password pipe'
# Repeat with root input must use worker key and must not invoke password again.
$before=$calls.Count
[void](Connect-WizardServer $root $repo $request)
$calls=@([IO.File]::ReadAllLines((Join-Path $TestHome 'calls.jsonl'))|ForEach-Object {ConvertFrom-Json $_})
Assert ($calls.Count -eq $before+1 -and $calls[-1].user -ceq 'remoteagents' -and -not $calls[-1].password) 'repeat root onboarding needs only worker key'
# Broken changed server never commits a new active profile.
$previous=[IO.File]::ReadAllText((Join-Path $root 'config.json'));$env:RA_TEST_DENY='1'
$other=[pscustomobject]@{address='other.example.invalid';login='root';passwordPipe='fixture-memory-channel';askpassExecutable='fixture-askpass'}
Throws {Connect-WizardServer $root $repo $other} 'denied root password produces failure'
Assert ([IO.File]::ReadAllText((Join-Path $root 'config.json')) -ceq $previous) 'denied bootstrap preserves previous active server'
# Exit 255 is authentication/connection; any other code is the remote helper and is reported as such.
$helper='IFS= read -r ra_user; IFS= read -r ra_key; export ra_user ra_key; bash -s'
$message='';try{[void](Invoke-WizardLogin $p 'root' $helper "x`n" $request)}catch{$message=$_.Exception.Message}
Assert ($message -like '*Проверьте пароль*') 'ssh 255 is reported as a login failure'
$env:RA_TEST_DENY='0';$env:RA_TEST_HELPER_FAIL='1'
$message='';try{[void](Invoke-WizardLogin $p 'root' $helper "x`n" $request)}catch{$message=$_.Exception.Message}
Assert ($message -like '*код 1*' -and $message -like '*useradd*' -and $message -notlike '*Проверьте пароль*') 'remote helper failure is not reported as a wrong password'
$env:RA_TEST_HELPER_FAIL='0'
# Existing keys: candidates are ordered, deduplicated and exclude this profile's own key.
$keyHome=Join-Path $TestHome 'keys';$keyRoot=Join-Path $keyHome 'RemoteAgents';$sshDir=Join-Path $env:USERPROFILE '.ssh'
foreach($d in @($sshDir,(Join-Path $keyRoot 'ssh-profiles/a/project-connections/control'),(Join-Path $keyRoot 'ssh-profiles/b/project-connections/control'))){[void][IO.Directory]::CreateDirectory($d)}
Write-TransportJson (Join-Path $keyRoot 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
$keygen=@(Get-Command ssh-keygen -CommandType Application)[0].Source
foreach($k in @((Join-Path $sshDir 'id_rsa'),(Join-Path $sshDir 'id_ed25519'),(Join-Path $keyRoot 'ssh-profiles/a/project-connections/control/id_ed25519'),(Join-Path $keyRoot 'ssh-profiles/b/project-connections/control/id_ed25519'),(Join-Path $keyHome 'chosen'))){[void](Invoke-DiskProcess $keygen @('-q','-t','ed25519','-N','','-f',$k))}
[void](Invoke-DiskProcess $keygen @('-q','-t','ed25519','-N','fixture-passphrase','-f',(Join-Path $sshDir 'id_ecdsa')))
$own=Join-Path $keyRoot 'ssh-profiles/b/project-connections/control/id_ed25519';$chosen=Join-Path $keyHome 'chosen'
$order=@(Get-WizardKeyCandidates $keyRoot $own $chosen)
$expected=@($chosen,(Join-Path $sshDir 'id_ed25519'),(Join-Path $sshDir 'id_ecdsa'),(Join-Path $sshDir 'id_rsa'),(Join-Path $keyRoot 'ssh-profiles/a/project-connections/control/id_ed25519'))|ForEach-Object {[IO.Path]::GetFullPath($_)}
Assert (($order -join '|') -ceq ($expected -join '|')) 'key candidates: chosen file, ~/.ssh ed25519/ecdsa/rsa, other profiles; own key excluded'
Assert (@(Get-WizardKeyCandidates $keyRoot $own (Join-Path $sshDir 'id_rsa')).Count -eq 4 -and @(Get-WizardKeyCandidates $keyRoot $own (Join-Path $sshDir 'id_rsa'))[0] -ceq [IO.Path]::GetFullPath((Join-Path $sshDir 'id_rsa'))) 'chosen standard key is first and not duplicated'
Assert (@(Get-WizardKeyCandidates $keyRoot $own (Join-Path $keyHome 'absent')).Count -eq 4) 'missing files are skipped'
# A fresh PC: only the chosen key opens root; it is tried first, then the app uses only its own key.
$sshHome=Join-Path $keyHome 'ssh';[void][IO.Directory]::CreateDirectory($sshHome);$env:RA_TEST_SSH=$sshHome;$env:RA_TEST_GOOD_KEY=[IO.Path]::GetFullPath($chosen)
$script:WizardProgressFile=Join-Path $keyHome 'live.jsonl'
$keyRequest=[pscustomobject]@{address='keys.example.invalid';login='root';keyFile=($chosen+'.pub');passwordPipe=''}
$kfile=Connect-WizardServer $keyRoot $repo $keyRequest;$kp=Read-TransportJson $kfile
$kcalls=@([IO.File]::ReadAllLines((Join-Path $sshHome 'calls.jsonl'))|ForEach-Object {ConvertFrom-Json $_})
$tried=@($kcalls|ForEach-Object {$_.args[[array]::IndexOf([string[]]$_.args,'-i')+1]}|Where-Object {$_ -cne $kp.keyPath})
Assert ($tried.Count -eq 1 -and $tried[0] -ceq $env:RA_TEST_GOOD_KEY) 'chosen key file (given as .pub) is tried first and alone'
Assert (@($kcalls|Where-Object {$_.password}).Count -eq 0 -and $kcalls[-1].user -ceq 'remoteagents' -and $kcalls[-1].args -contains $kp.keyPath) 'existing key bootstraps without password; worker verified with own key'
$kc=@($kcalls|Where-Object {$_.args -contains $env:RA_TEST_GOOD_KEY})[0]
Assert ($kc.args -contains 'BatchMode=yes' -and $kc.args -contains 'IdentitiesOnly=yes' -and $kc.args -contains 'StrictHostKeyChecking=accept-new' -and $kc.payload.Contains((Get-Content -Raw ($kp.keyPath+'.pub')).Trim())) 'existing key installs the per-profile key in batch mode with accept-new'
$secret=[IO.File]::ReadAllText($chosen);$body=($secret -split "`n"|Where-Object {$_ -and $_ -notmatch '-----'}) -join ''
$live=[IO.File]::ReadAllText($script:WizardProgressFile)
Assert ($live.Contains('Пробую ключ '+$env:RA_TEST_GOOD_KEY.Replace('\','\\')) -and $live.Contains('✓')) 'live progress names the key path being tried'
foreach($f in @($script:WizardProgressFile,$kfile,(Join-Path $keyRoot 'config.json'))){$t=[IO.File]::ReadAllText($f);Assert (-not $t.Contains($body.Substring(0,40)) -and -not $t.Contains('PRIVATE KEY')) ('no key contents in '+(Split-Path $f -Leaf))}
Assert (-not ([IO.File]::ReadAllText($kfile)).Contains('chosen') -and $kp.keyPath -ceq (Join-Path (Split-Path $kfile -Parent) 'id_ed25519')) 'profile keeps only its own key'
# Nothing works and no password: every candidate is attempted, protected keys are skipped with a reason.
$env:RA_TEST_GOOD_KEY='';Remove-Item (Join-Path $sshHome 'installed')
$message='';try{[void](Connect-WizardServer $keyRoot $repo ([pscustomobject]@{address='keys2.example.invalid';login='root';passwordPipe=''}))}catch{$message=$_.Exception.Message}
Assert ($message -clike 'Ни один ключ не подошёл. Выберите файл ключа, которым вы входите на сервер, или введите пароль (если вход по паролю на сервере разрешён)') 'final error explains keys and password'
$live=[IO.File]::ReadAllText($script:WizardProgressFile)
Assert ($live.Contains('id_ecdsa… ✗ защищён паролем') -and $live.Contains('id_rsa… ✗ не подошёл')) 'passphrase key skipped with a clear message'
$env:RA_TEST_SSH=$TestHome;$script:WizardProgressFile=Join-Path $TestHome 'live.jsonl'
# The disk decision is asked only when a disk is installed.
[void][IO.Directory]::CreateDirectory((Join-Path $TestHome 'RemoteDisk/state'));Write-DiskUtf8 (Join-Path $TestHome 'RemoteDisk/state/config.xml') '<configuration/>'
[void](Connect-WizardServer $root $repo $other)
$c=Read-TransportJson (Join-Path $root 'config.json')
Assert ($c.wizard.diskPreviousProfile -ceq $file -and $c.wizard.pendingProfile -cne $file -and $c.transport.profilePath -ceq $file -and -not $c.wizard.configured) 'changed server records explicit disk decision and resets setup'
Assert ((Find-InstallProfile $root) -ceq $c.wizard.pendingProfile) 'wizard uses staged profile while active transport stays unchanged'
$noDisk=Join-Path $TestHome 'RemoteAgents-nodisk';[void][IO.Directory]::CreateDirectory($noDisk)
Write-TransportJson (Join-Path $noDisk 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
$saved=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $TestHome 'empty-local'
[void](Connect-WizardServer $noDisk $repo $request);[void](Connect-WizardServer $noDisk $repo $other)
$env:LOCALAPPDATA=$saved;$nd=Read-TransportJson (Join-Path $noDisk 'config.json')
Assert ($nd.wizard.pendingProfile -and -not $nd.wizard.diskPreviousProfile) 'server change without an installed disk asks no disk question'
# Explicit reconnect refuses non-empty data before stopping any process or touching old files.
$base=Join-Path $TestHome 'old-data';[void][IO.Directory]::CreateDirectory($base);Write-DiskUtf8 (Join-Path $base 'keep.txt') 'keep-local-files'
Throws {Resolve-WizardDiskServer $root $repo ([pscustomobject]@{base=$base;reconnect=$true})} 'nonempty disk cannot be silently merged into new server'
Assert ([IO.File]::ReadAllText((Join-Path $base 'keep.txt')) -ceq 'keep-local-files') 'refused reconnect preserves old local data'
# Real transport initialization reuses the explicit profile and the server's actual sync port.
$binary=Join-Path $TestHome 'fixture-sing-box.exe';Write-DiskUtf8 $binary 'fixture-only-not-executable'
$transport=[pscustomobject]@{singBoxPath=$binary}
function Send-WizardHelpers($Root,$Bundle){}
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){
    if($Command.StartsWith('test -r')){return "no`r`n"}
    if($Command.StartsWith('cat ')){return '{"listen":34567}' + "`r`n"}
    throw 'Unexpected initializer SSH request'
}
Initialize-WizardTransport $root $repo $transport
$channel=Read-TransportJson $transport.channelPath
Assert ($transport.profilePath -ceq $c.wizard.pendingProfile -and $channel.inbounds[0].override_port -eq 34567) 'fresh connection uses selected profile and actual server sync port'
Assert (@($channel.outbounds).Count -eq 0) 'clean server needs no fabricated VLESS endpoint or user value'
Assert ((Invoke-DiskProcess '/usr/bin/stat' @('-c','%a',$transport.channelPath)) -eq '600') 'channel material uses private permissions'
# The shared downloader/preflight are replaced only in this unit fixture.
$script:probes=0
function Get-WizardCatalog($Root,$Bundle){[pscustomobject]@{schema=1;entries=@();hops=@();relays=@();cdn=@()}}
function Initialize-WizardTransport($Root,$Bundle,$Transport){}
function Test-WizardNetworkManaged($Root){$false}
function Invoke-TransportPreflight($Root,$Bundle,$Config){$script:probes++;Assert ($Config.transport.profilePath -ceq $c.wizard.pendingProfile) 'new connection probes staged server'}
[void](Invoke-WizardStep $root $repo 'Connection' ([pscustomobject]@{catalog=(Get-WizardCatalog x x);shared=$false}))
$updated=Read-TransportJson (Join-Path $root 'config.json')
Assert ($script:probes -eq 1 -and -not $updated.wizard.pendingProfile -and $updated.transport.profilePath -ceq $c.wizard.pendingProfile) 'only verified connection commits new active server'
# CRLF .ovpn with adjacent references is converted to inline in memory only.
$ovpn=Join-Path $TestHome 'office.ovpn'
[IO.File]::WriteAllText((Join-Path $TestHome 'ca.crt'),"fixture-CA`r`n")
[IO.File]::WriteAllText((Join-Path $TestHome 'client.key'),"fixture-private-key`r`n")
[IO.File]::WriteAllText((Join-Path $TestHome 'auth.txt'),"fixture-user`r`nfixture-password`r`n")
[IO.File]::WriteAllText($ovpn,"client`r`nremote vpn.example.invalid 1194`r`nca ca.crt`r`nkey client.key`r`nauth-user-pass auth.txt`r`n")
$payload=Get-WizardLanPayload $ovpn
Assert ($payload.Contains('<ca>') -and $payload.Contains('<key>') -and $payload.Contains('<auth-user-pass>') -and -not $payload.Contains("`r")) 'external files resolved with CRLF normalization'
$script:uploads=New-Object Collections.ArrayList
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){Assert ($Command -eq 'bash -s' -and -not $InputText.Contains("`r")) 'upload via existing SSH profile with LF';[void]$script:uploads.Add($InputText)}
$r=Send-WizardLan $root $repo $ovpn
Assert ($r.ok -and $r.command.Contains('sudo bash') -and $r.command.Contains('profile.ovpn') -and $r.command.Contains('--ip-check-url')) 'upload returns executable administrator command with explicit required URL'
$r2=Send-WizardLan $root $repo $ovpn
Assert ($r.command -ceq $r2.command) 'same filename maps to same destination without duplicate LAN'
Assert ($script:uploads[0].Contains('chmod 700') -and $script:uploads[0].Contains('chmod 600') -and $script:uploads[0].Contains('mv -f')) 'upload restricts permissions and replaces atomically'
$receipt=[IO.File]::ReadAllText((Join-Path $root 'state/lan-upload.json'))
Assert (-not $receipt.Contains('fixture-private-key') -and -not $receipt.Contains('fixture-password')) 'receipt contains no secrets'
# Actually execute generated upload in isolated HOME; no network/root/OpenVPN is involved.
$uploadFile=Join-Path $TestHome 'upload.sh';$remote=Join-Path $TestHome 'fake-remote';[void][IO.Directory]::CreateDirectory($remote)
Write-DiskUtf8 $uploadFile $script:uploads[0]
# HOME belongs only to this isolated child, never change the agent environment.
[void](Invoke-DiskProcess '/usr/bin/env' @(('HOME='+$remote),'bash',$uploadFile))
$name=(Read-TransportJson (Join-Path $root 'state/lan-upload.json')).name
$uploaded=Join-Path $remote ('.config/remoteagents/lan/'+$name+'/profile.ovpn')
Assert ([IO.File]::ReadAllText($uploaded) -ceq $payload) 'production upload delivers complete inline profile'
Assert ((Invoke-DiskProcess '/usr/bin/stat' @('-c','%a',$uploaded)) -eq '600') 'uploaded secret mode 600'
Assert ((Invoke-DiskProcess '/usr/bin/stat' @('-c','%a',(Split-Path $uploaded -Parent))) -eq '700') 'uploaded directory mode 700'
[IO.File]::WriteAllText($ovpn,"ca absent.crt`r`n")
Throws {Send-WizardLan $root $repo $ovpn} 'missing adjacent file fails before SSH'
Assert ($script:uploads.Count -eq 2) 'invalid profile never partially uploads'
[IO.File]::WriteAllText($ovpn,"key ../outside.key`r`n")
Throws {Get-WizardLanPayload $ovpn} 'path traversal rejected'
[IO.File]::WriteAllText($ovpn,"auth-user-pass`r`n")
Assert ((Get-WizardLanPayload $ovpn).Trim() -ceq "auth-user-pass") 'interactive credentials kept for the window to ask (stored root-only on the server)'
Write-Output ('OK: '+$count+' onboarding/LAN checks (fake SSH, real keygen and isolated bash, no Windows)')
