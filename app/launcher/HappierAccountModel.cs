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
                WebUrl = url, HasKey = key, Visible = key || Json.Str(h, "mode") == "same" || saved.Count > 0 };
        }
    }

    internal sealed class HappierAccountCreation
    {
        string label;
        internal void Remember(string createdLabel) { label = createdLabel; }
        // A pending server install is not a created account yet; notify once after Account/ResumeAccount succeeds.
        internal string Complete(SectionOutcome outcome)
        {
            if (!outcome.Ok || label == null) return "";
            string message = "Создан новый аккаунт Happier \"" + label + "\". Чтобы открыть его в браузере или на телефоне, нажмите «Копировать ключ» и войдите в Happier по секретному ключу";
            label = null;
            return message;
        }
    }
}
