using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace RemoteAgents.Launcher
{
    internal sealed class NativeJob : IDisposable
    {
        readonly SafeFileHandle handle;
        int disposed;
        public NativeJob()
        {
            var raw = CreateJobObject(IntPtr.Zero, null); if (raw == IntPtr.Zero) throw new Win32Exception();
            handle = new SafeFileHandle(raw, true);
            var limits = new ExtendedLimits(); limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) { var error = new Win32Exception(); Dispose(); throw error; }
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
            bool pinned = false, initialized = false;
            IntPtr attributes = IntPtr.Zero, jobs = IntPtr.Zero, handles = IntPtr.Zero;
            try {
                // Keep the native handle valid while building the attribute list, even
                // when the independent fail-open lease disposes this Job concurrently.
                handle.DangerousAddRef(ref pinned);
                if (Volatile.Read(ref disposed) != 0) throw new ObjectDisposedException("NativeJob");
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, inherit ? 2 : 1, 0, ref size);
                attributes = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attributes, inherit ? 2 : 1, 0, ref size)) throw new Win32Exception();
                initialized = true;
                jobs = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobs, handle.DangerousGetHandle());
                // Windows 10+: atomic membership closes the owner-death window
                // between CreateProcess(CREATE_SUSPENDED) and a later Assign call.
                if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x0002000D), jobs, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
                if (inherit) {
                    handles = Marshal.AllocHGlobal(3 * IntPtr.Size);
                    Marshal.WriteIntPtr(handles, 0, startup.stdInput);
                    Marshal.WriteIntPtr(handles, IntPtr.Size, startup.stdOutput);
                    Marshal.WriteIntPtr(handles, 2 * IntPtr.Size, startup.stdError);
                    if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x00020002), handles, new IntPtr(3 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
                }
                startup.cb = Marshal.SizeOf(typeof(StartupInfoEx));
                var extended = new StartupInfoEx { Startup = startup, Attributes = attributes };
                // CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT.
                // No unowned child exists, even if this process is killed inside CreateProcess.
                if (!CreateProcess(null, new StringBuilder(Files.Quote(exe) + " " + Files.Arguments(args)), IntPtr.Zero, IntPtr.Zero, inherit, 0x08080004, IntPtr.Zero, cwd, ref extended, out info)) throw new Win32Exception();
                Process process = null;
                try {
                    if (Volatile.Read(ref disposed) != 0) throw new ObjectDisposedException("NativeJob");
                    process = Process.GetProcessById((int)info.pid); var processHandle = process.Handle;
                    if (ResumeThread(info.thread) == uint.MaxValue) throw new Win32Exception();
                    return process;
                } catch { TerminateProcess(info.process, 1); if (process != null) process.Dispose(); throw; }
                finally { CloseHandle(info.thread); CloseHandle(info.process); }
            } finally {
                if (initialized) DeleteProcThreadAttributeList(attributes);
                foreach (var memory in new[] { attributes, jobs, handles }) if (memory != IntPtr.Zero) Marshal.FreeHGlobal(memory);
                if (pinned) handle.DangerousRelease();
            }
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            // Do not let an in-flight CreateProcess's SafeHandle pin delay fail-open.
            try { TerminateJobObject(handle, 1); } finally { handle.Dispose(); }
        }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFile(string path, uint access, uint share, ref SecurityAttributes security, uint disposition, uint flags, IntPtr template);
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo { public int cb; public string reserved, desktop, title; public uint x, y, xSize, ySize, xCount, yCount, fillAttribute, flags; public short showWindow, reserved2; public IntPtr reservedPointer, stdInput, stdOutput, stdError; }
        [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(SafeFileHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfoEx startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    }
}
