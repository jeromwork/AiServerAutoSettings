using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace RemoteAgents.Launcher
{
    internal static class AccountDiskSetup
    {
        // Kept separate from public wizard requests and journals. Existing keys survive account changes.
        internal static void SaveKey(string home, string key)
        {
            string directory = Path.Combine(home, "secrets"); Directory.CreateDirectory(directory);
            var sid = WindowsIdentity.GetCurrent().User;
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(directory, acl);
            string current = Path.Combine(directory, "happier-account.key");
            if (File.Exists(current)) Files.Atomic(Path.Combine(directory, "happier-backup-" + Guid.NewGuid().ToString("N") + ".key"), File.ReadAllText(current));
            Files.Atomic(current, key.Trim() + "\n");
        }
    }
}
