using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class DiskRecycle
    {
        internal const uint FOF_NOCONFIRMATION = 0x0010, FOF_ALLOWUNDO = 0x0040, FOF_WANTNUKEWARNING = 0x4000;
        internal const uint FOFX_RECYCLEONDELETE = 0x00080000, FOFX_EARLYFAILURE = 0x00100000;
        internal const uint Flags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_WANTNUKEWARNING | FOFX_RECYCLEONDELETE | FOFX_EARLYFAILURE;
        internal const string Refused = "Папка не помещается в Корзину — освободите место или удалите вручную";
        internal static void Move(string path)
        {
#if PORTABLE_TEST
            throw new IOException("Корзина проверяется только на Windows");
#else
            // ALLOWUNDO alone is only "if possible" (the old VB API could permanently delete).
            // IFileOperation also requests RECYCLEONDELETE, keeps Shell error UI/nuke warnings,
            // and vetoes a delete without TSF_DELETE_RECYCLE_IF_POSSIBLE in PreDeleteItem.
            // https://learn.microsoft.com/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifileoperation-setoperationflags
            // No permanent-delete fallback, including unsupported Windows, network/removable drives.
            if (Environment.OSVersion.Version < new Version(6, 2) || new DriveInfo(Path.GetPathRoot(path)).DriveType != DriveType.Fixed)
                throw new IOException(Refused);
            Exception failure = null;
            var thread = new Thread(() => {
                IFileOperation operation = null; IShellItem item = null;
                try {
                    operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3ad05575-8857-4850-9277-11b85bdb8e09")));
                    operation.SetOperationFlags(Flags);
                    var iid = typeof(IShellItem).GUID;
                    Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item));
                    var sink = new RecycleSink(); operation.DeleteItem(item, sink); operation.PerformOperations();
                    bool aborted; operation.GetAnyOperationsAborted(out aborted);
                    if (aborted || !sink.Confirmed) throw new IOException(Refused);
                    GC.KeepAlive(sink);
                } catch (Exception e) { failure = new IOException(Refused, e); }
                finally {
                    if (item != null) Marshal.FinalReleaseComObject(item);
                    if (operation != null) Marshal.FinalReleaseComObject(operation);
                }
            });
            thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
            if (failure != null) throw failure;
#endif
        }
        // PreserveSig makes the veto an HRESULT returned to Shell, not an unobserved managed exception.
        [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
        internal sealed class RecycleSink : IFileOperationProgressSink
        {
            const uint TSF_DELETE_RECYCLE_IF_POSSIBLE = 0x80;
            const int Cancelled = unchecked((int)0x800704C7);
            bool recycled, failed;
            internal bool Confirmed { get { return recycled && !failed; } }
            public int StartOperations() { return 0; }
            public int FinishOperations(int result) { if (result < 0) failed = true; return 0; }
            public int PreDeleteItem(uint flags, IShellItem item) { if ((flags & TSF_DELETE_RECYCLE_IF_POSSIBLE) != 0) return 0; failed = true; return Cancelled; }
            public int PostDeleteItem(uint flags, IShellItem item, int result, IShellItem created)
            { if (result < 0 || created == null) failed = true; else recycled = true; return 0; }
            public int PreRenameItem(uint flags, IShellItem item, string name) { return 0; }
            public int PostRenameItem(uint flags, IShellItem item, string name, int result, IShellItem created) { return 0; }
            public int PreMoveItem(uint flags, IShellItem item, IShellItem destination, string name) { return 0; }
            public int PostMoveItem(uint flags, IShellItem item, IShellItem destination, string name, int result, IShellItem created) { return 0; }
            public int PreCopyItem(uint flags, IShellItem item, IShellItem destination, string name) { return 0; }
            public int PostCopyItem(uint flags, IShellItem item, IShellItem destination, string name, int result, IShellItem created) { return 0; }
            public int PreNewItem(uint flags, IShellItem destination, string name) { return 0; }
            public int PostNewItem(uint flags, IShellItem destination, string name, string template, uint attributes, int result, IShellItem created) { return 0; }
            public int UpdateProgress(uint total, uint done) { return 0; }
            public int ResetTimer() { return 0; }
            public int PauseTimer() { return 0; }
            public int ResumeTimer() { return 0; }
        }
        [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IShellItem { }
        [ComImport, Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IFileOperationProgressSink
        {
            [PreserveSig] int StartOperations();
            [PreserveSig] int FinishOperations(int result);
            [PreserveSig] int PreRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name);
            [PreserveSig] int PostRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
            [PreserveSig] int PreMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
            [PreserveSig] int PostMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
            [PreserveSig] int PreCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
            [PreserveSig] int PostCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
            [PreserveSig] int PreDeleteItem(uint flags, IShellItem item);
            [PreserveSig] int PostDeleteItem(uint flags, IShellItem item, int result, IShellItem created);
            [PreserveSig] int PreNewItem(uint flags, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
            [PreserveSig] int PostNewItem(uint flags, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes, int result, IShellItem created);
            [PreserveSig] int UpdateProgress(uint total, uint done);
            [PreserveSig] int ResetTimer();
            [PreserveSig] int PauseTimer();
            [PreserveSig] int ResumeTimer();
        }
#if !PORTABLE_TEST
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        static extern int SHCreateItemFromParsingName(string path, IntPtr bind, ref Guid iid, out IShellItem item);
        [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IFileOperation
        {
            void Advise(IFileOperationProgressSink sink, out uint cookie);
            void Unadvise(uint cookie);
            void SetOperationFlags(uint flags);
            void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
            void SetProgressDialog([MarshalAs(UnmanagedType.Interface)] object dialog);
            void SetProperties([MarshalAs(UnmanagedType.Interface)] object properties);
            void SetOwnerWindow(IntPtr window);
            void ApplyPropertiesToItem(IShellItem item);
            void ApplyPropertiesToItems([MarshalAs(UnmanagedType.Interface)] object items);
            void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink sink);
            void RenameItems([MarshalAs(UnmanagedType.Interface)] object items, [MarshalAs(UnmanagedType.LPWStr)] string name);
            void MoveItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink sink);
            void MoveItems([MarshalAs(UnmanagedType.Interface)] object items, IShellItem destination);
            void CopyItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink sink);
            void CopyItems([MarshalAs(UnmanagedType.Interface)] object items, IShellItem destination);
            void DeleteItem(IShellItem item, IFileOperationProgressSink sink);
            void DeleteItems([MarshalAs(UnmanagedType.Interface)] object items);
            void NewItem(IShellItem destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, IFileOperationProgressSink sink);
            void PerformOperations();
            void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
        }
#endif
    }
}
