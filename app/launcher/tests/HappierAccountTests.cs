using System;
using System.IO;

namespace RemoteAgents.Launcher
{
    internal static class HappierAccountTests
    {
        static int count;
        static void Check(bool value, string message)
        { if (!value) throw new Exception("HappierAccount: " + message); count++; }
        internal static void Run()
        {
            string home = Path.Combine(Path.GetTempPath(), "happier-view-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(home);
            try {
                var config = Json.Map(Json.Parse("{\"profile\":{\"device\":{\"name\":\"Ноутбук\"},\"happier\":{\"mode\":\"same\",\"label\":\"Семейный\",\"key\":{\"secret\":\"custom-happier\"},\"webappUrl\":\"https://web.example:8443\"}},\"happier\":{\"label\":\"Старый\",\"webappUrl\":\"https://old.example\"}}"));
                Func<HappierAccountModel> read = () => HappierAccountModel.From(config, name => SecretVault.Has(home, name));
                var account = read();
                Check(account.Visible && !account.HasKey, "same without stored key has an open-only block");
                SecretVault.Set(home, "custom-happier", "TEST-RECOVERY-KEY");
                account = read();
                Check(account.HasKey && account.Visible && account.SecretName == "custom-happier", "custom vault reference exposes key actions");
                Check(account.Label == "Семейный" && account.WebUrl == "https://web.example:8443", "profile label and URL take priority");
                Check(SecretVault.Get(home, account.SecretName) == "TEST-RECOVERY-KEY", "UI reference reads the actual vault key");
                Check(!account.Label.Contains("TEST-RECOVERY-KEY") && !account.WebUrl.Contains("TEST-RECOVERY-KEY"), "metadata contains no key");
                var h = Json.Map(Json.Get(Json.Map(Json.Get(config, "profile")), "happier"));
                h.Remove("key");
                SecretVault.Set(home, "happier-key", "TEST-STALE-DEFAULT");
                account = read();
                Check(account.Visible && !account.HasKey && account.SecretName == "", "same without key reference never offers another account's default key");
                h["mode"] = "new";
                Check(!read().HasKey, "new account in progress never exposes the previous default key");
                h["mode"] = "same";
                h["key"] = ConfigBundle.D("secret", "happier-key");
                Check(read().HasKey && read().SecretName == "happier-key", "promoted new account uses the default reference");
                h["key"] = ConfigBundle.D("secret", "missing-custom");
                Check(!read().HasKey && read().SecretName == "missing-custom", "missing custom reference does not fall back to another key");
                h.Remove("key"); h.Remove("label");
                Check(read().Label == "Старый", "saved label fallback");
                Json.Map(config["happier"]).Remove("label");
                Check(read().Label == "Ноутбук", "device label fallback matches account request");
                foreach (string url in new[] { "http://web.example", "file:///tmp/test", "javascript:alert(1)", "https://user:password@web.example", "https://web.example/?key=TEST", "not a URL" }) {
                    h["webappUrl"] = url;
                    Check(read().WebUrl == "", "unsafe URL disables opening");
                }
                h.Remove("webappUrl");
                Check(read().WebUrl == "https://old.example", "saved webappUrl fallback");
                config.Remove("profile"); config.Remove("happier");
                Check(read().HasKey && read().Visible && read().Label == "Мой аккаунт", "default vault key survives reopening without profile metadata");
                SecretVault.Set(home, "happier-key", "");
                Check(!read().Visible && !read().HasKey, "no Happier metadata or key hides block");
                var creation = new HappierAccountCreation();
                var ok = new SectionOutcome { Ok = true };
                Check(creation.Complete(ok) == "", "same account has no creation notice");
                creation.Remember("Семейный");
                Check(creation.Complete(new SectionOutcome { Pending = true, Operation = "happier" }) == "", "pending install is not announced as success");
                Check(creation.Complete(new SectionOutcome()) == "", "failed attempt is not announced as success");
                Check(creation.Complete(ok) == "Создан новый аккаунт Happier \"Семейный\". Чтобы открыть его в браузере или на телефоне, нажмите «Копировать ключ» и войдите в Happier по секретному ключу", "success or delayed resume produces exact owner instructions");
                Check(creation.Complete(ok) == "", "success notification only once");
                creation.Remember("Другой");
                Check(creation.Complete(ok).Contains("\"Другой\""), "next new account gets its own notice");
            } finally { Directory.Delete(home, true); }
            Console.WriteLine("PASS: " + count + " Happier account/vault/notification checks");
        }
    }
}
