#requires -Version 5.1
# M0: synthetic events, manually completed checks and fake clocks. No network or waits.
param([switch]$CompileOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
. (Join-Path $PSScriptRoot 'Transport.Events.ps1')
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')
$eventsAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Transport.Events.ps1'),[ref]$null,[ref]$null)
$eventSource=$eventsAst.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('using System;')},$true).Value
$testSource=@'
namespace M0Tests {
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.Serialization;
using RemoteAgents;
public static class M0Retention {
 const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
 static readonly MethodInfo Log=typeof(TransportEvents).GetMethod("ParseLogAt",Private);
 static readonly MethodInfo Connections=typeof(TransportEvents).GetMethod("ParseConnectionsAt",Private);
 static readonly MethodInfo Enqueue=typeof(TransportEvents).GetMethod("Enqueue",Private);
 static void Field(TransportEvents reader,string name,object value) {
  typeof(TransportEvents).GetField(name,Private).SetValue(reader,value);
 }
 static TransportEvents Reader() {
  // Parsers only: no constructor, worker, socket or cancellation source is started.
  // No formatter/serialization is used; this builds a parser-only fixture on net48 and Core.
#pragma warning disable
  TransportEvents reader=(TransportEvents)FormatterServices.GetUninitializedObject(typeof(TransportEvents));
#pragma warning restore
  foreach(string name in new[]{"gate","queue","samples","suspected","contexts"}) {
   FieldInfo field=typeof(TransportEvents).GetField(name,Private);
   Field(reader,name,Activator.CreateInstance(field.FieldType,true));
  }
  Field(reader,"tags",new HashSet<string>(new[]{"a"}));
  Field(reader,"stallSeconds",8.0);Field(reader,"stallConns",2);
  return reader;
 }
 static ClashConnection Connection(string id) {
  return new ClashConnection {Id=id,Start="2000-01-01T00:00:00Z",Chains=new[]{"a"},Upload=1,Download=1};
 }
 static void Feed(TransportEvents reader,int count,WeakReference[] inputs) {
  for(int i=0;i<count;i++) {
   ClashLog log=new ClashLog {Type="warn",Payload="["+i+" 1ms] outbound/test[a]"};
   ClashConnections snapshot=new ClashConnections {Connections=new[]{Connection("c"+i)}};
   inputs[i%inputs.Length]=new WeakReference(snapshot);
   Log.Invoke(reader,new object[]{log,i/1000.0});
   Connections.Invoke(reader,new object[]{snapshot,i/1000.0});
   Enqueue.Invoke(reader,new object[]{new TransportEvent {at=i,kind="path-check",tag="a",code="cancelled"}});
  }
 }
 static void Require(bool value,string message) {if(!value) throw new Exception(message);}
 public static string Run(int count) {
  TransportEvents reader=Reader();WeakReference[] inputs=new WeakReference[64];
  Feed(reader,count,inputs);
  Require(reader.QueuedEvents==TransportEvents.MaxQueuedEvents,"reader queue bound");
  Require(reader.RetainedSamples==1,"departed connections retained");
  Require(reader.RetainedContexts<=TransportEvents.MaxLogContexts,"log contexts bound");
  Require(reader.Dropped==count-TransportEvents.MaxQueuedEvents,"reader overflow count");
  GC.Collect();GC.WaitForPendingFinalizers();GC.Collect();
  int alive=0;foreach(WeakReference input in inputs) if(input.IsAlive) alive++;
  Require(alive==0,"snapshot input objects retained");
  ClashConnection[] full=new ClashConnection[TransportEvents.MaxConnectionSamples];
  for(int i=0;i<full.Length;i++) full[i]=Connection("full"+i);
  Connections.Invoke(reader,new object[]{new ClashConnections {Connections=full},count+1.0});
  Require(reader.RetainedSamples==TransportEvents.MaxConnectionSamples,"exact sample limit rejected");
  try {
   Connections.Invoke(reader,new object[]{new ClashConnections {Connections=new ClashConnection[full.Length+1]},count+2.0});
   throw new Exception("oversized snapshot accepted");
  }catch(TargetInvocationException error) {if(!(error.InnerException is SerializationException)) throw;}
  Require(reader.RetainedSamples==0 && reader.OversizedSnapshots==1,"overflow baseline not cleared/count missing");
  Connections.Invoke(reader,new object[]{new ClashConnections {Connections=new[]{Connection("recovered")}},count+3.0});
  Require(reader.RetainedSamples==1,"parser did not recover after overflow");
  Require(reader.Drain().Length==TransportEvents.MaxQueuedEvents && reader.QueuedEvents==0,"reader drain retained events");
  return "reader N="+count+" bounds=queue:512,contexts:2048,samples:4096 liveInputs="+alive+" PASS";
 }
}
}
'@
$combined=$eventSource+[Environment]::NewLine+$testSource
if($PSVersionTable.PSEdition -eq 'Core'){Add-Type -TypeDefinition $combined}
else{Add-Type -TypeDefinition $combined -ReferencedAssemblies System.dll,System.Core.dll,System.Runtime.Serialization.dll,System.Xml.dll}
function Assert($Value,[string]$Message) {if(-not $Value){throw $Message}}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Transport.Daemon.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Receive-DaemonChecks','Add-DaemonQueuedEvent','Get-DaemonRetentionFields','Write-DaemonPathCheck','Reset-DaemonDecision')},$true)){
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Write-RaLog { }
function Get-DaemonTime { $script:fakeNow }
function Receive-TransportDirectCheck($Handle) { $Handle.result }
function Stop-TransportDirectCheck($Handle) { $script:stopped++;$Handle.result=$null }
$root='unused';$paths=@{Candidates=@(@{tag='a'})};$rows=@();$decision=$null;$active='a';$memory=$null
$script:daemonEventsQueued=[long]0;$script:daemonProbesStarted=[long]0
$DaemonEventLimit=512;$script:daemonCheckPolls=[long]0;$script:daemonEventsDropped=[long]0
$eventQueue=@();$pathChecks=@{};$probes=@{};$pathLogState=@{};$liveDeferred=@();$tunnelChildren=@{};$reader=$null;$reloadJob=$null
if($CompileOnly){'M0 compilation PASS';return}
foreach($n in @(1000,20000)){
    $eventQueue=@();$script:daemonEventsDropped=[long]0;$script:daemonCheckPolls=[long]0;$script:stopped=0
    Write-DaemonPathCheck @{tag='a';code='ok'}
    for($i=0;$i -lt $n;$i++){
        $script:fakeNow=[long]$i
        $directCheck=@{handle=@{result=@{at=0;kind='net-up';tag='';code='ok';local=$false}};until=[long]::MaxValue}
        Receive-DaemonChecks
        Write-DaemonPathCheck @{tag=('unknown'+$i);code='ok'}
    }
    Assert ($null -eq $directCheck -and $stopped -eq $n -and $daemonCheckPolls -eq $n) 'completed direct checks not released exactly once'
    Assert ($eventQueue.Count -eq $DaemonEventLimit -and $daemonEventsDropped -eq ($n-$DaemonEventLimit)) 'daemon queue bound or drop counter'
    Assert ($eventQueue[0].at -eq ($n-$DaemonEventLimit) -and $eventQueue[-1].at -eq ($n-1)) 'daemon did not drop oldest event'
    Assert ($pathLogState.Count -eq 1) 'unknown tags retained in last-value map'
    Reset-DaemonDecision;Assert ($pathLogState.Count -eq 0) 'old generation tags retained'
    $fields=Get-DaemonRetentionFields
    Assert ($fields.directChecks -eq 0 -and $fields.reloadJobs -eq 0 -and $fields.events -eq 512) 'retention diagnostics disagree with owned objects'
    $eventQueue=@();Assert ($eventQueue.Count -eq 0) 'daemon drain retained events'
    'daemon N='+$n+' bound=512 activeChecks=0 PASS'
    [M0Tests.M0Retention]::Run($n)
}
'M0 retention PASS'
