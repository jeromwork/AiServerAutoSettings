#requires -Version 5.1
param([string]$Root,[string]$Directory,[string]$ProfileFile,[string]$RouteFile)
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot 'Wizard.Common.ps1')
    Invoke-WizardResourceLock $Root ('control-serve-'+(Split-Path $Directory -Leaf)) {
        $p=Read-TransportJson $ProfileFile;$route=Read-TransportJson $RouteFile
        $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-WizardSessionWorker)))
        $command='python3 -u -c ''import base64;exec(base64.b64decode("'+$code+'"))'''
        $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$p.sshExecutable
        $si.Arguments=((@($route.options|Where-Object {$null -ne $_ -and [string]$_ -ne ''})+@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2')+@($p.arguments)+@($command)|ForEach-Object {Quote-Transport ([string]$_)}) -join ' ')
        $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
        $ssh=New-Object Diagnostics.Process;$ssh.StartInfo=$si;$ready=Join-Path $Directory 'ready.json';$active=@{};$last=[DateTime]::UtcNow
        try{
            [void]$ssh.Start();[void]$ssh.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            $line=$ssh.StandardOutput.ReadLineAsync()
            $idle=330;if($env:REMOTEAGENTS_CONTROL_IDLE_SECONDS){$idle=[int]$env:REMOTEAGENTS_CONTROL_IDLE_SECONDS}
            while(-not $ssh.HasExited -and -not (Test-Path (Join-Path $Directory 'stop'))){
                if(-not (Test-Path $ready) -or ([DateTime]::UtcNow-(Get-Item $ready).LastWriteTimeUtc).TotalMilliseconds -gt 500){Write-TransportJson $ready @{pid=$PID}}
                foreach($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.request.json')){
                    $row=Read-TransportJson $file.FullName
                    if($row.id -cnotmatch '\A[a-f0-9]{32}\z' -or $row.timeout -lt 1 -or $row.timeout -gt 2100){Remove-Item $file.FullName -Force;continue}
                    $active[$row.id]=[DateTime]::UtcNow
                    $ssh.StandardInput.WriteLine((ConvertTo-Json $row -Compress));$ssh.StandardInput.Flush()
                    Remove-Item -LiteralPath $file.FullName -Force;$last=[DateTime]::UtcNow
                }
                if($line.IsCompleted){
                    $text=$line.GetAwaiter().GetResult();if($null -eq $text){break}
                    $reply=ConvertFrom-Json (Convert-TransportLF $text)
                    if($reply.id -cmatch '\A[a-f0-9]{32}\z' -and $active.ContainsKey($reply.id)){
                        Write-WizardSessionMessage (Join-Path $Directory ($reply.id+'.reply.json')) $reply
                        $active.Remove($reply.id);$last=[DateTime]::UtcNow
                    }
                    $line=$ssh.StandardOutput.ReadLineAsync()
                }
                foreach($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.reply.json')){if(([DateTime]::UtcNow-$file.LastWriteTimeUtc).TotalSeconds -gt 30){Remove-Item -LiteralPath $file.FullName -Force}}
                if(-not $active.Count -and ([DateTime]::UtcNow-$last).TotalSeconds -gt $idle){break}
                Start-Sleep -Milliseconds 20
            }
        }finally{
            if(Test-Path $ready){Remove-Item -LiteralPath $ready -Force}
            if($ssh.Id -and -not $ssh.HasExited){$ssh.StandardInput.Close();if(-not $ssh.WaitForExit(2000)){$ssh.Kill()}}
            $ssh.Dispose()
            Get-ChildItem -LiteralPath $Directory -Filter '*.json'|Remove-Item -Force
        }
    } -TimeoutMs 1000
