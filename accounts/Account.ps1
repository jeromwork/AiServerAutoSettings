#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[string]$ExpectedAccount,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
# Redirected diagnostics must preserve Russian on Windows PowerShell 5.1 too.
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'build/Process.Common.ps1')
function Connect-HappierAccount([string]$Root) {
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'logs'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'state'))
    Write-DiskUtf8 (Join-Path $Root 'state/happier-account.json') '{"schema":1,"ok":false,"summary":"Проверка аккаунта"}'
    [IO.File]::AppendAllText((Join-Path $Root 'logs/accounts.log'),([DateTime]::UtcNow.ToString('o')+" account.check`n"))
    Read-DiskProfile
    $keyFile=Join-Path $Root 'secrets/happier-account.key'
    if(-not (Test-Path -LiteralPath $keyFile)){throw 'Выберите или создайте аккаунт в RemoteAgents'}
    $key=[IO.File]::ReadAllText($keyFile).Trim()
    # The key goes only through SSH stdin. Never argv, log or exception details.
    $upload='set -eu; umask 077; mkdir -p "$HOME/.local/share/remoteagents-accounts"' + "`n"
    foreach($name in @('server-account.mjs','bootstrap.sh')){
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r",'')
        $remote='$HOME/.local/share/remoteagents-accounts/'+$name;$temp=$remote+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        $upload+='printf %s '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))+' | base64 -d > "'+$temp+'"; mv -f -- "'+$temp+'" "'+$remote+'"'+"`n"
    }
    # Happier itself is installed by the detached server operation (server-wizard.sh start happier),
    # never inside this short call.
    $installed=Invoke-DiskSsh 'bash -s' -InputText ($upload+'if test -x "$HOME/.local/bin/happier" && systemctl --user show-environment >/dev/null 2>&1; then echo installed; fi') -TimeoutSeconds 60
    if(([string]$installed).Replace("`r",'').Trim() -cne 'installed'){throw 'Happier на сервере ещё не установлен'}
    $settings=@{serverUrl='';webappUrl='';label=''}
    $config=Join-Path $Root 'config.json'
    if(Test-Path -LiteralPath $config){$c=[IO.File]::ReadAllText($config)|ConvertFrom-Json;foreach($k in @('serverUrl','webappUrl','label')){if($c.happier.$k){$settings[$k]=[string]$c.happier.$k}}}
    if(-not $settings.serverUrl -or -not $settings.webappUrl){throw 'Укажите адреса Happier в настройках или на своём сервере'}
    $request=@{expectedAccount=$ExpectedAccount;key=$key;serverUrl=$settings.serverUrl;webappUrl=$settings.webappUrl;label=$settings.label}|ConvertTo-Json -Compress
    $result=(Invoke-DiskSsh 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; export XDG_RUNTIME_DIR="/run/user/$(id -u)"; export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"; flock -w 60 "$HOME/.local/share/remoteagents-accounts/accounts.lock" node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' -InputText $request -TimeoutSeconds 180).Replace("`r",'')|ConvertFrom-Json
    if(-not $result.ok -or $result.account -cnotmatch '^[a-f0-9]{64}$'){throw 'Аккаунт не подтверждён'}
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'state'))
    $result|Add-Member updatedUtc ([DateTime]::UtcNow.ToString('o'))
    [IO.File]::AppendAllText((Join-Path $Root 'logs/accounts.log'),([DateTime]::UtcNow.ToString('o')+" account.verified`n"))
    Write-DiskUtf8 (Join-Path $Root 'state/happier-account.json') ($result|ConvertTo-Json -Compress)
}
if($LibraryOnly){return}
try{Connect-HappierAccount $LauncherHome}catch{
    # Own messages and Invoke-DiskProcess errors contain no key; do not print InvocationInfo/stdin.
    $reason='Happier: '+[string]$_.Exception.Message
    if(Test-Path -LiteralPath (Join-Path $LauncherHome 'logs')){[IO.File]::AppendAllText((Join-Path $LauncherHome 'logs/accounts.log'),([DateTime]::UtcNow.ToString('o')+' account.failed '+$reason+"`n"))}
    [Console]::Error.WriteLine($reason);exit 1
}
