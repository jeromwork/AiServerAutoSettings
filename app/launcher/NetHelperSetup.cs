using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // One coordinator per launcher session: config, wizard, OTA launch and explicit retry share it.
    internal sealed class NetHelperSetup
    {
        internal const string PermissionRequired = "Нужно разрешение администратора. Локальные сети и VPN недоступны; нажмите «Установить помощника».";
        readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        bool attempted;
        internal int InstallGeneration { get; private set; }
        internal string Warning { get; private set; } = "";

        internal static bool Required(Dictionary<string, object> config)
        {
            var profile = Json.Map(Json.Get(config, "profile"));
            var vpn = Json.Map(Json.Get(profile, "vpn"));
            // Manual wizard / legacy settings can precede profile.vpn.
            bool vpnEnabled = vpn.ContainsKey("enabled") ? Json.Bool(vpn, "enabled") : Json.Bool(Json.Map(Json.Get(config, "vpn")), "enabled");
            return Json.Array(Json.Get(profile, "lan")).Length > 0 || Product.VpnEnabled && vpnEnabled;
        }

        // Production boundary used by both the WinForms callers and portable config-flow tests.
        internal static async Task<bool> ContinueApply(Func<Task<bool>> ensure, Action<Exception> failure)
        {
            try { return await ensure(); }
            catch (OperationCanceledException) { throw; }
            catch (Win32Exception error) when (error.NativeErrorCode == 1223) { failure(error); return false; }
            catch (Exception error) { failure(error); return false; }
        }

        internal async Task<bool> Ensure(bool required, Func<bool> ready, Func<Task> prepare, Func<Task<int>> install,
            Action<string> progress, CancellationToken token, bool retry = false)
        {
            if (!required) return true;
            await gate.WaitAsync(token);
            try {
                token.ThrowIfCancellationRequested();
                if (ready()) { Warning = ""; return true; }
                if (attempted && !retry) { progress(Warning); return false; }
                attempted = true;
                Warning = "Сетевой помощник не установлен. Нажмите «Установить помощника»; журнал: logs\\launcher.log.";
                progress("Подготавливаю сетевой помощник для локальных сетей и VPN…");
                await prepare(); // Restore and verify the pinned binary before asking for UAC.
                token.ThrowIfCancellationRequested();
                progress("Сетевой помощник отсутствует или устарел. Windows запросит одно разрешение администратора для установки. Подтвердите UAC.");
                int code;
                try { code = await install(); }
                catch (Win32Exception error) when (error.NativeErrorCode == 1223) {
                    Warning = PermissionRequired;
                    throw; // Keep the native cancellation reachable in the UI's 1223 branch.
                }
                // Wait for the elevated installer even if the caller cancels while UAC is open.
                if (code == 1223) { Warning = PermissionRequired; throw new Win32Exception(1223); }
                if (code != 0) {
                    Warning = "Сетевой помощник не установлен (код " + code.ToString(System.Globalization.CultureInfo.InvariantCulture) + "). Нажмите «Установить помощника».";
                    throw new Win32Exception(code);
                }
                if (!ready()) {
                    Warning = "Установка не подтвердила версию и файлы службы RemoteAgentsNet. Нажмите «Установить помощника».";
                    throw new IOException(Warning);
                }
                Warning = ""; InstallGeneration++;
                progress("Сетевой помощник установлен. Локальные сети из конфига включатся при готовности канала до сервера.");
                token.ThrowIfCancellationRequested();
                return true;
            } catch (OperationCanceledException) {
                attempted = false; throw;
            } catch (InvalidDataException error) {
                Warning = error.Message; throw;
            } catch (FileNotFoundException error) {
                Warning = error.Message; throw;
            } catch (Exception) {
                if (Warning.Length == 0) Warning = "Не удалось проверить или установить сетевой помощник. Нажмите «Установить помощника»; журнал: logs\\launcher.log.";
                throw;
            } finally { gate.Release(); }
        }
    }
}
