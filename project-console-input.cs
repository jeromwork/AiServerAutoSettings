using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

// Mouse/keyboard input for this selector only. Original console mode is restored.
public static class RemoteAgentsProjectConsole {
    [StructLayout(LayoutKind.Sequential)] struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Explicit, CharSet=CharSet.Unicode)] struct Record {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort Key;
        [FieldOffset(14)] public char Character;
        [FieldOffset(4)] public Coord Position;
        [FieldOffset(8)] public uint Buttons;
        [FieldOffset(16)] public uint Flags;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle,uint mode);
    [DllImport("kernel32.dll",EntryPoint="ReadConsoleInputW",CharSet=CharSet.Unicode)] static extern bool ReadConsoleInput(IntPtr handle,out Record record,uint length,out uint read);
    [DllImport("kernel32.dll",EntryPoint="ReadConsoleOutputCharacterW",CharSet=CharSet.Unicode)] static extern bool ReadConsoleOutputCharacter(IntPtr handle,[Out] char[] text,uint length,Coord position,out uint read);
    public static bool Available {
        get { uint mode; return !Console.IsInputRedirected && !Console.IsOutputRedirected && GetConsoleMode(GetStdHandle(-10),out mode) && GetConsoleMode(GetStdHandle(-11),out mode); }
    }
    public static string MouseChoice(string line, IDictionary<int,string> rows, uint buttons, uint flags) {
        if ((buttons & 1)==0 || flags!=0) return null;
        Match match=Regex.Match(line,@"^\s*(\d+)\. \[[+ ]\] ");
        int index; string expected;
        string choice;
        if(match.Success && Int32.TryParse(match.Groups[1].Value,out index)) { choice=index.ToString(); }
        else {
            match=Regex.Match(line,@"^\s*([SV])\s");
            if(!match.Success) return null;
            choice=match.Groups[1].Value;index=-(int)choice[0];
        }
        if(!rows.TryGetValue(index,out expected)) return null;
        // Ignore stale output from another page/search. Accept a wrapped first line.
        string visible=line.TrimEnd();
        return visible.Length>match.Length && expected.StartsWith(visible,StringComparison.Ordinal) ? choice : null;
    }
    public static string Read(IDictionary<int,string> rows) {
        IntPtr input=GetStdHandle(-10); uint original;
        if (!GetConsoleMode(input,out original)) throw new InvalidOperationException("Console input unavailable");
        // Disable QuickEdit only while reading our menu, never a saved Windows policy.
        uint mode=(original | 0x10u | 0x80u | 0x8u) & ~(0x40u | 0x2u | 0x4u | 0x200u);
        if (!SetConsoleMode(input,mode)) throw new InvalidOperationException("Console input mode unavailable");
        StringBuilder text=new StringBuilder();
        try {
            while(true) {
                Record record; uint count;
                if (!ReadConsoleInput(input,out record,1,out count) || count!=1) throw new InvalidOperationException("Console input ended");
                if(record.Type==2) {
                    char[] line=new char[Console.BufferWidth]; uint read;
                    Coord start=new Coord { X=0,Y=record.Position.Y };
                    if(ReadConsoleOutputCharacter(GetStdHandle(-11),line,(uint)Console.BufferWidth,start,out read)) {
                        string selected=MouseChoice(new string(line,0,(int)read),rows,record.Buttons,record.Flags);
                        if(selected!=null) { Console.WriteLine(); return selected; }
                    }
                } else if(record.Type==1 && record.KeyDown!=0) {
                    if(record.Key==13) { Console.WriteLine();return text.ToString(); }
                    if(record.Key==27) { Console.WriteLine();return "0"; }
                    if(record.Key==8) { if(text.Length>0) { text.Length--;Console.Write("\b \b"); }continue; }
                    if(record.Character>=' ' && text.Length<128) { text.Append(record.Character);Console.Write(record.Character); }
                }
            }
        } finally { SetConsoleMode(input,original); }
    }
}
