#requires -Version 5.1
# B4B: memory pipes, explicit events and manually pumped workers; no network, processes or real-time assertions.
param([switch]$CompileOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Events.ps1')
Initialize-TransportEvents
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Transport.Daemon.ps1'),[ref]$null,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$fixture=@'
using System;
using System.IO;
using System.Text;
using System.Threading;
namespace B4BTests {
 public sealed class BlockedInput : Stream {
  public readonly ManualResetEvent Entered=new ManualResetEvent(false), Release=new ManualResetEvent(false);
  public override int Read(byte[] b,int o,int n) {Entered.Set();Release.WaitOne();return 0;}
  public override bool CanRead {get{return true;}} public override bool CanSeek {get{return false;}} public override bool CanWrite {get{return false;}}
  public override long Length {get{throw new NotSupportedException();}} public override long Position {get{throw new NotSupportedException();}set{throw new NotSupportedException();}}
  public override void Flush() {} public override long Seek(long o,SeekOrigin s) {throw new NotSupportedException();}
  public override void SetLength(long n) {throw new NotSupportedException();} public override void Write(byte[] b,int o,int n) {throw new NotSupportedException();}
 }
 public sealed class BlockedOutput : TextWriter {
  public readonly ManualResetEvent Entered=new ManualResetEvent(false), Release=new ManualResetEvent(false);
  public override Encoding Encoding {get{return new UTF8Encoding(false);}}
  public override void WriteLine(string s) {Entered.Set();Release.WaitOne();}
 }
}
'@
Add-Type -TypeDefinition $fixture
if($CompileOnly){'B4B syntax / C# compilation PASS';return}
function Assert($Value,[string]$Message){if(-not $Value){throw ('B4B: '+$Message)}}
function Pump($Bus,[string]$Method){[void]$Bus.GetType().GetMethod($Method,[Reflection.BindingFlags]'Instance,NonPublic').Invoke($Bus,@())}
function New-TestBus([string]$Text,$Output){
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Text))
    $handle=[RemoteAgents.TransportBus]::new($stream,$Output)
    Pump $handle 'ReadInput'
    $handle
}
$functions=@('New-DaemonEvent','Add-DaemonQueuedEvent','Receive-DaemonBus','Publish-DaemonBusStatus','Publish-DaemonBusReady','Add-DaemonEvent')
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $functions},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
function Get-DaemonTime {[long]1234}
function Write-DaemonPathCheck($Event){}
function Save-TransportMemory {}
$script:eventQueue=@();$DaemonEventLimit=512;$script:daemonEventsQueued=[long]0;$script:daemonEventsDropped=[long]0
$script:networkRefreshPending=$false;$script:TransportBusConnected=$false
$route='@bus {"topic":"win.route.changed","fields":{"family":"IPv4","ifIndex":7}}'
$command='@bus {"topic":"transport.command","fields":{"command":"inspect","text":"Привет"}}'
$writer=[IO.StringWriter]::new()
$bus=New-TestBus ($route+"`r`n"+$command) $writer
Receive-DaemonBus
Assert ($bus.Connected -and $bus.InputClosed -and $TransportBusConnected) 'valid input/EOF did not latch bridge'
Assert ($eventQueue.Count -eq 2 -and $eventQueue[0].kind -eq 'net-change' -and $eventQueue[0].topic -eq 'win.route.changed') 'stdin did not enter daemon queue'
Assert ($eventQueue[1].fields['text'] -ceq 'Привет') 'UTF-8 or fields lost'
Assert $networkRefreshPending 'route event did not request forced network snapshot'
# Run the actual daemon network branch with an injected source. No files or network calls.
$branch=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$networkRefreshPending -or (-not $script:TransportBusConnected -and $now -ge $nextNetwork)'},$true))
Assert ($branch.Count -eq 1) 'network branch missing'
$networkPass=[scriptblock]::Create($branch[0].Extent.Text)
$script:networkCalls=0;$script:forced=0
$network=[pscustomobject]@{id='same';available=$true};$metered=$false
function Get-TransportNetworkSnapshot {param($Options,[switch]$Force) $script:networkCalls++;if($Force){$script:forced++};[pscustomobject]@{network=$network;metered=$false}}
function Test-TransportNetworkChanged {param($Old,$New) $false}
$settings=[pscustomobject]@{Options=[pscustomobject]@{metered='false'}}
$now=[DateTime]'2000-01-01T00:00:00Z';$nextNetwork=[DateTime]::MinValue;$engine=$null
. $networkPass
Assert ($networkCalls -eq 1 -and $forced -eq 1 -and -not $networkRefreshPending) 'route did not force exactly one snapshot'
Receive-DaemonBus;. $networkPass
Assert ($networkCalls -eq 1 -and $TransportBusConnected) 'EOF re-enabled periodic network probing'
foreach($topic in @('win.iface.changed','win.addr.changed','net.change')){
    $bus=New-TestBus ('@bus {"topic":"'+$topic+'","fields":{}}') $writer
    Receive-DaemonBus;. $networkPass
}
Assert ($networkCalls -eq 4 -and $forced -eq 4) 'other network topics did not force refresh'
# Every allowed family survives parsing; malformed/nested/foreign input is ignored, never fatal.
$good='@bus {"topic":"tick.transport-decide","fields":{}}'
$bad=@('junk','@bus {broken','@bus {"topic":"vpn.state","fields":{}}','@bus {"topic":"net.change","fields":[]}',
    '@bus {"topic":"net.change","fields":{"nested":{}}}','@bus {"topic":"net.change","fields":{"array":[]}}',
    '@bus {"topic":"net.change","fields":{"a":1,"a":2}}','@bus {"topic":"net.change","topic":"net.change","fields":{}}')
