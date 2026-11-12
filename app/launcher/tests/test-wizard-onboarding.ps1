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
pc=[a for a in args if a.startswith('ProxyCommand=')]
kind='direct' if not pc else (('hoppw' if 'PubkeyAuthentication=no' in pc[0] else 'hop') if ' -W ' in pc[0] else 'proxy')
import time
wait=dict(x.split(':') for x in os.environ.get('RA_TEST_DELAY','').split(',') if x)
if kind in wait:time.sleep(float(wait[kind]))
if kind in os.environ.get('RA_TEST_HANG','').split(','):
 with (home/'hang.pids').open('a') as f:f.write(str(os.getpid())+'\n')
 time.sleep(120)
if kind in os.environ.get('RA_TEST_BLOCK','').split(','):sys.stderr.write('Connection timed out during banner exchange\r\n');sys.exit(255)
if os.environ.get('RA_TEST_DENY')=='1':sys.exit(255)
if args[-1]=='true':
 if (home/'installed').exists():sys.exit(0)
 sys.stderr.write('remoteagents@x: Permission denied (publickey).\r\n');sys.exit(255)
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
# Routes: direct, local proxy (exe relay), SSH hop. All are probed at once; the first in that order that reaches SSH wins.
$routeHome=Join-Path $TestHome 'routes';[void][IO.Directory]::CreateDirectory($routeHome);$env:RA_TEST_GOOD_KEY=[IO.Path]::GetFullPath($chosen)
$hopKey=Join-Path $keyHome 'hopkey';[void](Invoke-DiskProcess $keygen @('-q','-t','ed25519','-N','','-f',$hopKey))
$hopBody=(([IO.File]::ReadAllText($hopKey)) -split "`n"|Where-Object {$_ -and $_ -notmatch '-----'}) -join ''
function New-RouteRoot([string]$Name){
    $r=Join-Path $routeHome $Name;[void][IO.Directory]::CreateDirectory($r);Write-TransportJson (Join-Path $r 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
    $d=Join-Path $routeHome ($Name+'-ssh');[void][IO.Directory]::CreateDirectory($d);$env:RA_TEST_SSH=$d;$script:WizardProgressFile=Join-Path $d 'live.jsonl';$r
}
function Get-RouteCalls{@([IO.File]::ReadAllLines((Join-Path $env:RA_TEST_SSH 'calls.jsonl'))|ForEach-Object {ConvertFrom-Json $_})}
function Get-ProxyOption($Call){@($Call.args|Where-Object {$_ -like 'ProxyCommand=*'})}
$proxy=[pscustomobject]@{type='socks';host='127.0.0.1';port=10808}
$hop=[pscustomobject]@{name='jump';ssh='jumper@hop.example.invalid:2222';keyFile=$hopKey}
$askpass=Join-Path $routeHome 'Program Files/RemoteAgents/RemoteAgents.exe';[void][IO.Directory]::CreateDirectory((Split-Path $askpass -Parent));Write-DiskUtf8 $askpass 'fixture-only'
$base=@{login='root';keyFile=$chosen;passwordPipe='';askpassExecutable=$askpass}
# 1. Direct is blocked, the proxy works.
$rr=New-RouteRoot 'proxy';$env:RA_TEST_BLOCK='direct'
$f=Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route1.example.invalid';proxy=$proxy}))
$rc=Get-RouteCalls;$live=[IO.File]::ReadAllText($script:WizardProgressFile)
$dc=@($rc|Where-Object {(Get-ProxyOption $_).Count -eq 0})
Assert ($dc.Count -eq 1 -and $dc[0].args -contains 'ConnectTimeout=8') 'direct is probed with a short connect timeout'
$po=@(Get-ProxyOption @($rc|Where-Object {(Get-ProxyOption $_).Count -eq 1})[0])
Assert ($po.Count -eq 1 -and $po[0].Contains('--proxy-connect socks 127.0.0.1 10808 %h %p') -and $po[0].Contains('RemoteAgents.exe')) 'proxy route passes the relay with host, port and %h %p to ssh'
Assert ($live.Contains('напрямую… ✗') -and $live.Contains('через локальный прокси 127.0.0.1:10808… ✓')) 'live progress shows direct failing and the proxy working'
Assert (@($rc|Where-Object {(Get-ProxyOption $_).Count -eq 0}).Count -eq 1 -and @($rc|Where-Object {$_.user -ceq 'remoteagents' -and (Get-ProxyOption $_).Count -eq 1}).Count -ge 2) 'direct is not retried after a proxy success; later calls use the proxy'
$text=[IO.File]::ReadAllText($f);Assert (-not $text.Contains('ProxyCommand') -and -not $text.Contains('10808') -and -not $text.Contains('proxy-connect')) 'saved profile does not bake in the proxy'
$cfg=Read-TransportJson (Join-Path $rr 'config.json')
Assert ($cfg.wizard.serverRoute.used -ceq 'proxy' -and $cfg.wizard.serverRoute.proxy.host -ceq '127.0.0.1' -and $cfg.wizard.serverRoute.proxy.port -eq 10808 -and $cfg.wizard.serverRoute.proxy.type -ceq 'socks') 'working route and proxy fields are saved for prefill'
# 2. Direct and proxy are blocked, the SSH hop works; its key is only a path.
$rr=New-RouteRoot 'hop';$env:RA_TEST_BLOCK='direct,proxy'
$f=Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route2.example.invalid';proxy=$proxy;hop=$hop}))
$rc=Get-RouteCalls;$live=[IO.File]::ReadAllText($script:WizardProgressFile)
$last=@(Get-ProxyOption $rc[-1])
Assert ($last.Count -eq 1 -and $last[0].Contains('-W %h:%p') -and $last[0].Contains('-l jumper') -and $last[0].Contains('-p 2222') -and $last[0].Contains('hop.example.invalid') -and $last[0].Contains('IdentitiesOnly=yes') -and $last[0].Contains($hopKey)) 'hop route is a pass-through ssh -W with its own login, port and key file'
Assert ($rc[-1].args -contains $env:RA_TEST_GOOD_KEY -or $rc[-1].args[[array]::IndexOf([string[]]$rc[-1].args,'-i')+1] -ceq (Read-TransportJson $f).keyPath) 'the final login to the target still uses the target key, not the hop key'
Assert ($live.Contains('напрямую… ✗') -and $live.Contains('прокси 127.0.0.1:10808… ✗') -and $live.Contains('промежуточный сервер jumper@hop.example.invalid:2222… ✓')) 'direct failure leads to the next route, then the hop'
foreach($t in @($live,[IO.File]::ReadAllText($f),[IO.File]::ReadAllText((Join-Path $rr 'config.json')))){Assert (-not $t.Contains($hopBody.Substring(0,40)) -and -not $t.Contains('PRIVATE KEY') -and -not $t.Contains('ProxyCommand')) 'hop key contents and route options are not logged or saved'}
$cfg=Read-TransportJson (Join-Path $rr 'config.json')
Assert ($cfg.wizard.serverRoute.used -ceq 'hop' -and $cfg.wizard.serverRoute.hop.name -ceq 'jump' -and $cfg.wizard.serverRoute.hop.ssh -ceq 'jumper@hop.example.invalid:2222' -and $cfg.wizard.serverRoute.hop.keyFile -ceq $hopKey) 'hop saved with transport hops[] names (name, ssh) and key path'
# A known_hosts file may contain several hops; save the selected endpoint's pinned key.
$knownHop=Join-Path (Split-Path (Read-TransportJson $f).keyPath -Parent) 'known_hosts-hop'
$hopPub=((Convert-TransportLF ([IO.File]::ReadAllText($hopKey+'.pub'))).Trim() -split '\s+')[0..1] -join ' '
Write-DiskUtf8 $knownHop ("unrelated.example.invalid ssh-ed25519 Zml4dHVyZQ==`r`n[hop.example.invalid]:2222 "+$hopPub+"`r`n")
Save-WizardRoute $rr ([pscustomobject]@{hop=$hop}) (Read-TransportJson $f)
Assert ((Read-TransportJson (Join-Path $rr 'config.json')).wizard.serverRoute.hop.hostKey -ceq $hopPub) 'saved hop host key belongs to selected host and port, not first known_hosts line'
# 2b. Hop key rejected/unreachable, password route works: the password exists only as a pipe name, in a hop-only environment.
$rr=New-RouteRoot 'hoppw';$env:RA_TEST_BLOCK='direct,hop'
$pipeName='RemoteAgents.Password.'+[guid]::NewGuid().ToString('N');$secret='hop-secret-password-value'
$f=Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route2b.example.invalid';hop=[pscustomobject]@{name='jump';ssh='jumper@hop.example.invalid';keyFile=$hopKey;passwordPipe=$pipeName}}))
$rc=Get-RouteCalls;$live=[IO.File]::ReadAllText($script:WizardProgressFile);$last=@(Get-ProxyOption $rc[-1])
$hopCalls=@($rc|Where-Object {(Get-ProxyOption $_).Count -eq 1})
$keyHop=@($hopCalls|ForEach-Object {@(Get-ProxyOption $_)[0]}|Where-Object {-not $_.Contains('PubkeyAuthentication=no')})
Assert ($keyHop.Count -ge 1 -and $keyHop[0].Contains($hopKey) -and $keyHop[0].Contains('BatchMode=yes')) 'key hop route is probed besides the password route'
Assert ($last[0].Contains('PubkeyAuthentication=no') -and $last[0].Contains('PreferredAuthentications=password,keyboard-interactive') -and $last[0].Contains('BatchMode=no') -and $last[0].Contains('REMOTEAGENTS_PASSWORD_PIPE='+$pipeName) -and $last[0].Contains('SSH_ASKPASS_REQUIRE=force') -and $last[0].Contains('SSH_ASKPASS='+$askpass)) 'password hop route asks the askpass relay through its own pipe, set only for the inner ssh'
Assert ($live.Contains('(пароль)… ✓')) 'password hop route is reported working'
foreach($t in @($live,[IO.File]::ReadAllText($f),[IO.File]::ReadAllText((Join-Path $rr 'config.json')))){Assert (-not $t.Contains($secret) -and -not $t.Contains($pipeName)) 'hop password and pipe name never in progress, profile or config'}
Assert (-not ([IO.File]::ReadAllText((Join-Path $env:RA_TEST_SSH 'calls.jsonl'))).Contains($secret)) 'hop password never on a command line'
Assert (-not ([IO.File]::ReadAllText((Join-Path $rr 'config.json'))).Contains('passwordPipe') -and (Read-TransportJson (Join-Path $rr 'config.json')).wizard.serverRoute.hop.ssh -ceq 'jumper@hop.example.invalid') 'only non-secret hop fields are remembered'
Throws {Connect-WizardServer (New-RouteRoot 'badpipe') $repo ([pscustomobject]($base+@{address='route2c.example.invalid';hop=[pscustomobject]@{ssh='jumper@hop.example.invalid';passwordPipe='x" & calc'}}))} 'malformed pipe name is rejected'
# 3. Hop key falls back to the standard keys of this user when no file is chosen.
$rr=New-RouteRoot 'hopdefault';$env:RA_TEST_BLOCK='direct'
[void](Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route3.example.invalid';hop=[pscustomobject]@{ssh='hop.example.invalid'}})))
$std=Join-Path $sshDir 'id_ed25519';$po=@(Get-ProxyOption (Get-RouteCalls)[-1])
Assert ($po[0].Contains($std) -and -not $po[0].Contains('-l ')) 'hop without a chosen key uses ~/.ssh keys; login is optional'
# 4. Nothing reaches the server.
$rr=New-RouteRoot 'none';$env:RA_TEST_BLOCK='direct,proxy,hop';$message=''
try{[void](Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route4.example.invalid';proxy=$proxy;hop=$hop})))}catch{$message=$_.Exception.Message}
Assert ($message -like 'Сервер не ответил по SSH ни одним из способов*') 'all routes failing is reported honestly'
Assert ($message.Contains('TUN') -and $message.Contains('«Повторить»') -and $message.Contains('«смешанный»') -and $message.Contains('Локальный прокси')) 'all-failed message offers an enabled TUN VPN, Повторить and explains mixed mode'
Assert (-not (Get-ChildItem $rr -Recurse -Filter ssh-transport.json) -and -not (Read-TransportJson (Join-Path $rr 'config.json')).wizard) 'failed routes save nothing'
# 4b. Parallel probes: silent direct and proxy cost one timeout in total, not one each; the working hop wins and the rest are killed.
$script:WizardProbeTimeout=8
$rr=New-RouteRoot 'parallel';$env:RA_TEST_BLOCK='';$env:RA_TEST_HANG='direct,proxy';$watch=[Diagnostics.Stopwatch]::StartNew()
[void](Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route7.example.invalid';proxy=$proxy;hop=$hop})))
$watch.Stop();$live=[IO.File]::ReadAllText($script:WizardProgressFile)
Assert ((Read-TransportJson (Join-Path $rr 'config.json')).wizard.serverRoute.used -ceq 'hop') 'silent direct and proxy, working hop: the hop is chosen'
Assert ($watch.Elapsed.TotalSeconds -lt $script:WizardProbeTimeout) ('hop chosen within one probe timeout, not the sum of timeouts: '+[int]$watch.Elapsed.TotalSeconds+' s')
Assert ($live.Contains('напрямую… не дождался') -and $live.Contains('10808… не дождался') -and $live.Contains('jumper@hop.example.invalid:2222… ✓')) 'one line per route; unanswered routes are reported as stopped'
$hung=@([IO.File]::ReadAllLines((Join-Path $env:RA_TEST_SSH 'hang.pids'))|Where-Object {$_})
Assert ($hung.Count -eq 2 -and -not @($hung|Where-Object {Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue})) 'unfinished probe processes are killed after the choice'
# 4c. Direct and hop both work: direct wins although it answers after the hop (within the grace period).
$rr=New-RouteRoot 'both';$env:RA_TEST_HANG='';$env:RA_TEST_DELAY='direct:1'
[void](Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route8.example.invalid';hop=$hop})))
Assert ((Read-TransportJson (Join-Path $rr 'config.json')).wizard.serverRoute.used -ceq 'direct') 'direct and hop both alive: direct is chosen'
# 4d. Nothing answers: the same clear error, after one timeout rather than one per route.
$rr=New-RouteRoot 'silent';$env:RA_TEST_DELAY='';$env:RA_TEST_HANG='direct,proxy,hop';$message='';$watch=[Diagnostics.Stopwatch]::StartNew()
try{[void](Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route9.example.invalid';proxy=$proxy;hop=$hop})))}catch{$message=$_.Exception.Message}
$watch.Stop();$live=[IO.File]::ReadAllText($script:WizardProgressFile)
Assert ($message -like 'Сервер не ответил по SSH ни одним из способов*' -and $live.Contains('напрямую… ✗ нет ответа за 8 с')) 'all routes silent: the existing clear error, each route marked'
Assert ($watch.Elapsed.TotalSeconds -lt 1.5*$script:WizardProbeTimeout) ('all routes silent: one timeout in total, not three: '+[int]$watch.Elapsed.TotalSeconds+' s')
$env:RA_TEST_HANG='';$script:WizardProbeTimeout=30
# 5. Direct only, blocked by DPI: the provider message; a real key rejection keeps the key message.
$rr=New-RouteRoot 'direct';$env:RA_TEST_BLOCK='direct';$message=''
try{[void](Connect-WizardServer $rr $repo ([pscustomobject]($base+@{address='route5.example.invalid'})))}catch{$message=$_.Exception.Message}
Assert ($message -clike 'Сервер не ответил по SSH: похоже, провайдер блокирует прямое подключение.*Happ*') 'no banner on direct: provider-blocking message instead of the key message'
Assert ($message.Contains('TUN') -and $message.Contains('«Повторить»') -and $message.Contains('смешанный')) 'provider message offers TUN VPN and Повторить and explains mixed mode'
$rr=New-RouteRoot 'denied';$env:RA_TEST_BLOCK='';$env:RA_TEST_GOOD_KEY='';$message=''
try{[void](Connect-WizardServer $rr $repo ([pscustomobject]@{address='route6.example.invalid';login='root';passwordPipe='';askpassExecutable='x'}))}catch{$message=$_.Exception.Message}
Assert ($message -clike 'Ни один ключ не подошёл*') ('Permission denied keeps the key message: '+$message)
$env:RA_TEST_BLOCK='';$env:RA_TEST_SSH=$TestHome;$script:WizardProgressFile=Join-Path $TestHome 'live.jsonl'
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
Assert (-not $transport.PSObject.Properties['serverRoute']) 'direct initialization adds no personal transport overlay'
Assert (@($channel.outbounds).Count -eq 0) 'clean server needs no fabricated VLESS endpoint or user value'
Assert ((Invoke-DiskProcess '/usr/bin/stat' @('-c','%a',$transport.channelPath)) -eq '600') 'channel material uses private permissions'
$personalConfig=Read-TransportJson (Join-Path $root 'config.json')
$personalConfig.wizard|Add-Member -Force serverRoute ([pscustomobject]@{used='hop';hop=[pscustomobject]@{ssh='jumper@hop.example.invalid:2207';keyFile=$hopKey}})
Write-TransportJson (Join-Path $root 'config.json') $personalConfig
Initialize-WizardTransport $root $repo $transport
Assert ($transport.serverRoute.used -eq 'hop' -and $transport.serverRoute.hop.keyFile -eq $hopKey) 'initializer places personal hop in local transport for isolated preflight'
$personalConfig.wizard.serverRoute=[pscustomobject]@{used='proxy';proxy=$proxy}
Write-TransportJson (Join-Path $root 'config.json') $personalConfig
Initialize-WizardTransport $root $repo $transport
Assert ($transport.serverRoute.used -eq 'proxy' -and $transport.serverRoute.proxyExecutable -eq (Join-Path $root 'RemoteAgents.exe')) 'proxy overlay keeps installed exe path when preflight runs in a temporary home'
$personalConfig.wizard.serverRoute=[pscustomobject]@{used='direct'}
Write-TransportJson (Join-Path $root 'config.json') $personalConfig
Initialize-WizardTransport $root $repo $transport
Assert (-not $transport.PSObject.Properties['serverRoute']) 'switching to direct removes previous personal overlay'
# The shared downloader/preflight are replaced only in this unit fixture.
$script:probes=0
function Get-WizardCatalog($Root,$Bundle){[pscustomobject]@{schema=1;entries=@();hops=@();relays=@();cdn=@()}}
function Initialize-WizardTransport($Root,$Bundle,$Transport){}
function Test-WizardNetworkManaged($Root){$false}
function Invoke-TransportPreflight($Root,$Bundle,$Config){throw 'fresh setup must not run a duplicate isolated preflight'}
function Start-WizardWorkingTransport($Root,$Bundle){}
function Wait-WizardWorkingProof($Root,$Mark){$script:probes++;Assert ((Read-TransportJson (Join-Path $Root 'config.json')).transport.profilePath -ceq $c.wizard.pendingProfile) 'working transport proves staged server'}
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
