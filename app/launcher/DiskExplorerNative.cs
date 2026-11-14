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
                            if (kind == DiskExplorerKind.ServerOnly) {
                                using (var source = folder.ToBitmap()) using (var attributes = new ImageAttributes()) {
                                    var faded = new ColorMatrix { Matrix33 = .45f }; attributes.SetColorMatrix(faded);
                                    g.DrawImage(source, new Rectangle(0, 0, size, size), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel, attributes);
                                }
                            } else g.DrawIcon(folder, new Rectangle(0, 0, size, size));
                            DrawBadge(g, kind, size);
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
            if (kind == DiskExplorerKind.Local) return;
            float d = size * .54f, left = size - d, top = size - d;
            if (kind == DiskExplorerKind.ServerOnly) {
                using (var cloud = new SolidBrush(Color.FromArgb(110, 115, 120))) {
                    g.FillEllipse(cloud, left + d * .05f, top + d * .43f, d * .48f, d * .46f);
                    g.FillEllipse(cloud, left + d * .27f, top + d * .21f, d * .48f, d * .63f);
                    g.FillEllipse(cloud, left + d * .56f, top + d * .44f, d * .4f, d * .45f);
                    g.FillRectangle(cloud, left + d * .25f, top + d * .62f, d * .5f, d * .26f);
                }
                return;
            }
            Color color = kind == DiskExplorerKind.Synced ? Color.FromArgb(25, 145, 72) :
                kind == DiskExplorerKind.Syncing ? Color.FromArgb(35, 118, 208) : Color.FromArgb(218, 158, 20);
            using (var brush = new SolidBrush(color)) g.FillEllipse(brush, left, top, d, d);
            using (var pen = new Pen(Color.White, Math.Max(1, size * .052f))) {
                pen.StartCap = pen.EndCap = LineCap.Round;
                Func<float, float, PointF> p = (x, y) => new PointF(left + x * d, top + y * d);
                if (kind == DiskExplorerKind.Synced) g.DrawLines(pen, new[] { p(.22f, .51f), p(.43f, .7f), p(.78f, .3f) });
                else if (kind == DiskExplorerKind.Syncing) {
                    var ring = new RectangleF(left + d * .23f, top + d * .23f, d * .54f, d * .54f);
                    g.DrawArc(pen, ring, 20, 135); g.DrawArc(pen, ring, 200, 135);
                    g.DrawLines(pen, new[] { p(.25f, .47f), p(.26f, .62f), p(.42f, .62f) });
                    g.DrawLines(pen, new[] { p(.75f, .53f), p(.74f, .38f), p(.58f, .38f) });
                }
                else { g.DrawLine(pen, p(.5f, .25f), p(.5f, .53f)); g.DrawLine(pen, p(.5f, .72f), p(.5f, .73f)); }
            }
        }
    }
}
#endif
