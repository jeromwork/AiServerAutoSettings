using System;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal enum UpdateOffer { Failed, Current, Bad, NeedsInstaller, Available, ManualOnly }
    internal sealed class UpdateProbe
    {
        internal Manifest Manifest;
        internal UpdateOffer Offer;
        internal static UpdateProbe Read(Func<Manifest> readManifest, string current, string launcher, Func<string, bool> bad, bool automatic)
        {
            try {
                var m = readManifest();
                if (m.Data.ContainsKey("product") && Json.Str(m.Data, "product") != Product.Name) return new UpdateProbe { Offer = UpdateOffer.Failed };
                return new UpdateProbe { Manifest = m, Offer = Files.Compare(m.Version, current) <= 0 ? UpdateOffer.Current : bad(m.Version) ? UpdateOffer.Bad :
                    Files.Compare(m.Minimum, launcher) > 0 || !m.Data.ContainsKey("configSchema") || m.LauncherVersion.Length == 0 ? UpdateOffer.NeedsInstaller :
                    automatic ? UpdateOffer.Available : UpdateOffer.ManualOnly };
            } catch (OperationCanceledException) { throw; }
            catch { return new UpdateProbe { Offer = UpdateOffer.Failed }; }
        }
    }
}
