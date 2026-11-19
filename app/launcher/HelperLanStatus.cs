using System.Collections.Generic;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class HelperLanStatus
    {
        internal static Dictionary<string, object> Unavailable(Dictionary<string, object> config, bool installed, bool connected)
        {
            var networks = LanAccess.Read(Json.Map(Json.Get(config, "profile"))).Networks
                .Where(n => Json.Bool(n, "enabled") && Json.Strings(Json.Get(n, "subnets")).Length > 0)
                .Select(n => {
                    var row = new Dictionary<string, object>(n);
                    row["state"] = installed ? "channel-down" : "no-helper";
                    row["reason"] = installed ? (connected ? "ожидается проверка локальных сетей" : "нет связи с помощником")
                        : "помощник не установлен — установите помощник";
                    return (object)row;
                }).ToArray();
            return new Dictionary<string, object> { { "enabled", networks.Length > 0 }, { "networks", networks } };
        }
    }
}
