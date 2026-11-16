using System;
using System.Collections.Generic;
using System.IO;

namespace RemoteAgents.Launcher
{
    // Public metadata only. The UI reads the key from the vault only for an explicit user action.
    internal sealed class HappierAccountModel
    {
        internal string Label = "", SecretName = "", WebUrl = "";
        internal bool HasKey, Visible;
        internal static HappierAccountModel From(Dictionary<string, object> config, Func<string, bool> hasSecret)
        {
            var profile = Json.Map(Json.Get(config, "profile"));
            var h = Json.Map(Json.Get(profile, "happier"));
            var saved = Json.Map(Json.Get(config, "happier"));
            string name = ConfigRequests.SecretName(Json.Get(h, "key"));
            // A server-exported same account carries no recovery key. Never offer a stale default key for it.
            if (Json.Str(h, "mode") == "new") name = "";
            else if (name.Length == 0 && h.Count == 0) name = "happier-key";
            string label = Json.Text(h, "label", Json.Text(saved, "label", ConfigProfile.DeviceName(profile)));
            string url = "";
            try { url = ConfigRequests.Origin(Json.Text(h, "webappUrl", Json.Str(saved, "webappUrl"))); }
            catch (IOException) { }
            bool key = name.Length > 0 && hasSecret(name);
            return new HappierAccountModel { Label = label.Length > 0 ? label : "Мой аккаунт", SecretName = name,
                WebUrl = url, HasKey = key, Visible = key || Json.Str(h, "mode") == "same" || saved.Count > 0 || HappierWebResolver.LocalUrl(config).Length > 0 };
        }
    }

    internal sealed class HappierAccountCreation
    {
        readonly string file;
        static readonly object gate = new object();
        internal HappierAccountCreation(string home) { file = Path.Combine(home, "state", "happier-created.json"); }
        internal void Remember(string createdLabel)
        {
            lock (gate) Json.Write(file, new Dictionary<string, object> { { "schema", 1 }, { "label", createdLabel } });
        }
        // Public local state survives Pending and process restart. Only success consumes the notice.
        internal string Complete(SectionOutcome outcome)
        {
            if (!outcome.Ok) return "";
            lock (gate) {
                if (!File.Exists(file)) return "";
                var saved = Json.Read(file);
                if (Json.Int(saved, "schema", 0) != 1) return "";
                string label = Json.Str(saved, "label");
                string message = "Создан новый аккаунт Happier \"" + label + "\". Чтобы открыть его в браузере или на телефоне, нажмите «Копировать ключ» и войдите в Happier по секретному ключу";
                File.Delete(file);
                return message;
            }
        }
    }
}
