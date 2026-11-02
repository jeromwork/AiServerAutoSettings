$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-console-mouse-'+[guid]::NewGuid().ToString('N'))
$process=$null
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'project-console-input.cs'))
    $harness=@'
public class ConsoleMouseFixture {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit,Size=20,CharSet=System.Runtime.InteropServices.CharSet.Unicode)] struct Input {
        [System.Runtime.InteropServices.FieldOffset(0)] public ushort Type;
        [System.Runtime.InteropServices.FieldOffset(4)] public int KeyDown;
        [System.Runtime.InteropServices.FieldOffset(8)] public uint Buttons;
        [System.Runtime.InteropServices.FieldOffset(10)] public ushort Key;
        [System.Runtime.InteropServices.FieldOffset(14)] public char Character;
        [System.Runtime.InteropServices.FieldOffset(6)] public short Y;
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool AllocConsole();
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool FreeConsole();
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern System.IntPtr GetConsoleWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(System.IntPtr window,int mode);
    [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)] static extern System.IntPtr CreateFileW(string name,uint access,uint share,System.IntPtr security,uint creation,uint flags,System.IntPtr template);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool SetStdHandle(int index,System.IntPtr handle);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GetConsoleMode(System.IntPtr handle,out uint mode);
    [System.Runtime.InteropServices.DllImport("kernel32.dll",EntryPoint="WriteConsoleInputW",CharSet=System.Runtime.InteropServices.CharSet.Unicode)] static extern bool WriteConsoleInput(System.IntPtr handle,Input[] events,uint count,out uint written);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct Position { public short X,Y; }
    [System.Runtime.InteropServices.DllImport("kernel32.dll",EntryPoint="ReadConsoleOutputCharacterW",CharSet=System.Runtime.InteropServices.CharSet.Unicode)] static extern bool ReadOutput(System.IntPtr handle,[System.Runtime.InteropServices.Out] char[] text,uint size,Position position,out uint read);
    static void Check(bool value,string message) { if(!value) throw new System.Exception(message); }
    public static int Main(string[] args) {
        try {
            // The test child can inherit a non-visible host console even with
            // CREATE_NO_WINDOW. Detach only this child before making its fixture.
            FreeConsole();Check(AllocConsole(),"Private console creation failed");ShowWindow(GetConsoleWindow(),0);
            var input=CreateFileW("CONIN$",0xC0000000,3,System.IntPtr.Zero,3,0,System.IntPtr.Zero);
            var output=CreateFileW("CONOUT$",0xC0000000,3,System.IntPtr.Zero,3,0,System.IntPtr.Zero);
            Check(SetStdHandle(-10,input) && SetStdHandle(-11,output),"Private console handles failed");
            Check(RemoteAgentsProjectConsole.Available,"Native console mouse availability was not detected");
            uint before,after;Check(GetConsoleMode(input,out before),"No private input mode");
            var rows=new System.Collections.Generic.Dictionary<int,string>();rows[1]="  1. [ ] fixture | Git | source date";
            rows[-83]="S / Enter - Connect selected (1): fixture";
            Check(RemoteAgentsProjectConsole.MouseChoice(rows[1],rows,1,0)=="1","Mouse decoder rejected current row");
            Check(RemoteAgentsProjectConsole.MouseChoice(rows[1],rows,1,2)==null,"Double click toggles twice");
            Check(RemoteAgentsProjectConsole.MouseChoice("  1. [ ] wrong | Git",rows,1,0)==null,"Stale/foreign console row accepted");
            Check(RemoteAgentsProjectConsole.MouseChoice(rows[1],rows,0,0)==null,"Mouse release toggled row");
            System.Console.WriteLine(rows[1]);
            System.Console.WriteLine(rows[-83]);
            var buffer=new char[System.Console.BufferWidth];uint read;ReadOutput(output,buffer,(uint)buffer.Length,new Position(),out read);string line=new string(buffer,0,(int)read);
            bool done=false;var send=new System.Threading.Thread(()=>{System.Threading.Thread.Sleep(150);uint written;WriteConsoleInput(input,new[]{new Input{Type=2,Buttons=1,Y=0}},1,out written);System.Threading.Thread.Sleep(800);if(!done)WriteConsoleInput(input,new[]{new Input{Type=1,KeyDown=1,Key=13}},1,out written);});
            send.Start();string selected=RemoteAgentsProjectConsole.Read(rows);done=true;send.Join();Check(selected=="1","Native mouse did not select row; actual buffer: ["+line+"] result=["+selected+"]");
            Check(GetConsoleMode(input,out after) && before==after,"Input mode not restored after mouse");
            send=new System.Threading.Thread(()=>{System.Threading.Thread.Sleep(150);uint written;WriteConsoleInput(input,new[]{new Input{Type=2,Buttons=1,Y=1}},1,out written);});
            send.Start();Check(RemoteAgentsProjectConsole.Read(rows)=="S","Native clickable action footer failed");send.Join();
            Check(GetConsoleMode(input,out after) && before==after,"Input mode not restored after action footer");
            send=new System.Threading.Thread(()=>{System.Threading.Thread.Sleep(150);uint written;var records=new[]{new Input{Type=1,KeyDown=1,Character='1'},new Input{Type=1,KeyDown=1,Character='.'},new Input{Type=1,KeyDown=1,Character='2'},new Input{Type=1,KeyDown=1,Key=13}};WriteConsoleInput(input,records,(uint)records.Length,out written);});
            send.Start();Check(RemoteAgentsProjectConsole.Read(rows)=="1.2","Native keyboard input changed");send.Join();
            Check(GetConsoleMode(input,out after) && before==after,"Input mode not restored after keyboard");
            System.IO.File.WriteAllText(args[0],"PASS");return 0;
        }catch(System.Exception error){System.IO.File.WriteAllText(args[0],error.ToString());return 1;}
        finally{FreeConsole();}
    }
}
'@
    $exe=Join-Path $fixture 'console-fixture.exe';$report=Join-Path $fixture 'result.txt'
    Add-Type -TypeDefinition ($source+"`n"+$harness) -OutputAssembly $exe -OutputType ConsoleApplication
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$exe;$info.Arguments='"'+$report+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info;[void]$process.Start();$handle=$process.Handle
    if(!$process.WaitForExit(10000)){throw 'Private console fixture timed out'}
    if($process.ExitCode -ne 0 -or [IO.File]::ReadAllText($report) -cne 'PASS'){throw ([IO.File]::ReadAllText($report))}
    'PASS: real Win32 mouse and keyboard records in a private hidden test console, exact visible-row mapping, stale/double/release rejection and original console mode restored'
}finally{
    if($process){if(!$process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe console fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
