[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VPSHost,
    [Parameter(Mandatory=$true)][string]$VPSUser,
    [Parameter(Mandatory=$true)][string]$IdentityFile,
    [Parameter(Mandatory=$true)][string]$KnownHostsFile,
    [string]$SSHConfig,
    [string]$SSHExecutable="$env:WINDIR\System32\OpenSSH\ssh.exe",
    [ValidateRange(1,65535)][int]$SSHPort=22,
    [string]$ChatUser='remoteagents'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Remote.Chat.ps1')
if(!(Test-RemoteChatUser $ChatUser)){throw 'Недопустимое имя пользователя чатов.'}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$connection=@{SSHExecutable=$SSHExecutable;VPSHost=$VPSHost;VPSUser=$VPSUser;IdentityFile=$IdentityFile;SSHConfig=$SSHConfig;KnownHostsFile=$KnownHostsFile;SSHPort=$SSHPort;ChatUser=$ChatUser}
$script:chatProcess=$null;$script:chatStreams=@();$script:approvalUrl=$null;$script:chatAction='';$script:chatClock=$null
$form=New-Object Windows.Forms.Form
$form.Text='Чаты на сервере — Codex и Claude'
$form.ClientSize=New-Object Drawing.Size(680,410)
$form.StartPosition='CenterScreen'
$form.MinimumSize=New-Object Drawing.Size(696,449)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$title=New-Object Windows.Forms.Label
$title.Text='Codex и Claude — без удалённого рабочего стола'
$title.Font=New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Bold)
$title.SetBounds(22,20,635,34)
$description=New-Object Windows.Forms.Label
$description.Text="Сервер: $VPSHost`r`nОбщие чаты и проекты. Приложения работают на сервере."
$description.SetBounds(22,65,635,54)
$status=New-Object Windows.Forms.Label
$status.Text='Проверяем подключение… (до 10 секунд)'
$status.SetBounds(22,125,635,62)
$open=New-Object Windows.Forms.Button
$open.Text='Открыть чаты в браузере'
$open.SetBounds(22,199,302,42)
$pair=New-Object Windows.Forms.Button
$pair.Text='Подключить сервер к аккаунту'
$pair.SetBounds(344,199,313,42)
$approve=New-Object Windows.Forms.Button
$approve.Text='Открыть подтверждение входа'
$approve.SetBounds(22,250,635,40)
$approve.Enabled=$false
$help=New-Object Windows.Forms.Label
$help.Text="Первый запуск: подключите сервер и подтвердите вход в браузере.`r`nВ Happier: «Новый чат» → машина → папка проекта → Codex или Claude.`r`nВойти в Codex/Claude можно в настройках агента выбранной машины.`r`nДля общих чатов на всех компьютерах войдите в один аккаунт Happier. Каждый может вести свои проекты и чаты."
$help.SetBounds(22,306,635,91)
$form.Controls.AddRange(@($title,$description,$status,$open,$pair,$approve,$help))
function Stop-ChatProcess {
    if($script:chatProcess){
        if(!$script:chatProcess.HasExited){$script:chatProcess.Kill()}
        $script:chatProcess.Dispose();$script:chatProcess=$null
    }
    $script:chatStreams=@()
}
function Start-ChatAction([string]$Action) {
    Stop-ChatProcess
    $script:approvalUrl=$null;$approve.Enabled=$false
    $script:chatAction=$Action
    $script:chatProcess=New-Object Diagnostics.Process
    $script:chatProcess.StartInfo=New-RemoteChatStart @connection -Action $Action
    [void]$script:chatProcess.Start()
    $script:chatProcess.StandardInput.Close()
    $script:chatStreams=@(
        [pscustomobject]@{Reader=$script:chatProcess.StandardOutput;Task=$script:chatProcess.StandardOutput.ReadLineAsync();Closed=$false},
        [pscustomobject]@{Reader=$script:chatProcess.StandardError;Task=$script:chatProcess.StandardError.ReadLineAsync();Closed=$false}
    )
    $script:chatClock=[Diagnostics.Stopwatch]::StartNew()
    $pair.Enabled=$false
    $status.Text=if($Action -eq 'login'){'Готовим подтверждение входа. Запрос действует 10 минут.'}else{'Проверяем подключение… (до 10 секунд)'}
}
$open.Add_Click({Start-Process 'https://cloud.happier.dev/'})
$pair.Add_Click({try{Start-ChatAction 'login'}catch{$status.Text='Не удалось начать вход. Повторите подключение.';$pair.Enabled=$true}})
$approve.Add_Click({if($script:approvalUrl){Start-Process $script:approvalUrl}})
$timer=New-Object Windows.Forms.Timer
$timer.Interval=100
$timer.Add_Tick({
    try{
        if(!$script:chatProcess){return}
        foreach($stream in $script:chatStreams){
            $count=0
            while(!$stream.Closed -and $stream.Task.IsCompleted -and $count -lt 40){
                $count++
                $line=$stream.Task.GetAwaiter().GetResult()
                if($null -eq $line){$stream.Closed=$true;break}
                # Sign-in URLs stay in this window's memory; no transcript/log/output.
                $url=Get-RemoteChatApprovalUrl $line
                if($script:chatAction -eq 'login' -and $url){
                    $script:approvalUrl=$url;$approve.Enabled=$true
                    $status.Text='Нажмите «Открыть подтверждение входа», затем подтвердите сервер в браузере.'
                }
                if($script:chatAction -eq 'status'){
                    try{
                        $result=$line|ConvertFrom-Json -ErrorAction Stop
                        if($result.kind -eq 'auth_status'){
                            if($result.ok){$status.Text='Сервер подключён к Happier. Откройте чаты; выберите машину и проект.'}
                            elseif($result.error.code -eq 'not_authenticated'){$status.Text='Нужен первый вход. Нажмите «Подключить сервер к аккаунту».'}
                            else{$status.Text='Подключение требует проверки. Повторите вход без удаления профиля.'}
                        }
                    }catch{}
                }
                $stream.Task=$stream.Reader.ReadLineAsync()
            }
        }
        $limit=if($script:chatAction -eq 'login'){620}else{10}
        if(!$script:chatProcess.HasExited -and $script:chatClock.Elapsed.TotalSeconds -ge $limit){
            Stop-ChatProcess;$pair.Enabled=$true;$approve.Enabled=$false
            $status.Text=if($script:chatAction -eq 'login'){'Время подтверждения истекло. Нажмите подключение для новой попытки.'}else{'Сервер не ответил за 10 секунд. Чаты можно открыть; проверьте подключение из установщика.'}
            return
        }
        if($script:chatProcess.HasExited -and @($script:chatStreams|Where-Object{!$_.Closed}).Count -eq 0){
            $exitCode=$script:chatProcess.ExitCode
            if($script:chatAction -eq 'login'){
                $approve.Enabled=$false
                if($exitCode -eq 0){Start-ChatAction 'status';return}
                $status.Text='Вход не завершён. Нажмите подключение и подтвердите новый запрос в браузере.'
            }elseif($status.Text -like 'Проверяем*'){$status.Text='Проверка не завершена. Можно повторить вход; данные профиля сохранены.'}
            Stop-ChatProcess;$pair.Enabled=$true
        }
    }catch{Stop-ChatProcess;$pair.Enabled=$true;$approve.Enabled=$false;$status.Text='Не удалось проверить подключение. Повторите вход; данные сохранены.'}
})
$form.Add_Shown({try{Start-ChatAction 'status'}catch{$status.Text='Подключение пока недоступно. Откройте установщик и выберите сервер.';$pair.Enabled=$true};$timer.Start()})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();Stop-ChatProcess})
try{[void]$form.ShowDialog()}finally{$form.Dispose()}
