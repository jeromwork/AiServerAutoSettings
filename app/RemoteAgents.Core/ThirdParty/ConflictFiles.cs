// Adapted conflict recognition from SyncTrayzor ConflictFileManager (afac7f1).
// Copyright (c) 2015-2021 Antony Male; (c) 2025 GermanCoding. MIT.
// Full notice in THIRD-PARTY-NOTICES.txt. No automatic conflict deletion/resolution.
using System.Text.RegularExpressions;
namespace RemoteAgents.Core.ThirdParty;

public static class ConflictFiles
{
    static readonly Regex Pattern = new(@"^(?<prefix>.*)\.sync-conflict-(?<year>\d{4})(?<month>\d{2})(?<day>\d{2})-(?<hours>\d{2})(?<mins>\d{2})(?<secs>\d{2})-(?<device>[a-zA-Z0-9]+)?(?<suffix>.*(?=\.))?(?<extension>\..*)?$");
    public static bool IsConflict(string path)
    {
        var name=Path.GetFileName(path);
        if(name.Contains("~syncthing~"))return false;
        var match=Pattern.Match(name); if(!match.Success) return false;
        try { int N(string key)=>int.Parse(match.Groups[key].Value); _=new DateTime(N("year"),N("month"),N("day"),N("hours"),N("mins"),N("secs"));return true; }
        catch(ArgumentOutOfRangeException) {return false;}
    }
    public static string[] Find(string root)
    {
        var options=new EnumerationOptions{RecurseSubdirectories=true,AttributesToSkip=FileAttributes.ReparsePoint,IgnoreInaccessible=false};
        return Directory.EnumerateFiles(root,"*.sync-conflict-*",options)
            .Where(p=>!Path.GetRelativePath(root,p).Split(Path.DirectorySeparatorChar).Contains(".stversions")&&IsConflict(p)).Take(1000).ToArray();
    }
}
