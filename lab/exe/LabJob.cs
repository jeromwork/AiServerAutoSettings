using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace RemoteAgents.Lab
{
    // Job Object с KILL_ON_JOB_CLOSE: умер EXE (даже принудительно) -- Windows сама гасит Python и всех его детей.
    // P/Invoke -- копия приёмов app/launcher/NativeJob.cs (сам файл не трогаем).
    internal sealed class LabJob : IDisposable
    {
        readonly SafeFileHandle handle;
        int disposed;
        public LabJob()
        {
            var raw = CreateJobObject(IntPtr.Zero, null); if (raw == IntPtr.Zero) throw new Win32Exception();
            handle = new SafeFileHandle(raw, true);
            var limits = new ExtendedLimits(); limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) { var error = new Win32Exception(); Dispose(); throw error; }
        }
        // Process.Start, затем сразу Assign: за доли секунды между ними Python ничего запустить не успевает
        // (ему нужно загрузить интерпретатор и разобрать код), поэтому неучтённых детей не будет.
        public void Assign(Process process)
        {
            if (Volatile.Read(ref disposed) != 0) throw new ObjectDisposedException("LabJob");
            if (!AssignProcessToJobObject(handle, process.Handle)) throw new Win32Exception();
        }
        // Гасит всех, кто сейчас в Job. Сам Job остаётся годным: после Terminate в него можно назначать новый Python.
        public void Terminate()
        {
            if (Volatile.Read(ref disposed) != 0) return;
            TerminateJobObject(handle, 1);
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            try { TerminateJobObject(handle, 1); } finally { handle.Dispose(); }
        }
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(SafeFileHandle job, uint code);
    }
}
