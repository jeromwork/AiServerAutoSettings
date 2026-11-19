using System;
using System.ComponentModel;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Shared by config apply, the manual wizard and the tray's explicit retry.
    // Always recheck SCM/version; no user-writable "installed" flag can skip installation.
    internal sealed class NetHelperSetup
    {
        readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        internal async Task Ensure(Func<bool> ready, Func<Task> prepare, Func<Task<int>> install,
            Action<string> progress, CancellationToken token)
        {
            await gate.WaitAsync(token);
            try {
                token.ThrowIfCancellationRequested();
                if (ready()) return;
                progress("Подготавливаю сетевой помощник для локальных сетей и VPN…");
                await prepare(); // Restore and verify the pinned binary before asking for UAC.
                token.ThrowIfCancellationRequested();
                progress("Windows запросит одно разрешение администратора: устанавливаю сетевой помощник. Подтвердите запрос UAC.");
                int code;
                try { code = await install(); }
                catch (Win32Exception error) when (error.NativeErrorCode == 1223) {
                    throw new IOException("Разрешение Windows отменено: сетевой помощник не установлен. Для локальных сетей и VPN повторите применение настроек и подтвердите UAC.", error);
                }
                // Do not abandon an elevated installer on cancellation: wait for its result first.
                if (code != 0) throw new IOException("Сетевой помощник не установлен (код " + code.ToString(System.Globalization.CultureInfo.InvariantCulture) + "). Повторите применение настроек; журнал: logs\\launcher.log.");
                if (!ready()) throw new IOException("Установка завершилась без подтверждённой службы RemoteAgentsNet. Повторите применение настроек.");
                progress("Сетевой помощник установлен. Локальные сети из конфига включатся при готовности канала до сервера.");
                token.ThrowIfCancellationRequested();
            } finally { gate.Release(); }
        }
    }
}
