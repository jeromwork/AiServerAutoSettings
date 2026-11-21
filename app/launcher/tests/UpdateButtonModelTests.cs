using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class UpdateButtonModelTests
    {
        static int count;

        static void Check(bool condition, string name)
        {
            if (!condition) throw new Exception("UpdateButtonModel: " + name);
            count++;
        }

        static void ReadExact(Stream stream, byte[] buffer)
        {
            int offset = 0;
            while (offset < buffer.Length)
            {
                int read = stream.Read(buffer, offset, buffer.Length - offset);
                if (read <= 0) throw new EndOfStreamException();
                offset += read;
            }
        }

        public static int Main(string[] args)
        {
            Run();
            return 0;
        }

        internal static void Run()
        {
            SequenceWithFakeSourceAndManualBytes();
            SecondClickIgnoredWhileBusy();
            SizeZeroModeWithoutPercent();
            UpToDateStateEnablesButton();
            OccupiedAndDeferredState();
            FailedStateEnablesButton();
            CountingStreamStepByStepThrottling();
            CountingStreamWriteSupport();
            UpdatedState();
            TerminalStatesIgnoreLateEvents();
            DeferredUnsubscribesOnFailed();
            InjectedClockUsedForUpToDate();
            SubscribeFailureTransitionsToFailed();
            RecheckAfterSubscribeReleases();
            ProgressHandlerNeverThrows();
            DeadlockFreedomWithStateChangedAndOtherThread();
            PhaseChangedEventFires();
            ShowSpinnerFlag();
            CountingStreamClosesSource();
            Console.WriteLine("PASS: " + count + " update button model checks");
        }

        static void SequenceWithFakeSourceAndManualBytes()
        {
            var model = new UpdateButtonModel();
            Check(model.State == UpdateButtonState.Idle, "initial state is idle");
            Check(model.ButtonEnabled, "idle button is enabled");
            Check(!model.IsBusy, "idle is not busy");
            Check(!model.ShowSpinner, "idle has no spinner");

            Check(model.OnClick(), "click accepted");
            Check(model.State == UpdateButtonState.Checking, "state is checking");

            long totalSize = 10 * 1024 * 1024; // 10 MB
            byte[] fakeData = new byte[totalSize];
            using (var fakeSource = new MemoryStream(fakeData))
            using (var stream = model.CreateCountingStream(fakeSource, totalSize))
            {
                // Initial progress: 0%
                Check(model.State == UpdateButtonState.Downloading, "entering downloading on stream creation");
                Check(model.DownloadPercent == 0, "initial percent is 0%");
                Check(model.StatusText.Contains("0%"), "status contains 0%: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 0% (0 из 10 МБ)", "status text matches: " + model.StatusText);
                Check(!model.ButtonEnabled, "button disabled while downloading");
                Check(model.IsBusy, "busy while downloading");
                Check(model.ShowSpinner, "spinner visible while downloading");

                // Manual read of 5 MB (50%) in exact chunks
                byte[] buffer = new byte[5 * 1024 * 1024];
                ReadExact(stream, buffer);
                Check(model.DownloadPercent == 50, "percent is 50%");
                Check(model.StatusText.Contains("50%"), "status contains 50%: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 50% (5 из 10 МБ)", "status text matches 50%: " + model.StatusText);
                Check(model.ShowSpinner, "spinner still visible at 50%");

                // Manual read of remaining 5 MB (100%)
                ReadExact(stream, buffer);
                Check(model.DownloadPercent == 100, "percent is 100%");
                Check(model.StatusText.Contains("100%"), "status contains 100%: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 100% (10 из 10 МБ)", "status text matches 100%: " + model.StatusText);
                Check(model.ShowSpinner, "spinner still visible at 100%");
            }

            // Sequence transitions to Verifying:
            Check(model.OnVerifying(), "transition to verifying accepted");
            Check(model.State == UpdateButtonState.Verifying, "state is verifying");
            Check(model.StatusText.Contains("Проверяю сборку"), "status contains Проверяю сборку: " + model.StatusText);
            Check(model.StatusText == "Проверяю сборку…", "verifying text matches");
            Check(!model.ButtonEnabled, "button disabled while verifying");
            Check(model.IsBusy, "busy while verifying");
            Check(model.ShowSpinner, "spinner visible while verifying");

            // Sequence transitions to Installing:
            Check(model.OnInstalling(), "transition to installing accepted");
            Check(model.State == UpdateButtonState.Installing, "state is installing");
            Check(model.StatusText.Contains("Устанавливаю"), "status contains Устанавливаю: " + model.StatusText);
            Check(model.StatusText == "Устанавливаю, программа перезапустится", "installing text matches");
            Check(!model.ButtonEnabled, "button disabled while installing");
            Check(model.IsBusy, "busy while installing");
            Check(model.ShowSpinner, "spinner visible while installing");
        }

        static void SecondClickIgnoredWhileBusy()
        {
            var model = new UpdateButtonModel();
            Check(model.OnClick(), "first click accepted");
            Check(model.State == UpdateButtonState.Checking, "state is checking");
            Check(model.StatusText == "Проверяю…", "checking text");
            Check(!model.ButtonEnabled, "button disabled during checking");
            Check(model.IsBusy, "busy during checking");
            Check(model.ShowSpinner, "spinner visible during checking");

            // Second click during checking: ignored
            Check(!model.OnClick(), "second click during checking is ignored");
            Check(model.State == UpdateButtonState.Checking, "state remains checking");

            // Downloading: click ignored
            model.OnDownloading(50, 50, 100);
            Check(!model.OnClick(), "click during downloading ignored");
            Check(model.State == UpdateButtonState.Downloading, "state remains downloading");

            // Verifying: click ignored
            model.OnVerifying();
            Check(!model.OnClick(), "click during verifying ignored");
            Check(model.State == UpdateButtonState.Verifying, "state remains verifying");

            // Installing: click ignored
            model.OnInstalling();
            Check(!model.OnClick(), "click during installing ignored");
            Check(model.State == UpdateButtonState.Installing, "state remains installing");

            // Deferred: click ignored
            model.OnDeferred("конфиг");
            Check(!model.OnClick(), "click during deferred ignored");
            Check(model.State == UpdateButtonState.Deferred, "state remains deferred");
            Check(!model.ShowSpinner, "spinner not visible when deferred");
        }

        static void SizeZeroModeWithoutPercent()
        {
            var model = new UpdateButtonModel();
            Check(model.OnClick(), "click accepted");
            Check(model.State == UpdateButtonState.Checking, "state is checking");
            var reports = new List<long>();
            using (var fakeSource = new MemoryStream(new byte[15 * 1024 * 1024]))
            using (var stream = new CountingStream(fakeSource, 0, (bytes, size) => { reports.Add(bytes); model.OnDownloadProgress(bytes, size); }, reportInitial: true))
            {
                Check(model.State == UpdateButtonState.Downloading, "downloading state with size 0");
                Check(model.DownloadPercent == 0, "percent is 0");
                Check(!model.StatusText.Contains("%"), "status text has no percent at 0: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 0 МБ", "matches zero text: " + model.StatusText);
                Check(reports.Count == 1 && reports[0] == 0, "initial 0 report");

                // Small reads (< 1 MB total) should NOT trigger progress
                byte[] chunk = new byte[100 * 1024]; // 100 KB
                for (int i = 0; i < 5; i++)
                {
                    ReadExact(stream, chunk);
                }
                Check(reports.Count == 1, "small reads under 1 MB do not trigger progress (reports=" + reports.Count + ")");

                // Read enough to reach exactly 1 MB (total 1024 * 1024)
                byte[] chunkRestTo1Mb = new byte[1024 * 1024 - 500 * 1024];
                ReadExact(stream, chunkRestTo1Mb);
                Check(reports.Count == 2, "crossing 1 MB triggers progress (reports=" + reports.Count + ")");
                Check(model.StatusText == "Скачиваю: 1 МБ", "matches 1 MB text: " + model.StatusText);

                // Read 4 MB more (to reach 5 MB)
                byte[] chunk4mb = new byte[4 * 1024 * 1024];
                ReadExact(stream, chunk4mb);
                Check(model.BytesDownloaded >= 5 * 1024 * 1024, "downloaded >= 5 MB");
                Check(!model.StatusText.Contains("%"), "status text has no percent at 5 MB: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 5 МБ", "matches 5 MB text: " + model.StatusText);
            }
        }

        static void UpToDateStateEnablesButton()
        {
            var model = new UpdateButtonModel();
            model.OnClick();
            Check(!model.ButtonEnabled, "busy checking");

            var time = new DateTime(2026, 11, 21, 14, 30, 0);
            Check(model.OnUpToDate("1.5.0", time), "uptodate accepted");
            Check(model.State == UpdateButtonState.UpToDate, "state is uptodate");
            Check(model.ButtonEnabled, "button is enabled when up to date");
            Check(!model.IsBusy, "not busy when up to date");
            Check(!model.ShowSpinner, "no spinner when up to date");
            Check(model.StatusText == "У вас последняя версия 1.5.0 (проверено 14:30)", "uptodate status text: " + model.StatusText);

            // Can click again when up to date
            Check(model.OnClick(), "click accepted when up to date");
            Check(model.State == UpdateButtonState.Checking, "re-enters checking");
        }

        static void OccupiedAndDeferredState()
        {
            var model = new UpdateButtonModel();
            bool subscribed = false;
            Check(model.OnDeferred("применение конфига", () => { subscribed = true; return new TestDisposable(); }), "deferred accepted");

            Check(model.State == UpdateButtonState.Deferred, "state is deferred");
            Check(model.StatusText == "Отложено: применение конфига — начну, как освободится", "deferred text matches: " + model.StatusText);
            Check(!model.ButtonEnabled, "button disabled when deferred");
            Check(model.IsBusy, "busy when deferred");
            Check(!model.ShowSpinner, "no spinner when deferred");
            Check(subscribed, "subscribed to release event");
            Check(model.HasReleaseSubscription, "model reports release subscribed");

            // Second click during deferred is ignored
            Check(!model.OnClick(), "click during deferred is ignored");

            // Release triggers transition to Checking
            Check(model.OnReleased(), "release transitions state");
            Check(!model.HasReleaseSubscription, "subscription cleared after release");
            Check(model.State == UpdateButtonState.Checking, "now checking");
            Check(model.StatusText == "Проверяю…", "status is checking: " + model.StatusText);
            Check(model.ShowSpinner, "spinner visible after release");

            // Calling OnReleased when not deferred returns false
            Check(!model.OnReleased(), "release returns false when not deferred");

            // Test OnClick with occupiedReason
            var model2 = new UpdateButtonModel();
            Check(model2.OnClick("диск"), "click with occupied reason sets deferred");
            Check(model2.State == UpdateButtonState.Deferred, "state deferred");
            Check(model2.StatusText == "Отложено: диск — начну, как освободится", "text matches");
        }

        static void FailedStateEnablesButton()
        {
            var model = new UpdateButtonModel();
            model.OnClick();
            Check(model.OnFailed("нет связи с сервером"), "failed accepted");

            Check(model.State == UpdateButtonState.Failed, "state is failed");
            Check(model.ButtonEnabled, "button enabled after failure");
            Check(!model.IsBusy, "not busy after failure");
            Check(!model.ShowSpinner, "no spinner when failed");
            Check(model.StatusText == "Ошибка: нет связи с сервером", "failed text matches: " + model.StatusText);

            // Can retry after failure
            Check(model.OnClick(), "click allowed after failure");
            Check(model.State == UpdateButtonState.Checking, "re-enters checking");
        }

        static void CountingStreamStepByStepThrottling()
        {
            var progressList = new List<long>();
            using (var ms = new MemoryStream(new byte[100]))
            using (var cs = new CountingStream(ms, 100, (bytes, size) => progressList.Add(bytes), reportInitial: false))
            {
                cs.AddBytes(0);
                Check(progressList.Count == 0, "0 bytes does not fire progress");

                cs.AddBytes(1); // 1%
                Check(progressList.Count == 1 && progressList[0] == 1, "1% fires progress");

                cs.AddBytes(1); // 2%
                Check(progressList.Count == 2 && progressList[1] == 2, "2% fires progress");
            }

            var progressPcts = new List<int>();
            using (var ms = new MemoryStream(new byte[1000]))
            using (var cs = new CountingStream(ms, 1000, (bytes, size) => progressPcts.Add((int)(bytes * 100 / size)), reportInitial: false))
            {
                cs.AddBytes(5); // 0.5% -> pct 0
                Check(progressPcts.Count == 1 && progressPcts[0] == 0, "first report at pct 0");

                cs.AddBytes(3); // total 8 bytes -> pct 0, no new report
                Check(progressPcts.Count == 1, "still pct 0, no report");

                cs.AddBytes(5); // total 13 bytes -> pct 1, report!
                Check(progressPcts.Count == 2 && progressPcts[1] == 1, "reported 1%");

                cs.AddBytes(2); // total 15 bytes -> pct 1, no report
                Check(progressPcts.Count == 2, "still 1%");

                cs.AddBytes(10); // total 25 bytes -> pct 2, report!
                Check(progressPcts.Count == 3 && progressPcts[2] == 2, "reported 2%");
            }
        }

        static void CountingStreamWriteSupport()
        {
            long transferred = 0;
            using (var dest = new MemoryStream())
            using (var cs = new CountingStream(dest, 200, (bytes, size) => transferred = bytes, reportInitial: false))
            {
                byte[] chunk = new byte[50];
                cs.Write(chunk, 0, chunk.Length);
                Check(transferred == 50, "write tracked: " + transferred);
                Check(cs.Percent == 25, "percent is 25%: " + cs.Percent);
            }
        }

        static void UpdatedState()
        {
            var model = new UpdateButtonModel();
            Check(model.OnUpdated("1.6.0"), "updated accepted");
            Check(model.State == UpdateButtonState.Updated, "state is updated");
            Check(model.ButtonEnabled, "button enabled when updated");
            Check(!model.ShowSpinner, "no spinner when updated");
            Check(model.StatusText == "Обновлено до 1.6.0", "updated status text");
        }

        static void TerminalStatesIgnoreLateEvents()
        {
            // 1. After OnFailed:
            var failedModel = new UpdateButtonModel();
            failedModel.OnClick();
            failedModel.OnFailed("таймаут загрузки");
            Check(failedModel.State == UpdateButtonState.Failed, "is failed");

            Check(!failedModel.OnDownloading(50, 50, 100), "late downloading rejected after failed");
            Check(failedModel.State == UpdateButtonState.Failed, "state unchanged after late downloading");

            Check(!failedModel.OnDownloadProgress(75, 100), "late progress rejected after failed");
            Check(failedModel.State == UpdateButtonState.Failed, "state unchanged after late progress");

            Check(!failedModel.OnVerifying(), "late verifying rejected after failed");
            Check(failedModel.State == UpdateButtonState.Failed, "state unchanged after late verifying");

            Check(!failedModel.OnInstalling(), "late installing rejected after failed");
            Check(failedModel.State == UpdateButtonState.Failed, "state unchanged after late installing");

            // 2. After OnUpToDate:
            var upToDateModel = new UpdateButtonModel();
            upToDateModel.OnClick();
            upToDateModel.OnUpToDate("1.5.0");
            Check(upToDateModel.State == UpdateButtonState.UpToDate, "is uptodate");

            Check(!upToDateModel.OnDownloading(50, 50, 100), "late downloading rejected after uptodate");
            Check(upToDateModel.State == UpdateButtonState.UpToDate, "state unchanged after late downloading");

            Check(!upToDateModel.OnDownloadProgress(75, 100), "late progress rejected after uptodate");
            Check(upToDateModel.State == UpdateButtonState.UpToDate, "state unchanged after late progress");

            Check(!upToDateModel.OnVerifying(), "late verifying rejected after uptodate");
            Check(upToDateModel.State == UpdateButtonState.UpToDate, "state unchanged after late verifying");

            Check(!upToDateModel.OnInstalling(), "late installing rejected after uptodate");
            Check(upToDateModel.State == UpdateButtonState.UpToDate, "state unchanged after late installing");
        }

        static void DeferredUnsubscribesOnFailed()
        {
            var model = new UpdateButtonModel();
            bool subscribed = false;
            bool disposed = false;

            var sub = new ActionDisposable(() => disposed = true);
            Check(model.OnClick("диск", () => { subscribed = true; return sub; }), "click occupied accepted");
            Check(model.State == UpdateButtonState.Deferred, "state is deferred");
            Check(subscribed, "subscribed called");
            Check(!disposed, "not disposed yet");
            Check(model.HasReleaseSubscription, "has active subscription");

            // Failure while deferred should unsubscribe / dispose
            Check(model.OnFailed("ошибка отмены"), "failed accepted while deferred");
            Check(model.State == UpdateButtonState.Failed, "state is failed");
            Check(disposed, "subscription was disposed on failed");
            Check(!model.HasReleaseSubscription, "no active subscription");
        }

        static void InjectedClockUsedForUpToDate()
        {
            var fixedTime = new DateTime(2026, 11, 21, 18, 42, 0, DateTimeKind.Local);
            var model = new UpdateButtonModel(() => fixedTime);
            model.OnClick();
            Check(model.OnUpToDate("3.0.0"), "uptodate accepted without explicit time");
            Check(model.CheckedTime == fixedTime, "injected clock time used");
            Check(model.StatusText == "У вас последняя версия 3.0.0 (проверено 18:42)", "status text matches injected clock: " + model.StatusText);

            var unspecTime = new DateTime(2026, 11, 21, 19, 15, 0, DateTimeKind.Unspecified);
            var modelUnspec = new UpdateButtonModel(() => unspecTime);
            modelUnspec.OnClick();
            modelUnspec.OnUpToDate("3.1.0");
            Check(modelUnspec.StatusText == "У вас последняя версия 3.1.0 (проверено 19:15)", "status text matches unspecified time: " + modelUnspec.StatusText);

            var utcTime = new DateTime(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);
            var modelUtc = new UpdateButtonModel(() => utcTime);
            modelUtc.OnClick();
            modelUtc.OnUpToDate("3.2.0");
            string expectedLocal = utcTime.ToLocalTime().ToString("HH:mm");
            Check(modelUtc.StatusText == "У вас последняя версия 3.2.0 (проверено " + expectedLocal + ")", "utc time converted to local: " + modelUtc.StatusText);
        }

        static void SubscribeFailureTransitionsToFailed()
        {
            // Case 1: subscribe throws exception
            var modelThrow = new UpdateButtonModel();
            bool res1 = modelThrow.OnClick("диск", () => throw new InvalidOperationException("шина недоступна"));
            Check(!res1, "OnClick returned false on subscribe exception");
            Check(modelThrow.State == UpdateButtonState.Failed, "state is failed on subscribe exception");
            Check(modelThrow.ErrorText.Contains("не удалось дождаться освобождения: шина недоступна"), "error text matches exception: " + modelThrow.ErrorText);
            Check(modelThrow.StatusText == "Ошибка: не удалось дождаться освобождения: шина недоступна", "status text matches: " + modelThrow.StatusText);
            Check(modelThrow.ButtonEnabled, "button enabled after failed subscribe");

            // Case 2: subscribe returns null
            var modelNull = new UpdateButtonModel();
            bool res2 = modelNull.OnClick("диск", () => null);
            Check(!res2, "OnClick returned false on subscribe null");
            Check(modelNull.State == UpdateButtonState.Failed, "state is failed on subscribe null");
            Check(modelNull.ErrorText.StartsWith("не удалось дождаться освобождения:"), "error text starts with failure message: " + modelNull.ErrorText);
            Check(modelNull.StatusText.StartsWith("Ошибка: не удалось дождаться освобождения:"), "status text starts with failure message: " + modelNull.StatusText);
            Check(modelNull.ButtonEnabled, "button enabled after null subscribe");

            // Case 3: OnDeferred directly with exception
            var modelDefThrow = new UpdateButtonModel();
            bool res3 = modelDefThrow.OnDeferred("конфиг", () => throw new Exception("сбой соединения"));
            Check(!res3, "OnDeferred returned false on exception");
            Check(modelDefThrow.State == UpdateButtonState.Failed, "OnDeferred state is failed on exception");

            // Case 4: OnDeferred directly with null
            var modelDefNull = new UpdateButtonModel();
            bool res4 = modelDefNull.OnDeferred("конфиг", () => null);
            Check(!res4, "OnDeferred returned false on null");
            Check(modelDefNull.State == UpdateButtonState.Failed, "OnDeferred state is failed on null");
        }

        static void DeadlockFreedomWithStateChangedAndOtherThread()
        {
            var model = new UpdateButtonModel();
            int notifications = 0;
            bool threadSucceeded = false;

            // Handler starts another thread calling model.OnClick() while StateChanged is in progress.
            // If NotifyChanged was called under lock(sync), this would deadlock!
            model.StateChanged += m =>
            {
                notifications++;
                if (notifications == 1)
                {
                    var thread = new Thread(() =>
                    {
                        // Calling model from another thread during notification
                        model.OnClick();
                        threadSucceeded = true;
                    });
                    thread.Start();

                    // Предохранитель (конституция 4а): событие завершения потока недоступно, если возник взаимный захват блокировок; при срабатывании — прерывание теста, успех не объявляет.
                    const int DeadlockFuseMs = 5000;
                    bool joined = thread.Join(DeadlockFuseMs);
                    Check(joined, "other thread completed without deadlock");
                }
            };

            Check(model.OnClick(), "initial click");
            Check(threadSucceeded, "thread completed safely inside StateChanged");
            Check(notifications >= 1, "notifications fired");
        }

        static void PhaseChangedEventFires()
        {
            DateTime current = new DateTime(2026, 11, 21, 10, 0, 0, DateTimeKind.Utc);
            var model = new UpdateButtonModel(() => current);

            var phases = new List<Tuple<UpdateButtonState, UpdateButtonState, long, long>>();
            model.PhaseChanged += (prev, next, ms, bytes) => phases.Add(Tuple.Create(prev, next, ms, bytes));

            model.OnClick(); // Idle -> Checking
            current = current.AddMilliseconds(250);

            model.OnDownloading(10, 1024 * 1024, 10 * 1024 * 1024); // Checking -> Downloading
            current = current.AddMilliseconds(1200);

            model.OnVerifying(); // Downloading -> Verifying
            current = current.AddMilliseconds(800);

            model.OnInstalling(); // Verifying -> Installing

            Check(phases.Count == 4, "4 phase transitions recorded (actual=" + phases.Count + ")");
            Check(phases[0].Item1 == UpdateButtonState.Idle && phases[0].Item2 == UpdateButtonState.Checking, "transition 1");
            Check(phases[1].Item1 == UpdateButtonState.Checking && phases[1].Item2 == UpdateButtonState.Downloading && phases[1].Item3 == 250, "transition 2 elapsed 250ms");
            Check(phases[2].Item1 == UpdateButtonState.Downloading && phases[2].Item2 == UpdateButtonState.Verifying && phases[2].Item3 == 1200, "transition 3 elapsed 1200ms");
            Check(phases[3].Item1 == UpdateButtonState.Verifying && phases[3].Item2 == UpdateButtonState.Installing && phases[3].Item3 == 800, "transition 4 elapsed 800ms");
        }

        static void ShowSpinnerFlag()
        {
            var model = new UpdateButtonModel();
            Check(!model.ShowSpinner, "idle has no spinner");

            model.OnChecking();
            Check(model.ShowSpinner, "checking has spinner");

            model.OnDownloading(50, 50, 100);
            Check(model.ShowSpinner, "downloading has spinner");

            model.OnVerifying();
            Check(model.ShowSpinner, "verifying has spinner");

            model.OnInstalling();
            Check(model.ShowSpinner, "installing has spinner");

            model.OnUpToDate("1.0.0");
            Check(!model.ShowSpinner, "uptodate has no spinner");

            model.OnFailed("ошибка");
            Check(!model.ShowSpinner, "failed has no spinner");

            model.OnDeferred("занято");
            Check(!model.ShowSpinner, "deferred has no spinner");

            model.OnUpdated("1.1.0");
            Check(!model.ShowSpinner, "updated has no spinner");
        }

        static void CountingStreamClosesSource()
        {
            bool sourceClosed = false;
            var memory = new TrackedMemoryStream(() => sourceClosed = true);
            using (var cs = new CountingStream(memory, 100))
            {
                Check(!sourceClosed, "source open while CountingStream active");
            }
            Check(sourceClosed, "CountingStream.Dispose closes underlying stream");
        }

        static void RecheckAfterSubscribeReleases()
        {
            // Занятое освободилось между проверкой и подпиской: после подписки перепроверка зовёт OnReleased().
            var model = new UpdateButtonModel();
            int disposed = 0;
            var phases = new List<string>();
            model.PhaseChanged += (from, to, ms, bytes) => phases.Add(from + ">" + to);
            Check(model.OnClick("диск", () => new ActionDisposable(() => disposed++), () => false), "click returns true when released right after subscribe");
            Check(model.State == UpdateButtonState.Checking, "released at once -> Checking");
            Check(disposed == 1 && !model.HasReleaseSubscription, "subscription disposed on release");
            Check(phases.Count == 2 && phases[0] == "Idle>Deferred" && phases[1] == "Deferred>Checking", "deferred then checking events in order");

            // Всё ещё занято: остаётся Deferred с подпиской; потом событие освобождения вручную.
            var model2 = new UpdateButtonModel();
            Check(model2.OnClick("диск", () => new TestDisposable(), () => true), "click occupied");
            Check(model2.State == UpdateButtonState.Deferred && model2.HasReleaseSubscription, "still occupied -> Deferred with subscription");
            Check(model2.OnReleased() && model2.State == UpdateButtonState.Checking, "manual release event -> Checking");

            // Проверка занятости бросила: считаем свободным, не зависаем в Deferred.
            var model3 = new UpdateButtonModel();
            model3.OnClick("диск", () => new TestDisposable(), () => { throw new InvalidOperationException("x"); });
            Check(model3.State == UpdateButtonState.Checking, "occupancy check failure treated as free");
        }

        static void ProgressHandlerNeverThrows()
        {
            var model = new UpdateButtonModel();
            model.OnClick();
            model.StateChanged += m => { throw new InvalidOperationException("ui"); };
            bool threw = false;
            try { Check(!model.OnDownloadProgress(10, 100), "progress reports false when handler throws"); }
            catch (InvalidOperationException) { threw = true; }
            Check(!threw, "OnDownloadProgress does not throw");

            // CountingStream: падение обработчика не обрывает чтение.
            int calls = 0;
            using (var cs = new CountingStream(new MemoryStream(new byte[300]), 300, (b, t) => { calls++; throw new InvalidOperationException("ui"); }, true))
            {
                var buf = new byte[100];
                int total = 0, n;
                while ((n = cs.Read(buf, 0, buf.Length)) > 0) total += n;
                Check(total == 300, "stream fully read despite throwing handler");
                Check(calls > 0, "handler was invoked");
            }
        }

        private sealed class TestDisposable : IDisposable
        {
            public void Dispose() { }
        }

        private sealed class ActionDisposable : IDisposable
        {
            private readonly Action onDispose;
            public ActionDisposable(Action onDispose) { this.onDispose = onDispose; }
            public void Dispose() { onDispose?.Invoke(); }
        }

        private sealed class TrackedMemoryStream : MemoryStream
        {
            private readonly Action onClose;
            public TrackedMemoryStream(Action onClose) { this.onClose = onClose; }
            protected override void Dispose(bool disposing)
            {
                if (disposing) onClose?.Invoke();
                base.Dispose(disposing);
            }
        }
    }
}
