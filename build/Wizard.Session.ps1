#requires -Version 5.1
# One authenticated SSH process per profile/pin/route generation, shared by action processes.
# Private filesystem queue avoids a TCP listener and is supported by Windows PowerShell 5.1.
function Get-WizardSessionWorker {
@'
import sys,json,base64,subprocess,threading,concurrent.futures,os,signal
lock=threading.Lock()
def run(row):
 try:
  process=subprocess.Popen(['bash','-c',base64.b64decode(row['command']).decode()],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
  try:output,_=process.communicate(base64.b64decode(row['input']),timeout=row['timeout'])
  except subprocess.TimeoutExpired:
   os.killpg(process.pid,signal.SIGKILL);process.communicate(timeout=5);raise
  reply=dict(id=row['id'],code=process.returncode,output=base64.b64encode(output).decode())
 except Exception:reply=dict(id=row['id'],code=124,output='')
 with lock:print(json.dumps(reply),flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
 for line in sys.stdin:
  try:pool.submit(run,json.loads(line))
  except Exception:break
'@
}
function Invoke-WizardControlSession([string]$Root,$Profile,$Route,[string]$Command,[string]$InputText,[int]$Timeout) {
    $pins='';if(Test-Path $Profile.knownHostsPath){$pins=[IO.File]::ReadAllText($Profile.knownHostsPath)}
    $generation=(ConvertTo-Json -InputObject $Profile -Depth 30 -Compress)+$pins+(ConvertTo-Json -InputObject @($Route) -Depth 10 -Compress)
    $generation+=(Get-WizardSessionWorker)
    $id=(Get-TransportFingerprint 'control-session' $generation).Substring(0,32)
    $dir=Join-Path $Root ('state/wizard-control/'+$id)
    [void][IO.Directory]::CreateDirectory($dir);Protect-TransportPath $dir
    $ready=Join-Path $dir 'ready.json'
    Invoke-WizardResourceLock $Root ('control-start-'+$id) {
        $live=$false
        if(Test-Path $ready){$live=([DateTime]::UtcNow-(Get-Item $ready).LastWriteTimeUtc).TotalSeconds -lt 5}
        if(-not $live){
            $profileFile=Join-Path $dir 'profile.json';$routeFile=Join-Path $dir 'route.json'
            Write-TransportJson $profileFile $Profile -Private
            Write-TransportJson $routeFile @{options=@($Route)} -Private
            $si=New-Object Diagnostics.ProcessStartInfo
            $si.FileName=Get-TransportPowerShell
            $si.Arguments=((@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Wizard.SessionHost.ps1'),'-Root',$Root,'-Directory',$dir,'-ProfileFile',$profileFile,'-RouteFile',$routeFile)|ForEach-Object {Quote-Transport $_}) -join ' ')
            $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
            $child=New-Object Diagnostics.Process;$child.StartInfo=$si
            try{
                [void]$child.Start();[void]$child.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null);[void]$child.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
                $watch=[Diagnostics.Stopwatch]::StartNew()
                while(-not (Test-Path $ready) -or ([DateTime]::UtcNow-(Get-Item $ready).LastWriteTimeUtc).TotalSeconds -ge 5){
                    if($child.HasExited -or $watch.Elapsed.TotalSeconds -gt 12){throw 'Управляющий SSH-сеанс не запущен'}
                    Start-Sleep -Milliseconds 30
                }
            }finally{$child.Dispose()}
        }
    }
    $requestId=[guid]::NewGuid().ToString('N');$requestFile=Join-Path $dir ($requestId+'.request.json');$replyFile=Join-Path $dir ($requestId+'.reply.json')
    try{
        $row=@{id=$requestId;timeout=$Timeout;command=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command));input=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Convert-TransportLF $InputText)))}
        Write-WizardSessionMessage $requestFile $row
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path $replyFile)){
            if($watch.Elapsed.TotalSeconds -gt ($Timeout+15)){throw 'Таймаут управляющего SSH-сеанса'}
            if(-not (Test-Path $ready) -or ([DateTime]::UtcNow-(Get-Item $ready).LastWriteTimeUtc).TotalSeconds -gt 8){throw 'Управляющий SSH-сеанс прерван; повторите раздел'}
            Start-Sleep -Milliseconds 25
        }
        $reply=Read-TransportJson $replyFile
        if($reply.id -cne $requestId -or $reply.code -ne 0){throw ('Команда сервера не выполнена (код '+[int]$reply.code+'); повторите раздел после проверки SSH')}
        return Convert-TransportLF ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$reply.output)))
    }finally{foreach($f in @($requestFile,$replyFile)){if(Test-Path $f){Remove-Item -LiteralPath $f -Force}}}
}

function Write-WizardSessionMessage([string]$Path,$Value) {
    # Publish only after ACL setup has completed; the consumer may unlink immediately.
    $stage=$Path+'.stage'
    try{Write-TransportJson $stage $Value -Private;[IO.File]::Move($stage,$Path)}finally{if(Test-Path $stage){Remove-Item -LiteralPath $stage -Force}}
}
