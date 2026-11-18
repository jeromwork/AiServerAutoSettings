#requires -Version 5.1
# One reconciler for all server sections. All root payloads and secrets travel on stdin.
function Get-WizardApplyMode([string]$Root,$Request) {
    $p=Read-TransportJson (Find-InstallProfile $Root)
    if($p.login -ceq 'root'){return 'profile'}
    try{[void](Invoke-WizardSsh $Root 'sudo -n true');return 'sudo'}catch{}
    try{[void](Invoke-WizardSsh $Root 'sudo -n -l -- /usr/local/lib/remoteagents/server/server-apply.sh >/dev/null');return 'delegated'}catch{}
    if($Request.mode -and $Request.mode -ne 'command'){return [string]$Request.mode}
    return Get-WizardAdminMode $Root $Request
}
function Get-WizardApplyFiles([string]$Bundle) {
    $names=@('server_apply.py','server-apply.sh','base_network.py','lan_share.py','server_recovery.py','server_components.py','server_packages.py','component_files.py','happier-web.schema.json','happier_web.py','happier_web_common.py','happier_web_release.py','happier_web_quotas.py','agy_usage_scrape.py','happier_web_settings.cjs','happier_web_verify.cjs','happier_web_addon.js','lan_vpn.py','lan-vpn.sh','lan-config.schema.json','proxy_out.py','proxy-out.sh','remoteagents_config.py')
    $body=Get-WizardNetFiles $Bundle $names
    $body+='mkdir -p "$d/tg-gateway"'+"`n"
    foreach($name in @('config.paste.schema.json','tg-gateway/gateway.py','tg-gateway/tg_gateway_keys.py','tg-gateway/tg_gateway_setup.py','tg-gateway/install.sh','tg-gateway/README.md')){
        $path=if($name -eq 'config.paste.schema.json'){$(if(Test-Path (Join-Path $Bundle 'server/config.paste.schema.json')){Join-Path $Bundle 'server/config.paste.schema.json'}else{Join-Path $Bundle 'app/launcher/config.paste.schema.json'})}else{Join-Path $Bundle ('server/'+$name)}
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText($path))))
        $body+='printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "$d/'+$name+'"'+"`n"
    }
    $body+='mkdir -p "$d/assets/disk"'+"`n"
    foreach($name in @('disk/server-disk.sh','disk/stignore.txt','codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py','server-codex-v1.sh','server-claude-code.sh','server-agent-handoff.py','server-desktop-bootstrap.sh','close-idle-chats.py')){
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle $name)))))
        $body+='printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "$d/assets/'+$name+'"'+"`n"
    }
    return $body
}
function Invoke-WizardApplyCommand([string]$Root,[string]$Bundle,$Request,[string]$Mode,[string]$Command,[string]$Payload,[bool]$Confirm=$false) {
    $args=$Command+' --json'+$(if($Confirm){' --confirm-ssh-checked'}else{''})
    # The delegated rule authorizes only the installed root-owned entry point.
    if($Mode -eq 'delegated'){
        $p=Read-TransportJson (Find-InstallProfile $Root)
        $text=Invoke-DiskProcess $p.sshExecutable ((Get-WizardNetArgs $p ([string]$p.login) $Root)+@('-o','BatchMode=yes',$p.serverAddress,('sudo -n -- /usr/local/lib/remoteagents/server/server-apply.sh '+$args+'; exit 0'))) $Payload -TimeoutSeconds 900
    }else{
        $end='RA_APPLY_'+[guid]::NewGuid().ToString('N')
        $script=(Get-WizardApplyFiles $Bundle)+'set +e'+"`n"+'python3 -I "$d/server_apply.py" '+$args+" <<'"+$end+"'`n"+$Payload+"`n"+$end+"`n"+'rc=$?'+"`n"+'test "$rc" -le 1'+"`n"
        # apply returns 1 for pending/blocked: retain its structured report for the UI.
        if($Mode -eq 'sudo'){
            $p=Read-TransportJson (Find-InstallProfile $Root)
            $text=Invoke-DiskProcess $p.sshExecutable ((Get-WizardNetArgs $p ([string]$p.login) $Root)+@('-o','BatchMode=yes',$p.serverAddress,'sudo -n bash -s')) $script -TimeoutSeconds 900
        }else{$text=Invoke-WizardAdmin $Root $Request $Mode $script 900}
    }
    try{$result=ConvertFrom-Json (Convert-TransportLF $text)}catch{throw 'Сервер вернул неверный отчёт развёртывания; таймер отката сохраняется'}
    if(-not $result.parts){throw 'Сервер не смог прочитать конфиг; проверьте схему и доступность установленного server-apply'}
    foreach($part in @($result.parts)){Write-WizardProgress ($part.part+': '+$part.state+' — '+$part.summary)}
    return $result
}
function Get-WizardApplyPorts($Config) {
    $ports=@([int]$(if($Config.server.port){$Config.server.port}else{22}))+@($Config.serverNetwork.inboundPorts|Where-Object {$null -ne $_})
    return @($ports|Select-Object -Unique)
}
function Test-WizardApplyPorts($Config) {
    foreach($port in @(Get-WizardApplyPorts $Config)){
        $client=New-Object Net.Sockets.TcpClient
        try{
            $task=$client.ConnectAsync([string]$Config.server.address,[int]$port)
            if(-not $task.Wait(10000) -or -not $client.Connected){throw 'Порт не отвечает'}
        }catch{throw ('Новое входящее соединение на порт '+$port+' не прошло; подтверждение отменено, сработает автооткат')}
        finally{$client.Dispose()}
    }
}
function Invoke-WizardServerApply([string]$Root,[string]$Bundle,$Request) {
    $config=$Request.config
    if(-not $config -or $config.kind -cne 'remoteagents-config'){throw 'Нужен единый конфиг программы'}
    $mode=Get-WizardApplyMode $Root $Request
    if($mode -eq 'command'){
        $blocked=@{ok=$false;parts=@(@{part='agent';state='blocked';summary='Нет root/sudo для автоматического развёртывания; нужен пароль root в server.rootPassword'});actions=@();summary='Нет прав на настройку сервера'}
        Write-TransportJson (Join-Path $Root 'state/server-apply.json') $blocked
        return $blocked
    }
    $values='{}';if($Request.secretPipe){$values=Read-WizardRelay ([string]$Request.secretPipe)}
    $payload=(ConvertTo-Json $config -Depth 80 -Compress)+"`n"+$script:WizardNetMarker+"`n"+$values+"`n"
    return Invoke-WizardServerApplyPayload $Root $Bundle $Request $mode $payload
}
function Invoke-WizardServerApplyPayload([string]$Root,[string]$Bundle,$Request,[string]$Mode,[string]$Payload) {
    $config=$Request.config
    $verb=if($Request.statusOnly){'status'}else{'plan'}
    $actions=@()
    $result=Invoke-WizardApplyCommand $Root $Bundle $Request $mode $verb $payload
    if(-not $Request.statusOnly -and -not $result.ok){
        # A missing secret/invalid configuration is reviewable and requires no mutation.
        $canApply=@($result.parts|Where-Object {$_.state -in @('change','pending')}).Count -gt 0
        if($canApply){
            $confirm=$false
            for($attempt=0;$attempt -lt 68;$attempt++){
                $result=Invoke-WizardApplyCommand $Root $Bundle $Request $mode 'apply' $payload $confirm
                $actions+=@($result.actions)
                if(-not @($result.parts|Where-Object {$_.state -eq 'pending'}).Count){break}
                # Each command below creates a new SSH process, with multiplexing disabled.
                # Check every declared public TCP entrance before that NEW session confirms.
                Test-WizardApplyPorts $config
                $confirm=$true
            }
        }
    }
    $result|Add-Member -Force actions $actions
    $result|Add-Member -Force summary ((@($result.parts|ForEach-Object {$_.part+': '+$_.state+' — '+$_.summary})) -join '; ')
    Write-TransportJson (Join-Path $Root 'state/server-apply.json') $result
    return $result
}
