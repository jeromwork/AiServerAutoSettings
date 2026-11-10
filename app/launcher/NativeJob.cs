using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace RemoteAgents.Launcher
{
    internal sealed class NativeJob : IDisposable
    {
        IntPtr handle;
        public NativeJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null); if (handle == IntPtr.Zero) throw new Win32Exception();
            var limits = new ExtendedLimits(); limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) { Dispose(); throw new Win32Exception(); }
        }
        static readonly object inheritGate = new object();
        public Process Start(string exe, string[] args, string cwd)
        { return StartCore(exe, args, cwd, new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)) }, false); }
        public Process StartRedirected(string exe, string[] args, string cwd, string output)
        {
            // Inheritable handles exist only while this lock is held; parallel commands cannot
            // keep each other's output files open. Stdin is immediate EOF, stderr is discarded.
            lock (inheritGate) {
                IntPtr input = IntPtr.Zero, stdout = IntPtr.Zero, stderr = IntPtr.Zero;
                try {
                    input = OpenInherited("NUL", 0x80000000, 3);
                    stdout = OpenInherited(output ?? "NUL", 0x40000000, output == null ? 3u : 2u);
                    stderr = OpenInherited("NUL", 0x40000000, 3);
                    return StartCore(exe, args, cwd, new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)), flags = 0x100, stdInput = input, stdOutput = stdout, stdError = stderr }, true);
                } finally {
                    foreach (var h in new[] { input, stdout, stderr }) if (h != IntPtr.Zero && h != new IntPtr(-1)) CloseHandle(h);
                }
            }
        }
        static IntPtr OpenInherited(string path, uint access, uint disposition)
        {
            var security = new SecurityAttributes { length = Marshal.SizeOf(typeof(SecurityAttributes)), inherit = true };
            var file = CreateFile(path, access, 7, ref security, disposition, 0x80, IntPtr.Zero);
            if (file == new IntPtr(-1)) throw new Win32Exception();
            return file;
        }
        Process StartCore(string exe, string[] args, string cwd, StartupInfo startup, bool inherit)
        {
            exe = Files.Executable(exe); ProcessInfo info;
            // Suspended creation also covers probes/selftests/updater commands, which may spawn
            // children immediately. No process runs before assignment to the kill-on-close job.
            if (!CreateProcess(null, new StringBuilder(Files.Quote(exe) + " " + Files.Arguments(args)), IntPtr.Zero, IntPtr.Zero, inherit, 0x08000004, IntPtr.Zero, cwd, ref startup, out info)) throw new Win32Exception();
            Process process = null;
            try {
                if (!AssignProcessToJobObject(handle, info.process)) throw new Win32Exception();
                process = Process.GetProcessById((int)info.pid); var pinned = process.Handle;
                if (ResumeThread(info.thread) == uint.MaxValue) throw new Win32Exception();
                return process;
            } catch { TerminateProcess(info.process, 1); if (process != null) process.Dispose(); throw; }
            finally { CloseHandle(info.thread); CloseHandle(info.process); }
        }
        public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFile(string path, uint access, uint share, ref SecurityAttributes security, uint disposition, uint flags, IntPtr template);
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo { public int cb; public string reserved, desktop, title; public uint x, y, xSize, ySize, xCount, yCount, fillAttribute, flags; public short showWindow, reserved2; public IntPtr reservedPointer, stdInput, stdOutput, stdError; }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfo startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    }
}
