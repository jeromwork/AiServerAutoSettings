using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    public enum UpdateButtonState
    {
        Idle,
        Checking,
        Downloading,
        Verifying,
        Installing,
        UpToDate,
        Failed,
        Deferred,
        Updated
    }

    public sealed class UpdateButtonModel
    {
        private readonly object sync = new object();

        public UpdateButtonState State { get; private set; } = UpdateButtonState.Idle;
        public string StatusText { get; private set; } = "";
        public int DownloadPercent { get; private set; }
        public long BytesDownloaded { get; private set; }
        public long TotalBytes { get; private set; }
        public string Version { get; private set; } = "";
        public DateTime? CheckedTime { get; private set; }
        public string ErrorText { get; private set; } = "";
        public string DeferredReason { get; private set; } = "";
        public Action ReleaseSubscription { get; set; }
        public bool IsReleaseSubscribed { get; private set; }

        public event Action<UpdateButtonModel> StateChanged;
        public event Action Changed;

        public bool ButtonEnabled => State == UpdateButtonState.Idle ||
                                     State == UpdateButtonState.UpToDate ||
                                     State == UpdateButtonState.Failed ||
                                     State == UpdateButtonState.Updated;

        public bool IsBusy => !ButtonEnabled;

        public bool OnClick(string occupiedReason = null)
        {
            lock (sync)
            {
                if (IsBusy)
                {
                    return false;
                }
                if (!string.IsNullOrEmpty(occupiedReason))
                {
                    OnDeferredInternal(occupiedReason, null);
                    return true;
                }
                OnCheckingInternal();
                return true;
            }
        }

        public void OnChecking()
        {
            lock (sync)
            {
                OnCheckingInternal();
            }
        }

        private void OnCheckingInternal()
        {
            State = UpdateButtonState.Checking;
            StatusText = "Проверяю…";
            DownloadPercent = 0;
            BytesDownloaded = 0;
            TotalBytes = 0;
            ErrorText = "";
            DeferredReason = "";
            NotifyChanged();
        }

        public void OnDownloading(int pct, long bytes, long size)
        {
            lock (sync)
            {
                State = UpdateButtonState.Downloading;
                DownloadPercent = Math.Max(0, Math.Min(100, pct));
                BytesDownloaded = Math.Max(0, bytes);
                TotalBytes = Math.Max(0, size);

                if (TotalBytes > 0)
                {
                    StatusText = "Скачиваю: " + DownloadPercent + "% (" + FormatMegaBytes(BytesDownloaded) + " из " + FormatMegaBytes(TotalBytes) + " МБ)";
                }
                else
                {
                    StatusText = "Скачиваю: " + FormatMegaBytes(BytesDownloaded) + " МБ";
                }
                NotifyChanged();
            }
        }

        public void OnDownloadProgress(long bytes, long size)
        {
            int pct = size > 0 ? (int)Math.Min(100, Math.Max(0, bytes * 100 / size)) : 0;
            OnDownloading(pct, bytes, size);
        }

        public void OnVerifying()
        {
            lock (sync)
            {
                State = UpdateButtonState.Verifying;
                StatusText = "Проверяю сборку…";
                NotifyChanged();
            }
        }

        public void OnInstalling()
        {
            lock (sync)
            {
                State = UpdateButtonState.Installing;
                StatusText = "Устанавливаю, программа перезапустится";
                NotifyChanged();
            }
        }

        public void OnUpToDate(string version, DateTime? checkedTime = null)
        {
            lock (sync)
            {
                State = UpdateButtonState.UpToDate;
                Version = version ?? "";
                CheckedTime = checkedTime ?? DateTime.Now;
                StatusText = "У вас последняя версия " + Version + " (проверено " + CheckedTime.Value.ToString("HH:mm") + ")";
                NotifyChanged();
            }
        }

        public void OnFailed(string text)
        {
            lock (sync)
            {
                State = UpdateButtonState.Failed;
                ErrorText = text ?? "";
                StatusText = "Ошибка: " + ErrorText;
                NotifyChanged();
            }
        }

        public void OnDeferred(string what, Action subscribe = null)
        {
            lock (sync)
            {
                OnDeferredInternal(what, subscribe);
            }
        }

        public void OnOccupied(string what, Action subscribe = null)
        {
            OnDeferred(what, subscribe);
        }

        private void OnDeferredInternal(string what, Action subscribe)
        {
            State = UpdateButtonState.Deferred;
            DeferredReason = what ?? "";
            StatusText = "Отложено: " + DeferredReason + " — начну, как освободится";
            if (subscribe != null)
            {
                ReleaseSubscription = subscribe;
                IsReleaseSubscribed = true;
                try { subscribe(); } catch { }
            }
            NotifyChanged();
        }

        public bool OnReleased()
        {
            lock (sync)
            {
                if (State != UpdateButtonState.Deferred)
                {
                    return false;
                }
                IsReleaseSubscribed = false;
                ReleaseSubscription = null;
                OnCheckingInternal();
                return true;
            }
        }

        public bool OnUnblocked()
        {
            return OnReleased();
        }

        public void OnUpdated(string version)
        {
            lock (sync)
            {
                State = UpdateButtonState.Updated;
                Version = version ?? "";
                StatusText = "Обновлено до " + Version;
                NotifyChanged();
            }
        }

        public void OnIdle()
        {
            lock (sync)
            {
                State = UpdateButtonState.Idle;
                StatusText = "";
                NotifyChanged();
            }
        }

        public CountingStream CreateCountingStream(Stream inner, long expectedSize, bool reportInitial = true)
        {
            return new CountingStream(inner, expectedSize, (bytes, total) => OnDownloadProgress(bytes, total), reportInitial);
        }

        public static string FormatMegaBytes(long bytes)
        {
            if (bytes <= 0) return "0";
            double mb = bytes / 1048576.0;
            return mb.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture);
        }

        private void NotifyChanged()
        {
            var sc = StateChanged;
            var ch = Changed;
            if (sc != null)
            {
                try { sc(this); } catch { }
            }
            if (ch != null)
            {
                try { ch(); } catch { }
            }
        }
    }

    public sealed class CountingStream : Stream
    {
        private readonly Stream inner;
        private readonly long expectedSize;
        private readonly Action<long, long> onProgress;
        private readonly object sync = new object();
        private long bytesTransferred;
        private int lastReportedPct = -1;

        public CountingStream(Stream inner, long expectedSize = 0, Action<long, long> onProgress = null, bool reportInitial = true)
        {
            this.inner = inner ?? throw new ArgumentNullException(nameof(inner));
            this.expectedSize = expectedSize > 0 ? expectedSize : 0;
            this.onProgress = onProgress;
            if (reportInitial && onProgress != null)
            {
                if (this.expectedSize > 0)
                {
                    lastReportedPct = 0;
                    onProgress(0, this.expectedSize);
                }
                else
                {
                    onProgress(0, 0);
                }
            }
        }

        public long BytesTransferred { get { lock (sync) return bytesTransferred; } }
        public long BytesRead => BytesTransferred;
        public long ExpectedSize => expectedSize;
        public int Percent
        {
            get
            {
                lock (sync)
                {
                    return expectedSize > 0 ? (int)Math.Min(100, Math.Max(0, bytesTransferred * 100 / expectedSize)) : 0;
                }
            }
        }

        public void AddBytes(long count)
        {
            if (count <= 0) return;
            long current;
            bool shouldReport = false;
            lock (sync)
            {
                bytesTransferred += count;
                current = bytesTransferred;
                if (expectedSize > 0)
                {
                    int currentPct = (int)Math.Min(100, Math.Max(0, current * 100 / expectedSize));
                    if (currentPct > lastReportedPct || lastReportedPct < 0)
                    {
                        lastReportedPct = currentPct;
                        shouldReport = true;
                    }
                }
                else
                {
                    shouldReport = true;
                }
            }
            if (shouldReport)
            {
                onProgress?.Invoke(current, expectedSize);
            }
        }

        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => inner.CanWrite;
        public override long Length => inner.Length;

        public override long Position
        {
            get => inner.Position;
            set => inner.Position = value;
        }

        public override void Flush() => inner.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);

        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => inner.SetLength(value);

        public override int Read(byte[] buffer, int offset, int count)
        {
            int read = inner.Read(buffer, offset, count);
            if (read > 0)
            {
                AddBytes(read);
            }
            return read;
        }

        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            int read = await inner.ReadAsync(buffer, offset, count, cancellationToken);
            if (read > 0)
            {
                AddBytes(read);
            }
            return read;
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            inner.Write(buffer, offset, count);
            if (count > 0)
            {
                AddBytes(count);
            }
        }

        public override async Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            await inner.WriteAsync(buffer, offset, count, cancellationToken);
            if (count > 0)
            {
                AddBytes(count);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inner.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