$bus=New-TestBus (($bad -join "`n")+"`n"+('.'*8193)+$route+"`n"+$good) $writer
$refresh=$false;$events=$bus.Drain([ref]$refresh)
Assert ($events.Count -eq 1 -and $events[0].topic -eq 'tick.transport-decide' -and -not $refresh) 'garbage/long-line forged tail was accepted or next line lost'
Assert ($bus.Rejected -eq ($bad.Count+1)) 'rejected input count wrong'
# Exact byte boundary and CRLF, including multi-byte UTF-8.
$head='@bus {"topic":"win.test","fields":{"text":"';$tail='"}}'
$line=$head+('я'*4000);$line+=('x'*(8192-[Text.Encoding]::UTF8.GetByteCount($line+$tail)))+$tail
$bus=New-TestBus ($line+"`r`n"+($line+'x')+"`n"+$good) $writer
$events=$bus.Drain([ref]$refresh)
Assert ($events.Count -eq 2 -and $bus.Rejected -eq 1) '8192-byte/CRLF boundary or UTF-8 length wrong'
$bus=New-TestBus '' $writer
Receive-DaemonBus
Assert ($bus.InputClosed -and -not $bus.Connected -and $TransportBusConnected) 'closed stdin broke daemon/lifetime latch'
# Bounded input queue: a dropped network notification still invalidates the snapshot.
$bus=New-TestBus ($route+"`n"+(($good+"`n")*600)) $writer
$script:eventQueue=@();$script:networkRefreshPending=$false
Receive-DaemonBus
Assert ($eventQueue.Count -eq 512 -and $bus.InputDropped -eq 89 -and $networkRefreshPending) 'input queue bound/invalidation latch wrong'
for($i=0;$i -lt 600;$i++){Add-DaemonQueuedEvent (New-DaemonEvent 'manual' '' 'ok')}
Assert ($eventQueue.Count -eq 512 -and $daemonEventsDropped -eq 600 -and $networkRefreshPending) 'daemon queue bound/invalidation lost'
'B4B stdin / garbage / UTF-8 / bounds / EOF / forced snapshot PASS'
# Outgoing format, change-only status (no updatedAt), ready only after engine and a valid path success.
$writer=[IO.StringWriter]::new();$bus=New-TestBus '' $writer
$script:busStatusKey=$null;$script:lastStatusKey='{"phase":"checking","ok":false,"active":"a","reason":{"code":"startup"}}'
Publish-DaemonBusStatus;Publish-DaemonBusStatus
Pump $bus 'WritePending'
$lines=@($writer.ToString().Trim() -split '\r?\n')
Assert ($lines.Count -eq 1 -and $lines[0].StartsWith('@bus ')) 'status missing or identical status repeated'
$frame=ConvertFrom-Json $lines[0].Substring(5)
Assert ($frame.topic -eq 'transport.status' -and $frame.fields.phase -eq 'checking' -and -not $frame.fields.PSObject.Properties['updatedAt']) 'status frame shape wrong'
$script:lastStatusKey='{"phase":"ok","ok":true,"active":"a"}'
Publish-DaemonBusStatus
$engine=[pscustomobject]@{Process=[pscustomobject]@{HasExited=$false}}
$script:busEngineReady=$false;$script:busReadySent=$false;$paths=[pscustomobject]@{Candidates=@([pscustomobject]@{tag='a'})};$rows=@();$script:eventQueue=@()
Add-DaemonEvent (New-DaemonEvent 'path-check' 'a' 'ok')
Assert (-not $busReadySent) 'ready before engine-ready'
$script:busEngineReady=$true
Add-DaemonEvent (New-DaemonEvent 'path-check' 'a' 'timeout')
Add-DaemonEvent (New-DaemonEvent 'path-check' 'foreign' 'ok')
Assert (-not $busReadySent) 'ready before valid successful path'
Add-DaemonEvent (New-DaemonEvent 'path-check' 'a' 'ok')
Add-DaemonEvent (New-DaemonEvent 'path-check' 'a' 'ok')
Pump $bus 'WritePending'
$lines=@($writer.ToString().Trim() -split '\r?\n')
Assert ($lines.Count -eq 3 -and (ConvertFrom-Json $lines[1].Substring(5)).fields.phase -eq 'ok' -and (ConvertFrom-Json $lines[2].Substring(5)).topic -eq 'transport.ready') 'changed status/one-shot ready missing'
Send-TransportBusEvent $bus 'transport.mem' ([ordered]@{private=12})
Send-TransportBusEvent $bus 'transport.mem' ([ordered]@{private=12})
Pump $bus 'WritePending'
Assert (@($writer.ToString().Trim() -split '\r?\n').Count -eq 4) 'outgoing dedup failed'
# A large detailed snapshot still sends a bounded status; file status remains untouched.
$large=[ordered]@{phase='ok';ok=$true;candidates=@(('x'*10000));summary=('я'*10000);updatedAt='excluded'}
$script:lastStatusKey=ConvertTo-Json $large -Compress;$script:busStatusKey=$null
Publish-DaemonBusStatus;Pump $bus 'WritePending'
$last=@($writer.ToString().Trim() -split '\r?\n')[-1]
$frame=ConvertFrom-Json $last.Substring(5)
Assert ([Text.Encoding]::UTF8.GetByteCount($last) -le 8192 -and $frame.fields.detailsOmitted -and $frame.fields.fieldsTruncated -and -not $frame.fields.PSObject.Properties['updatedAt']) 'large status not bounded/explicitly summarized'
Assert (-not $bus.Queue('transport.mem',('@bus '+('.'*8192)))) 'oversized output accepted'
Assert (-not $bus.Queue('vpn.state',$good)) 'foreign output accepted'
$writer=[IO.StringWriter]::new();$bus=New-TestBus '' $writer
for($i=0;$i -lt 600;$i++){Send-TransportBusEvent $bus 'transport.mem' ([ordered]@{n=$i})}
Assert ($bus.OutputDropped -eq 88) 'output queue unbounded'
Pump $bus 'WritePending'
Assert (@($writer.ToString().Trim() -split '\r?\n').Count -eq 512) 'bounded output drain wrong'
'B4B stdout / status changes / ready / dedup / bounds PASS'
# Real worker entry is signalled by barriers. Wait limits ONLY fail a hung fixture, never prove success.
$inputGate=[B4BTests.BlockedInput]::new();$outputGate=[B4BTests.BlockedOutput]::new()
$bus=[RemoteAgents.TransportBus]::new($inputGate,$outputGate)
try{
    $bus.Start()
    if(-not $inputGate.Entered.WaitOne(5000)){throw 'fixture stdin worker did not enter'}
    Send-TransportBusEvent $bus 'transport.mem' ([ordered]@{n=1})
    if(-not $outputGate.Entered.WaitOne(5000)){throw 'fixture stdout worker did not enter'}
    # Both pipe operations are blocked, while the daemon can still queue/drain and dispose.
    Send-TransportBusEvent $bus 'transport.mem' ([ordered]@{n=2})
    Receive-DaemonBus
    $bus.Dispose()
}finally{$inputGate.Release.Set()|Out-Null;$outputGate.Release.Set()|Out-Null}
'B4B blocked stdin/stdout leave daemon free PASS'
'B4B transport bus PASS'
