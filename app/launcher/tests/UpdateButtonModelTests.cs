using System;
using System.Collections.Generic;
using System.IO;

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
            Console.WriteLine("PASS: " + count + " update button model checks");
        }

        static void SequenceWithFakeSourceAndManualBytes()
        {
            var model = new UpdateButtonModel();
            Check(model.State == UpdateButtonState.Idle, "initial state is idle");
            Check(model.ButtonEnabled, "idle button is enabled");
            Check(!model.IsBusy, "idle is not busy");

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

                // Manual read / feed of 5 MB (50%)
                byte[] buffer = new byte[5 * 1024 * 1024];
                int read1 = stream.Read(buffer, 0, buffer.Length);
                Check(read1 == buffer.Length, "read 5 MB");
                Check(model.DownloadPercent == 50, "percent is 50%");
                Check(model.StatusText.Contains("50%"), "status contains 50%: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 50% (5 из 10 МБ)", "status text matches 50%: " + model.StatusText);

                // Manual read / feed of remaining 5 MB (100%)
                int read2 = stream.Read(buffer, 0, buffer.Length);
                Check(read2 == buffer.Length, "read remaining 5 MB");
                Check(model.DownloadPercent == 100, "percent is 100%");
                Check(model.StatusText.Contains("100%"), "status contains 100%: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 100% (10 из 10 МБ)", "status text matches 100%: " + model.StatusText);
            }

            // Sequence transitions to Verifying:
            model.OnVerifying();
            Check(model.State == UpdateButtonState.Verifying, "state is verifying");
            Check(model.StatusText.Contains("Проверяю сборку"), "status contains Проверяю сборку: " + model.StatusText);
            Check(model.StatusText == "Проверяю сборку…", "verifying text matches");
            Check(!model.ButtonEnabled, "button disabled while verifying");
            Check(model.IsBusy, "busy while verifying");

            // Sequence transitions to Installing:
            model.OnInstalling();
            Check(model.State == UpdateButtonState.Installing, "state is installing");
            Check(model.StatusText.Contains("Устанавливаю"), "status contains Устанавливаю: " + model.StatusText);
            Check(model.StatusText == "Устанавливаю, программа перезапустится", "installing text matches");
            Check(!model.ButtonEnabled, "button disabled while installing");
            Check(model.IsBusy, "busy while installing");
        }

        static void SecondClickIgnoredWhileBusy()
        {
            var model = new UpdateButtonModel();
            Check(model.OnClick(), "first click accepted");
            Check(model.State == UpdateButtonState.Checking, "state is checking");
            Check(model.StatusText == "Проверяю…", "checking text");
            Check(!model.ButtonEnabled, "button disabled during checking");
            Check(model.IsBusy, "busy during checking");

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
        }

        static void SizeZeroModeWithoutPercent()
        {
            var model = new UpdateButtonModel();
            using (var fakeSource = new MemoryStream(new byte[15 * 1024 * 1024]))
            using (var stream = model.CreateCountingStream(fakeSource, 0)) // size = 0
            {
                Check(model.State == UpdateButtonState.Downloading, "downloading state with size 0");
                Check(model.DownloadPercent == 0, "percent is 0");
                Check(!model.StatusText.Contains("%"), "status text has no percent at 0: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 0 МБ", "matches zero text: " + model.StatusText);

                byte[] buf = new byte[5 * 1024 * 1024];
                int r1 = stream.Read(buf, 0, buf.Length);
                Check(r1 == buf.Length, "read 5 MB chunk");
                Check(model.BytesDownloaded == 5 * 1024 * 1024, "downloaded 5 MB");
                Check(!model.StatusText.Contains("%"), "status text has no percent at 5 MB: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 5 МБ", "matches 5 MB text: " + model.StatusText);

                int r2 = stream.Read(buf, 0, buf.Length);
                Check(r2 == buf.Length, "read second 5 MB chunk");
                Check(model.BytesDownloaded == 10 * 1024 * 1024, "downloaded 10 MB");
                Check(!model.StatusText.Contains("%"), "status text has no percent at 10 MB: " + model.StatusText);
                Check(model.StatusText == "Скачиваю: 10 МБ", "matches 10 MB text: " + model.StatusText);
            }
        }

        static void UpToDateStateEnablesButton()
        {
            var model = new UpdateButtonModel();
            model.OnClick();
            Check(!model.ButtonEnabled, "busy checking");

            var time = new DateTime(2026, 11, 21, 14, 30, 0);
            model.OnUpToDate("1.5.0", time);
            Check(model.State == UpdateButtonState.UpToDate, "state is uptodate");
            Check(model.ButtonEnabled, "button is enabled when up to date");
            Check(!model.IsBusy, "not busy when up to date");
            Check(model.StatusText == "У вас последняя версия 1.5.0 (проверено 14:30)", "uptodate status text: " + model.StatusText);

            // Can click again when up to date
            Check(model.OnClick(), "click accepted when up to date");
            Check(model.State == UpdateButtonState.Checking, "re-enters checking");
        }

        static void OccupiedAndDeferredState()
        {
            var model = new UpdateButtonModel();
            bool subscribed = false;
            model.OnDeferred("применение конфига", () => subscribed = true);

            Check(model.State == UpdateButtonState.Deferred, "state is deferred");
            Check(model.StatusText == "Отложено: применение конфига — начну, как освободится", "deferred text matches: " + model.StatusText);
            Check(!model.ButtonEnabled, "button disabled when deferred");
            Check(model.IsBusy, "busy when deferred");
            Check(subscribed, "subscribed to release event");
            Check(model.IsReleaseSubscribed, "model reports release subscribed");

            // Second click during deferred is ignored
            Check(!model.OnClick(), "click during deferred is ignored");

            // Release triggers transition to Checking
            Check(model.OnReleased(), "release transitions state");
            Check(!model.IsReleaseSubscribed, "subscription cleared after release");
            Check(model.State == UpdateButtonState.Checking, "now checking");
            Check(model.StatusText == "Проверяю…", "status is checking: " + model.StatusText);

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
            model.OnFailed("нет связи с сервером");

            Check(model.State == UpdateButtonState.Failed, "state is failed");
            Check(model.ButtonEnabled, "button enabled after failure");
            Check(!model.IsBusy, "not busy after failure");
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
            model.OnUpdated("1.6.0");
            Check(model.State == UpdateButtonState.Updated, "state is updated");
            Check(model.ButtonEnabled, "button enabled when updated");
            Check(model.StatusText == "Обновлено до 1.6.0", "updated status text");
        }
    }
}
