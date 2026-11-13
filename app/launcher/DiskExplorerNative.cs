#if !PORTABLE_TEST
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace RemoteAgents.Launcher
{
    internal static class DiskExplorerNative
    {
        internal static DiskExplorerService CreateService(string iconDirectory, Action<string> log)
        { return new DiskExplorerService(new DiskExplorerFileSystem(), new DiskExplorerIcons(iconDirectory), new DiskExplorerNotifier(), log); }
        internal static DiskExplorerRegistry CreateRegistry(Action<string> log)
        { return new DiskExplorerRegistry(new DiskExplorerCurrentUserRegistry(), log, DiskExplorerNotifier.AssociationsChanged); }
        internal static void CleanupIcons(string iconDirectory)
        {
            foreach (DiskExplorerKind kind in Enum.GetValues(typeof(DiskExplorerKind))) {
                string path = Path.Combine(iconDirectory, DiskExplorerService.Owner + "." + kind + ".ico");
                if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0) File.Delete(path);
            }
        }
    }
    internal sealed class DiskExplorerNotifier : IDiskExplorerNotifier
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern void SHChangeNotify(uint change, uint flags, string item1, string item2);
        public void Changed(string path)
        {
            SHChangeNotify(0x2000, 0x2005, path, null); // SHCNE_UPDATEITEM, SHCNF_PATHW | FLUSHNOWAIT
            SHChangeNotify(0x1000, 0x2005, Path.GetDirectoryName(path), null);
        }
        internal static void AssociationsChanged() { SHChangeNotify(0x08000000, 0, null, null); }
    }
    internal sealed class DiskExplorerIcons : IDiskExplorerIcons
    {
        readonly string directory;
        internal DiskExplorerIcons(string directory) { this.directory = Path.GetFullPath(directory); }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StockIconInfo
        {
            internal uint Size;
            internal IntPtr Icon;
            internal int SystemIndex, IconIndex;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] internal string Path;
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHGetStockIconInfo(uint id, uint flags, ref StockIconInfo info);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
        public string PathFor(DiskExplorerKind kind)
        {
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, DiskExplorerService.Owner + "." + kind + ".ico");
            if (File.Exists(path)) return path;
            var info = new StockIconInfo { Size = (uint)Marshal.SizeOf(typeof(StockIconInfo)) };
            int error = SHGetStockIconInfo(3, 0x100, ref info); // SIID_FOLDER, SHGSI_ICON, large stock folder
            if (error < 0 || info.Icon == IntPtr.Zero) Marshal.ThrowExceptionForHR(error < 0 ? error : unchecked((int)0x80004005));
            try {
                using (var folder = (Icon)Icon.FromHandle(info.Icon).Clone()) {
                    var sizes = new[] { 16, 32, 48, 256 }; var frames = new List<byte[]>();
                    foreach (int size in sizes) using (var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb)) {
                        using (var g = Graphics.FromImage(bitmap)) {
                            g.Clear(Color.Transparent); g.SmoothingMode = SmoothingMode.AntiAlias; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                            g.DrawIcon(folder, new Rectangle(0, 0, size, size)); DrawBadge(g, kind, size);
                        }
                        using (var stream = new MemoryStream()) { bitmap.Save(stream, ImageFormat.Png); frames.Add(stream.ToArray()); }
                    }
                    string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try {
                        using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) using (var writer = new BinaryWriter(stream)) {
                            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
                            int offset = 6 + 16 * sizes.Length;
                            for (int i = 0; i < sizes.Length; i++) {
                                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i])); writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                                writer.Write((byte)0); writer.Write((byte)0); writer.Write((ushort)1); writer.Write((ushort)32);
                                writer.Write(frames[i].Length); writer.Write(offset); offset += frames[i].Length;
                            }
                            foreach (byte[] frame in frames) writer.Write(frame);
                        }
                        if (!File.Exists(path)) File.Move(temp, path);
                    } finally { if (File.Exists(temp)) File.Delete(temp); }
                }
            } finally { DestroyIcon(info.Icon); }
            return path;
        }
        static void DrawBadge(Graphics g, DiskExplorerKind kind, int size)
        {
            float d = size * .54f, left = size - d, top = size - d;
            Color color = kind == DiskExplorerKind.Synced ? Color.FromArgb(25, 145, 72) : kind == DiskExplorerKind.Error ? Color.FromArgb(205, 47, 47) :
                kind == DiskExplorerKind.Pending || kind == DiskExplorerKind.Paused ? Color.FromArgb(205, 145, 17) :
                kind == DiskExplorerKind.Syncing || kind == DiskExplorerKind.ServerOnly ? Color.FromArgb(35, 118, 208) : Color.FromArgb(105, 112, 120);
            using (var brush = new SolidBrush(color)) g.FillEllipse(brush, left, top, d, d);
            using (var pen = new Pen(Color.White, Math.Max(1, size * .052f))) {
                pen.StartCap = pen.EndCap = LineCap.Round;
                Func<float, float, PointF> p = (x, y) => new PointF(left + x * d, top + y * d);
                if (kind == DiskExplorerKind.Synced) g.DrawLines(pen, new[] { p(.22f, .51f), p(.43f, .7f), p(.78f, .3f) });
                else if (kind == DiskExplorerKind.Paused) { g.DrawLine(pen, p(.37f, .3f), p(.37f, .72f)); g.DrawLine(pen, p(.65f, .3f), p(.65f, .72f)); }
                else if (kind == DiskExplorerKind.ServerOnly) { g.DrawLine(pen, p(.5f, .22f), p(.5f, .75f)); g.DrawLines(pen, new[] { p(.27f, .52f), p(.5f, .75f), p(.73f, .52f) }); }
                else if (kind == DiskExplorerKind.Syncing) {
                    g.DrawArc(pen, left + d * .24f, top + d * .23f, d * .53f, d * .53f, 35, 250);
                    g.DrawLines(pen, new[] { p(.66f, .23f), p(.79f, .25f), p(.77f, .43f) });
                }
                else if (kind == DiskExplorerKind.Error) { g.DrawLine(pen, p(.5f, .25f), p(.5f, .53f)); g.DrawLine(pen, p(.5f, .72f), p(.5f, .73f)); }
                else if (kind == DiskExplorerKind.Offline) g.DrawLine(pen, p(.27f, .73f), p(.73f, .27f));
                else if (kind == DiskExplorerKind.Unavailable) { g.DrawArc(pen, left + d * .33f, top + d * .22f, d * .35f, d * .3f, 170, 270); g.DrawLine(pen, p(.5f, .57f), p(.5f, .58f)); g.DrawLine(pen, p(.5f, .76f), p(.5f, .77f)); }
                else if (kind == DiskExplorerKind.Pending) { foreach (float x in new[] { .28f, .5f, .72f }) g.DrawLine(pen, p(x, .5f), p(x, .51f)); }
                else { g.DrawLine(pen, p(.3f, .5f), p(.7f, .5f)); g.DrawLine(pen, p(.5f, .3f), p(.5f, .7f)); }
            }
        }
    }
}
#endif
