using Microsoft.Win32;
using RemoteAgents.Core;

namespace RemoteAgents.Tray;

static class WindowsIntegration
{
    const string Prefix="RemoteAgentsV1_";
    static readonly string[] Locations=[@"Software\Classes\Directory\shell",@"Software\Classes\*\shell",@"Software\Classes\Directory\Background\shell"];
    public static void AutoStart(bool enabled)
    {
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if(enabled) key.SetValue("RemoteAgentsV1",Quote(Environment.ProcessPath!)); else key.DeleteValue("RemoteAgentsV1",false);
    }
    static string Quote(string path)=>"\""+path+"\"";
    static string Exact(string path)=>"System.ItemPathDisplay:="+Quote(path.TrimEnd('\\'));
    static string Inside(string path)=>"System.ItemPathDisplay:~<"+Quote(path.TrimEnd('\\')+"\\");
    public static void RemoveMenus()
    {
        foreach(var location in Locations) {using var parent=Registry.CurrentUser.CreateSubKey(location);foreach(var name in parent.GetSubKeyNames().Where(n=>n.StartsWith(Prefix,StringComparison.Ordinal))) parent.DeleteSubKeyTree(name,false);}
    }
    public static void RegisterMenus(AppConfig config)
    {
        RemoveMenus(); if(!config.ContextMenu)return;
        var folders=config.Folders.Where(f=>f.Enabled).ToArray();
        string managed=string.Join(" OR ",folders.Select(f=>"("+Exact(f.LocalPath)+" OR "+Inside(f.LocalPath)+")"));
        Add(0,"connect","Синхронизировать с сервером",managed.Length==0?null:"NOT ("+managed+")","connect");
        foreach(var f in folders) {
            var root=Exact(f.LocalPath);var inner=Inside(f.LocalPath);
            Add(0,f.Id+"status","Показать статус",root,"status");
            bool paused=f.PauseUntilResume||f.PauseUntil>DateTimeOffset.UtcNow;
            Add(0,f.Id+"pause",paused?"Возобновить":"Приостановить",root,paused?"resume":"pause");
            Add(0,f.Id+"disconnect","Отключить, файлы останутся",root,"disconnect");
            Add(0,f.Id+"log","Открыть журнал",root,"log");
            Add(2,f.Id+"background","Показать статус",root+" OR "+inner,"status",true);
            foreach(int location in new[]{0,1}) {
                var excluded=f.Exclusions.Select(p=>Path.Combine(f.LocalPath,p.TrimStart('/').Replace('/',Path.DirectorySeparatorChar))).Select(p=>"("+Exact(p)+" OR "+Inside(p)+")").ToArray();
                string excludedFilter=string.Join(" OR ",excluded);
                Add(location,f.Id+"exclude","Исключить из синхронизации",inner+(excluded.Length>0?" AND NOT ("+excludedFilter+")":""),"exclude");
                if(excluded.Length>0)Add(location,f.Id+"include","Вернуть в синхронизацию",inner+" AND ("+excludedFilter+")","include");
                Add(location,f.Id+"versions","Показать версии",inner,"versions");
            }
        }
    }
    static void Add(int location,string id,string title,string? applies,string action,bool background=false)
    {
        using var key=Registry.CurrentUser.CreateSubKey(Locations[location]+"\\"+Prefix+id);
        key.SetValue("",title);if(applies!=null)key.SetValue("AppliesTo",applies);
        key.SetValue("MultiSelectModel","Single");
        using var command=key.CreateSubKey("command");command.SetValue("",Quote(Environment.ProcessPath!)+" --"+action+" \""+(background?"%V":"%1")+"\"");
    }
}
