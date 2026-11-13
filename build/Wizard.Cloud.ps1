#requires -Version 5.1
# Dedicated capture: cloud stdin/stderr must never enter SSH trace logs.
# Executor is replaceable in PS tests; profile/routes use the existing wizard contract.
function Invoke-WizardCloudProcess($Profile,$Options,[string]$Command,[string]$InputText) {
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Profile.sshExecutable
    $si.Arguments=((@($Options)+@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5')+@($Profile.arguments)+@($Command))|ForEach-Object {Quote-Disk ([string]$_)}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$si.StandardErrorEncoding=$si.StandardOutputEncoding
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try {
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF $InputText))
        $send=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $send.Wait(180000)){throw 'Таймаут отправки настроек облака'}
        $p.StandardInput.Close()
        if(-not $p.WaitForExit(180000)){throw 'Таймаут настройки облака'}
        return @{exitCode=$p.ExitCode;stdout=(Convert-TransportLF $out.GetAwaiter().GetResult());stderr=(Convert-TransportLF $err.GetAwaiter().GetResult())}
    } finally {if($p.Id -and -not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Invoke-WizardCloud([string]$Root,$Request) {
    $inputText=Read-WizardRelay ([string]$Request.secretPipe)
    $secret=[string](ConvertFrom-Json $inputText).password
    try {
        $profile=Read-TransportJson (Find-InstallProfile $Root)
        $options=@(Get-TransportSavedRouteOptions $Root $profile)
        $result=Invoke-WizardCloudProcess $profile $options 'bash "$HOME/.local/share/remoteagents-cloud/server-cloud.sh" apply' $inputText
        # Only confirmation and the first error line cross the request boundary. Never retain raw output.
        $ok=$false
        try{$answer=ConvertFrom-Json (Convert-TransportLF ([string]$result.stdout));$ok=($result.exitCode -eq 0 -and $answer.ok -is [bool] -and $answer.ok)}catch{}
        $reason=((Convert-TransportLF ([string]$result.stderr)) -split "`n")[0]
        if($secret){$encoded=ConvertTo-Json -InputObject $secret -Compress;$reason=$reason.Replace($encoded.Trim('"'),'<secret>').Replace($secret,'<secret>')}
        return @{exitCode=$result.exitCode;stdout=$(if($ok){'{"ok":true}'}else{'{"ok":false}'});stderr=$reason}
    } catch { return @{exitCode=-1;stdout='';stderr='Не удалось выполнить настройку облака: проверьте связь с сервером'} }
    finally {$inputText=$secret=$null}
}
