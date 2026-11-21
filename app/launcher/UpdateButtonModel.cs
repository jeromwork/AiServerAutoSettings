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

    public sealed class UpdateButtonModel : IDisposable
    {
        private readonly object sync = new object();
        private readonly Func<DateTime> clock;
        private DateTime phaseStart;
        private IDisposable activeSubscription;

        public UpdateButtonModel(Func<DateTime> clock = null)
        {
            this.clock = clock ?? (() => DateTime.Now);
            this.phaseStart = this.clock();
        }

        public UpdateButtonState State { get; private set; } = UpdateButtonState.Idle;
        public string StatusText { get; private set; } = "";
        public int DownloadPercent { get; private set; }
        public long BytesDownloaded { get; private set; }
        public long TotalBytes { get; private set; }
        public string Version { get; private set; } = "";
        public DateTime? CheckedTime { get; private set; }
        public string ErrorText { get; private set; } = "";
        public string DeferredReason { get; private set; } = "";

        public bool HasReleaseSubscription
        {
            get
            {
                lock (sync)
                {
                    return activeSubscription != null;
                }
            }
        }

        public event Action<UpdateButtonModel> StateChanged;
        public event Action<UpdateButtonState, UpdateButtonState, long, long> PhaseChanged;

        public bool ButtonEnabled => State == UpdateButtonState.Idle ||
                                     State == UpdateButtonState.UpToDate ||
                                     State == UpdateButtonState.Failed ||
                                     State == UpdateButtonState.Updated;

        public bool IsBusy => !ButtonEnabled;

        public bool ShowSpinner => State == UpdateButtonState.Checking ||
                                   State == UpdateButtonState.Downloading ||
                                   State == UpdateButtonState.Verifying ||
                                   State == UpdateButtonState.Installing;

        public bool OnClick(string occupiedReason = null, Func<IDisposable> subscribe = null)
        {
            if (!string.IsNullOrEmpty(occupiedReason))
            {
                lock (sync)
                {
                    if (IsBusy)
                    {
                        return false;
                    }
                }
                return OnDeferred(occupiedReason, subscribe);
            }

            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                if (IsBusy)
                {
                    return false;
                }

                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Checking;
                StatusText = "Проверяю…";
                DownloadPercent = 0;
                BytesDownloaded = 0;
                TotalBytes = 0;
                ErrorText = "";
                DeferredReason = "";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = 0;
            }

            toDispose?.Dispose();
            PhaseChanged?.Invoke(prev, UpdateButtonState.Checking, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnChecking()
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                if (State == UpdateButtonState.Checking ||
                    State == UpdateButtonState.Downloading ||
                    State == UpdateButtonState.Verifying ||
                    State == UpdateButtonState.Installing)
                {
                    return false;
                }

                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Checking;
                StatusText = "Проверяю…";
                DownloadPercent = 0;
                BytesDownloaded = 0;
                TotalBytes = 0;
                ErrorText = "";
                DeferredReason = "";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = 0;
            }

            toDispose?.Dispose();
            PhaseChanged?.Invoke(prev, UpdateButtonState.Checking, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnDownloading(int pct, long bytes, long size)
        {
            UpdateButtonState prev;
            long elapsedMs = 0;
            long currentBytes;
            bool stateChanged = false;

            lock (sync)
            {
                if (State != UpdateButtonState.Checking && State != UpdateButtonState.Downloading)
                {
                    return false;
                }

                prev = State;
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

                if (prev != State)
                {
                    DateTime now = clock();
                    elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                    phaseStart = now;
                    stateChanged = true;
                }
                currentBytes = BytesDownloaded;
            }

            if (stateChanged)
            {
                PhaseChanged?.Invoke(prev, UpdateButtonState.Downloading, elapsedMs, currentBytes);
            }
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnDownloadProgress(long bytes, long size)
        {
            // TODO (этап 2): обработчик прогресса не должен бросать исключения
            int pct = size > 0 ? (int)Math.Min(100, Math.Max(0, bytes * 100 / size)) : 0;
            return OnDownloading(pct, bytes, size);
        }

        public bool OnVerifying()
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;

            lock (sync)
            {
                if (State != UpdateButtonState.Checking && State != UpdateButtonState.Downloading)
                {
                    return false;
                }

                prev = State;
                State = UpdateButtonState.Verifying;
                StatusText = "Проверяю сборку…";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = BytesDownloaded;
            }

            PhaseChanged?.Invoke(prev, UpdateButtonState.Verifying, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnInstalling()
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;

            lock (sync)
            {
                if (State != UpdateButtonState.Verifying && State != UpdateButtonState.Downloading)
                {
                    return false;
                }

                prev = State;
                State = UpdateButtonState.Installing;
                StatusText = "Устанавливаю, программа перезапустится";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = BytesDownloaded;
            }

            PhaseChanged?.Invoke(prev, UpdateButtonState.Installing, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnUpToDate(string version, DateTime? checkedTime = null)
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.UpToDate;
                Version = version ?? "";
                CheckedTime = checkedTime ?? clock();
                DateTime displayTime = CheckedTime.Value.Kind == DateTimeKind.Utc ? CheckedTime.Value.ToLocalTime() : CheckedTime.Value;
                StatusText = "У вас последняя версия " + Version + " (проверено " + displayTime.ToString("HH:mm") + ")";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = BytesDownloaded;
            }

            toDispose?.Dispose();
            PhaseChanged?.Invoke(prev, UpdateButtonState.UpToDate, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnFailed(string text)
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Failed;
                ErrorText = text ?? "";
                StatusText = "Ошибка: " + ErrorText;

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = BytesDownloaded;
            }

            toDispose?.Dispose();
            PhaseChanged?.Invoke(prev, UpdateButtonState.Failed, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnDeferred(string what, Func<IDisposable> subscribe = null)
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Deferred;
                DeferredReason = what ?? "";
                StatusText = "Отложено: " + DeferredReason + " — начну, как освободится";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = BytesDownloaded;
            }

            toDispose?.Dispose();

            IDisposable sub = null;
            string failureReason = null;
            if (subscribe != null)
            {
                try
                {
                    sub = subscribe();
                    if (sub == null)
                    {
                        failureReason = "подписка вернула null";
                    }
                }
                catch (Exception ex)
                {
                    failureReason = ex.Message;
                }
            }

            if (failureReason != null)
            {
                OnFailed("не удалось дождаться освобождения: " + failureReason);
                return false;
            }

            lock (sync)
            {
                if (State == UpdateButtonState.Deferred)
                {
                    activeSubscription = sub;
                    sub = null;
                    // TODO (этап 2): после подписки перепроверить занятость и при свободном вызвать OnReleased()
                }
            }
            sub?.Dispose();

            PhaseChanged?.Invoke(prev, UpdateButtonState.Deferred, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnOccupied(string what, Func<IDisposable> subscribe = null)
        {
            return OnDeferred(what, subscribe);
        }

        public bool OnReleased()
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                if (State != UpdateButtonState.Deferred)
                {
                    return false;
                }

                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Checking;
                StatusText = "Проверяю…";
                DownloadPercent = 0;
                BytesDownloaded = 0;
                TotalBytes = 0;
                ErrorText = "";
                DeferredReason = "";

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = 0;
            }

            toDispose?.Dispose();
            PhaseChanged?.Invoke(prev, UpdateButtonState.Checking, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnUnblocked()
        {
            return OnReleased();
        }

        public bool OnUpdated(string version)
        {
            UpdateButtonState prev;
            long elapsedMs;
            long currentBytes;
            IDisposable toDispose;

            lock (sync)
            {
                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Updated;
                Version = version ?? "";
                StatusText = "Обновлено до " + Version;

                DateTime now = clock();
                elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                phaseStart = now;
                currentBytes = BytesDownloaded;
            }

            toDispose?.Dispose();
            PhaseChanged?.Invoke(prev, UpdateButtonState.Updated, elapsedMs, currentBytes);
            StateChanged?.Invoke(this);
            return true;
        }

        public bool OnIdle()
        {
            UpdateButtonState prev;
            long elapsedMs = 0;
            long currentBytes = 0;
            IDisposable toDispose;

            lock (sync)
            {
                toDispose = activeSubscription;
                activeSubscription = null;

                prev = State;
                State = UpdateButtonState.Idle;
                StatusText = "";
                DownloadPercent = 0;
                BytesDownloaded = 0;
                TotalBytes = 0;
                ErrorText = "";
                DeferredReason = "";

                DateTime now = clock();
                if (prev != UpdateButtonState.Idle)
                {
                    elapsedMs = Math.Max(0, (long)(now - phaseStart).TotalMilliseconds);
                    phaseStart = now;
                }
            }

            toDispose?.Dispose();
            if (prev != UpdateButtonState.Idle)
            {
                PhaseChanged?.Invoke(prev, UpdateButtonState.Idle, elapsedMs, currentBytes);
            }
            StateChanged?.Invoke(this);
            return true;
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

        public void Dispose()
        {
            IDisposable toDispose;
            lock (sync)
            {
                toDispose = activeSubscription;
                activeSubscription = null;
            }
            toDispose?.Dispose();
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
        private long lastReportedMb = -1;

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
                    lastReportedMb = 0;
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
                    long currentMb = current / (1024 * 1024);
                    if (currentMb > lastReportedMb || lastReportedMb < 0)
                    {
                        lastReportedMb = currentMb;
                        shouldReport = true;
                    }
                }
            }
            if (shouldReport)
            {
                // TODO (этап 2): обработчик прогресса не должен бросать исключения
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

        // CountingStream закрывает оборачиваемый поток при Dispose.
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
