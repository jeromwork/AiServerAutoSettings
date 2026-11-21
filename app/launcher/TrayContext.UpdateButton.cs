using System;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Привязка модели кнопки «Обновить» (UpdateButtonModel) к трею: события модели -> строка в окне/меню и update.phase в журнале.
    internal sealed partial class TrayContext
    {
        readonly UpdateButtonModel updateButton = new UpdateButtonModel();
        bool buttonWaitsRelease;

        sealed class ReleaseWait : IDisposable
        {
            readonly TrayContext owner;
            public ReleaseWait(TrayContext owner) { this.owner = owner; owner.buttonWaitsRelease = true; }
            public void Dispose() { owner.buttonWaitsRelease = false; }
        }

        void InitUpdateButton()
        {
            updateButton.PhaseChanged += (from, to, ms, bytes) => {
                try { log.Write("update.phase phase=" + to.ToString().ToLowerInvariant() + " from=" + from.ToString().ToLowerInvariant() + " ms=" + ms + " bytes=" + bytes); } catch { }
                // Освободилось занятое: запуск проверки по событию, а не молча (Deferred -> Checking).
                if (from == UpdateButtonState.Deferred && to == UpdateButtonState.Checking) RunOnUi(ButtonProceed);
            };
            updateButton.StateChanged += m => RunOnUi(() => {
                if (m.StatusText.Length > 0) updateSummary = m.StatusText;
                if (!closing) RefreshMenu();
            });
        }

        // Прогресс приходит из фоновых потоков; UI трогаем только через dispatch.
        void RunOnUi(Action action)
        {
            try {
                if (dispatch.InvokeRequired) dispatch.BeginInvoke(action); else action();
            } catch (InvalidOperationException) { }
        }

        string UpdateOccupiedReason()
        {
            string mutation = MutationConflict();
            if (mutation.Length > 0) return mutation;
            if (BackgroundWork.Disk.Busy || (diskExplorer != null && diskExplorer.Busy)) return "синхронизация диска";
            if (Application.OpenForms.Cast<Form>().Any(f => f is ConfigWindow && ((ConfigWindow)f).IsApplying || f is SetupWizard && ((SetupWizard)f).IsApplying)) return "применение настроек";
            return "";
        }

        // Событие освобождения: tick трея (PollUpdates) видит, что занятость кончилась; пока кнопка ждёт — модель в Deferred.
        void PollButtonRelease()
        {
            if (buttonWaitsRelease && !closing && UpdateOccupiedReason().Length == 0) updateButton.OnReleased();
        }

        // Нажатие кнопки/пункта меню. Только UI-поток: вход «занято» и подписка идут в одном потоке.
        void CheckUpdates()
        {
            if (dispatch.InvokeRequired) { dispatch.BeginInvoke(new Action(CheckUpdates)); return; }
            if (closing) return;
            string occupied = UpdateOccupiedReason();
            if (!updateButton.OnClick(occupied.Length > 0 ? occupied : null, () => new ReleaseWait(this), () => UpdateOccupiedReason().Length > 0)) return;
            if (occupied.Length > 0) return; // ждём освобождения: подписка уже есть
            ButtonProceed();
        }

        // Кнопка свободна от занятости: либо ставим уже найденную версию, либо проверяем.
        void ButtonProceed()
        {
            if (closing) return;
            if (offeredUpdate != null) InstallOfferedUpdate(); else StartUpdateCheck(true);
        }

        void ApplyUpdateButton()
        {
            if (mainWindow == null || mainWindow.IsDisposed) return;
            mainWindow.SetUpdateButton(updateButton.ButtonEnabled && !engine.Pending, updateButton.ShowSpinner, updateButton.StatusText);
        }

        // Если модель занята (кнопку нажали или идёт установка) — переводит её в итоговое состояние; фоновые проверки кнопку не трогают.
        void ButtonDo(Action<UpdateButtonModel> action)
        {
            if (updateButton.IsBusy) action(updateButton);
        }

        // Страховка: операция закончилась, а кнопка осталась в промежуточном состоянии — показать ошибку, кнопку освободить.
        void ButtonSettle(string text)
        {
            var s = updateButton.State;
            if (s == UpdateButtonState.Checking || s == UpdateButtonState.Downloading || s == UpdateButtonState.Verifying) updateButton.OnFailed(text);
        }

        // Счётчик байт скачивания: растёт файл ssh cat -> +1% -> строка кнопки (CountingStream, без таймеров).
        Action<long> ButtonBytes(long size)
        {
            var counter = new CountingStream(Stream.Null, size, (b, t) => updateButton.OnDownloadProgress(b, t));
            return total => { long delta = total - counter.BytesTransferred; if (delta > 0) counter.AddBytes(delta); };
        }
    }
}
