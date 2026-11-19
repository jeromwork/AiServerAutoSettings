using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class NetHelperSetupTests
    {
        static int count;
        static void Check(bool ok, string name) { if (!ok) throw new Exception("NetHelperSetup: " + name); count++; }
        static Dictionary<string, object> Config(string profile, string legacy = "{}")
        { return Json.Map(Json.Parse("{\"profile\":" + profile + ",\"vpn\":" + legacy + "}")); }
        static async Task Scenarios()
        {
            Check(NetHelperInstall.HelperVersion == "6" && NetHelperInstall.NeedsInstall("5"), "v5 must receive changed service code");
            Check(NetHelperSetup.Required(Config("{\"lan\":[{\"name\":\"clinic\"}]}")), "LAN requires helper even with VPN off");
            Check(NetHelperSetup.Required(Config("{\"vpn\":{\"enabled\":true}}")), "enabled VPN requires helper");
            Check(NetHelperSetup.Required(Config("{}", "{\"enabled\":true}")), "manual/legacy VPN requires helper");
            Check(!NetHelperSetup.Required(Config("{\"vpn\":{\"enabled\":false}}", "{\"enabled\":true}")), "explicit profile VPN off takes precedence");
            Check(!NetHelperInstall.NeedsInstall("999"), "a newer helper version alone does not request a downgrade");
            var messages = new List<string>();
            Action<string> progress = messages.Add;
            foreach (string version in new[] { "", "5" }) {
                var setup = new NetHelperSetup(); string installed = version;
                int prompts = 0, preparations = 0;
                Func<Task<bool>> ensure = () => setup.Ensure(true, () => !NetHelperInstall.NeedsInstall(installed),
                    () => { preparations++; return Task.CompletedTask; },
                    () => { prompts++; installed = NetHelperInstall.HelperVersion; return Task.FromResult(0); }, progress, CancellationToken.None);
                Check(await ensure() && await ensure(), "clean install / OTA becomes ready for all subsequent callers");
                Check(prompts == 1 && preparations == 1, version == "" ? "clean install exactly one UAC" : "OTA v5 exactly one UAC");
            }
            {
                var setup = new NetHelperSetup(); int prompts = 0;
                Check(await setup.Ensure(true, () => true, () => { throw new Exception("must not prepare"); },
                    () => { prompts++; return Task.FromResult(0); }, progress, CancellationToken.None) && prompts == 0, "current helper no UAC/preparation");
                bool needed = NetHelperSetup.Required(Config("{\"lan\":[],\"vpn\":{\"enabled\":false}}"));
                Check(!needed && await setup.Ensure(needed, () => { throw new Exception("must not inspect SCM"); },
                    () => Task.CompletedTask, () => { prompts++; return Task.FromResult(0); }, progress, CancellationToken.None) && prompts == 0,
                    "no LAN and VPN off: no SCM, no preparation, no UAC");
            }
            {
                var setup = new NetHelperSetup(); int reads = 0, prompts = 0; bool current = true;
                Func<Task<bool>> ensure = () => setup.Ensure(true, () => { reads++; return current; },
                    () => Task.CompletedTask, () => { prompts++; current = true; return Task.FromResult(0); }, progress, CancellationToken.None);
                Check(await ensure() && await ensure() && await ensure() && reads == 1, "wizard steps share one session readiness/hash check");
                current = false;
                Check(await setup.Ensure(true, () => { reads++; return current; }, () => Task.CompletedTask,
                    () => { prompts++; current = true; return Task.FromResult(0); }, progress, CancellationToken.None, retry: true) &&
                    prompts == 1 && reads == 3, "button invalidates ready cache and installation verifies fresh files");
                Check(await ensure() && reads == 3, "post-install readiness is cached for the session");
            }
            {
                var setup = new NetHelperSetup(); var entered = new TaskCompletionSource<bool>();
                using (var release = new ManualResetEventSlim()) {
                    var pending = setup.Ensure(true, () => {
                        entered.SetResult(true);
                        if (!release.Wait(2000)) throw new Exception("readiness blocked its caller");
                        return true;
                    }, () => Task.CompletedTask, () => { throw new Exception("no UAC"); }, progress, CancellationToken.None);
                    await entered.Task;
                    Check(!pending.IsCompleted, "slow hash check yields to the window caller");
                    release.Set(); Check(await pending, "background readiness completes normally");
                }
            }
            {
                await NetHelperSetup.WaitForIdle(() => false, CancellationToken.None);
                var entered = new TaskCompletionSource<bool>(); bool busy = true; int polls = 0;
                var pending = NetHelperSetup.WaitForIdle(() => { polls++; entered.TrySetResult(true); return busy; }, CancellationToken.None);
                Check(!pending.IsCompleted, "busy operation yields while connection is pending");
                await entered.Task; busy = false; await pending;
                Check(polls >= 2, "completed busy operation allows connection after recheck");
                bool timedOut = false;
                try { await NetHelperSetup.WaitForIdle(() => true, CancellationToken.None, timeoutMs: 1); }
                catch (TimeoutException error) { timedOut = error.Message == NetHelperSetup.BusyTimeout; }
                Check(timedOut, "stuck busy has a bounded wait and actionable error");
                using (var cancelled = new CancellationTokenSource()) {
                    pending = NetHelperSetup.WaitForIdle(() => true, cancelled.Token); cancelled.Cancel();
                    bool propagated = false;
                    try { await pending; } catch (OperationCanceledException) { propagated = true; }
                    Check(propagated, "busy wait still honours cancellation");
                }
            }
            {
                var setup = new NetHelperSetup(); int prompts = 0, failures = 0; bool installed = false;
                Func<Task<bool>> ensure = () => NetHelperSetup.ContinueApply(() => setup.Ensure(true, () => installed,
                    () => Task.CompletedTask, () => { prompts++; throw new Win32Exception(1223); }, progress, CancellationToken.None),
                    error => { Check(error is Win32Exception && ((Win32Exception)error).NativeErrorCode == 1223, "native UAC cancellation branch reachable"); failures++; });
                Check(!await ensure(), "cancel UAC returns unavailable without throwing at apply boundary");
                var sections = new[] { ConfigSections.Server, ConfigSections.Connection, ConfigSections.Disk, ConfigSections.Lan };
                var result = await ConfigEngine.Execute(sections, (s, t) => Task.FromResult(new SectionOutcome { Ok = true }), (s, state, text) => { }, CancellationToken.None);
                Check(result.Count == sections.Length && result.Values.All(r => r.Ok), "config engine continues all unrelated sections after refusal");
                Check(!await ensure() && !await ensure() && prompts == 1 && failures == 1, "Execute/Activate/wizard repeated calls do not repeat UAC in session");
                Check(setup.Warning == NetHelperSetup.PermissionRequired, "persistent administrator permission status");
                Check(await setup.Ensure(true, () => installed, () => Task.CompletedTask,
                    () => { prompts++; installed = true; return Task.FromResult(0); }, progress, CancellationToken.None, retry: true) && prompts == 2 && setup.Warning == "",
                    "explicit install button permits one new attempt and clears warning");
            }
            {
                var setup = new NetHelperSetup(); bool installed = false; int prompts = 0;
                var release = new TaskCompletionSource<int>();
                Func<Task<bool>> ensure = () => setup.Ensure(true, () => installed, () => Task.CompletedTask,
                    async () => { prompts++; int code = await release.Task; installed = true; return code; }, progress, CancellationToken.None);
                var first = ensure(); var second = ensure(); release.SetResult(0);
                Check((await Task.WhenAll(first, second)).All(r => r) && prompts == 1, "concurrent tray/config setup shares exactly one elevation");
            }
            foreach (int code in new[] { 1, 1223, 0 }) {
                var setup = new NetHelperSetup(); int prompts = 0;
                bool ok = await NetHelperSetup.ContinueApply(() => setup.Ensure(true, () => false, () => Task.CompletedTask,
                    () => { prompts++; return Task.FromResult(code); }, progress, CancellationToken.None), error => { });
                Check(!ok && setup.Warning.Length > 0 && prompts == 1, "failed installer / cancelled exit / missing service cannot report success");
                Check(!await setup.Ensure(true, () => false, () => Task.CompletedTask, () => { throw new Exception("no repeated UAC"); }, progress, CancellationToken.None), "failure is retained until explicit retry");
            }
            {
                var setup = new NetHelperSetup();
                using (var cancelled = new CancellationTokenSource()) {
                    cancelled.Cancel(); bool propagated = false;
                    try { await NetHelperSetup.ContinueApply(() => setup.Ensure(true, () => false, () => Task.CompletedTask,
                        () => { throw new Exception("no UAC after cancellation"); }, progress, cancelled.Token), error => { }); }
                    catch (OperationCanceledException) { propagated = true; }
                    Check(propagated, "actual cancellation still stops config apply");
                }
            }
            {
                var setup = new NetHelperSetup(); var release = new TaskCompletionSource<int>();
                var entered = new TaskCompletionSource<bool>(); bool installed = false;
                using (var cancelled = new CancellationTokenSource()) {
                    var pending = setup.Ensure(true, () => installed, () => Task.CompletedTask,
                        async () => { entered.SetResult(true); int code = await release.Task; installed = true; return code; }, progress, cancelled.Token);
                    await entered.Task;
                    cancelled.Cancel();
                    Check(!pending.IsCompleted, "cancellation waits for elevated installer to finish");
                    release.SetResult(0); bool propagated = false;
                    try { await pending; } catch (OperationCanceledException) { propagated = true; }
                    Check(propagated && installed, "installer completes before cancellation propagates");
                }
            }
            string root = Path.Combine(Path.GetTempPath(), "ra-helper-setup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try {
                string exe = Path.Combine(root, "current.exe"), installedExe = Path.Combine(root, "RemoteAgents.exe"), transport = Path.Combine(root, "sing-box.exe");
                File.WriteAllText(exe, "expected EXE"); File.Copy(exe, installedExe); File.WriteAllText(transport, "expected transport");
                string hash = Files.Hash(transport);
                Check(NetHelperInstall.ImagesMatch(root, hash), "installed EXE exists and transport matches pin");
                File.WriteAllText(exe, "new launcher after OTA");
                Check(Files.Hash(exe) != Files.Hash(installedExe) && NetHelperInstall.ImagesMatch(root, hash), "new launcher hash with compatible helper is current");
                foreach (string scenario in new[] { "OTA same helper", "OTA older helper", "wrong sing-box" }) {
                    var coordinator = new NetHelperSetup(); int prompts = 0;
                    string version = scenario == "OTA older helper" ? "5" : NetHelperInstall.HelperVersion;
                    if (scenario == "wrong sing-box") File.WriteAllText(transport, "wrong sing-box");
                    Func<Task<bool>> ensure = () => coordinator.Ensure(true,
                        () => !NetHelperInstall.NeedsInstall(version) && NetHelperInstall.ImagesMatch(root, hash),
                        () => Task.CompletedTask, () => {
                            prompts++; version = NetHelperInstall.HelperVersion; File.WriteAllText(transport, "expected transport");
                            return Task.FromResult(0);
                        }, progress, CancellationToken.None);
                    Check(await ensure() && await ensure() && prompts == (scenario == "OTA same helper" ? 0 : 1), scenario + ": expected UAC count");
                }
                File.Delete(installedExe);
                Check(!NetHelperInstall.ImagesMatch(root, hash), "missing service EXE is not current");
                File.Copy(exe, installedExe); File.WriteAllText(transport, "wrong sing-box");
                Check(!NetHelperInstall.ImagesMatch(root, hash), "changed sing-box detected even with current version marker");
                var setup = new NetHelperSetup(); int copies = 0;
                bool ok = await NetHelperSetup.ContinueApply(() => setup.Ensure(true, () => false,
                    () => { PinnedTransport.ReadVerified(root, root, hash); return Task.CompletedTask; },
                    () => { copies++; return Task.FromResult(0); }, progress, CancellationToken.None), error => { });
                // ReadVerified searches transport-bin or bundle/transport, not service's destination.
                Check(!ok && copies == 0 && setup.Warning.Contains("полную"), "thin EXE with no source has actionable window status, no elevation/copy");
                Directory.CreateDirectory(Path.Combine(root, "transport-bin"));
                File.WriteAllText(Path.Combine(root, "transport-bin", "sing-box.exe"), "untrusted bytes");
                setup = new NetHelperSetup();
                ok = await NetHelperSetup.ContinueApply(() => setup.Ensure(true, () => false,
                    () => { PinnedTransport.ReadVerified(root, root, hash); return Task.CompletedTask; },
                    () => { copies++; File.WriteAllText(transport, "copied"); return Task.FromResult(0); }, progress, CancellationToken.None), error => { });
                Check(!ok && copies == 0 && setup.Warning.Contains("SHA-256") && File.ReadAllText(transport) == "wrong sing-box", "hash mismatch: no UAC, no privileged copy, actionable status");
            } finally { Directory.Delete(root, true); }
            Console.WriteLine("PASS: NetHelperSetup " + count + " checks (no service/UAC)");
        }
        internal static void Run() { Scenarios().GetAwaiter().GetResult(); }

        static byte[] Resource(string exe, string name)
        {
            using (var file = File.OpenRead(exe)) using (var pe = new PEReader(file)) {
                var metadata = pe.GetMetadataReader();
                foreach (var handle in metadata.ManifestResources) {
                    var row = metadata.GetManifestResource(handle);
                    if (metadata.GetString(row.Name) != name || !row.Implementation.IsNil) continue;
                    var section = pe.GetSectionData(pe.PEHeaders.CorHeader.ResourcesDirectory.RelativeVirtualAddress);
                    var blob = section.GetReader((int)row.Offset, section.Length - (int)row.Offset);
                    int size = blob.ReadInt32(); return blob.ReadBytes(size);
                }
            }
            throw new Exception("Missing EXE resource " + name);
        }
        internal static void FullExe(string exe, string ota)
        {
            using (var data = new MemoryStream(Resource(exe, "RemoteAgents.InitialBundle.zip")))
            using (var zip = new ZipArchive(data, ZipArchiveMode.Read)) {
                var entry = zip.GetEntry(PinnedTransport.Target);
                Check(entry != null, "actual full net48 EXE embeds sing-box in InitialBundle.zip");
                using (var source = entry.Open()) using (var image = new MemoryStream()) {
                    source.CopyTo(image);
                    Check(PinnedTransport.Hash(image.ToArray()) == PinnedTransport.ExpectedHash, "actual embedded sing-box matches trusted memberSha256");
                }
            }
            using (var zip = ZipFile.OpenRead(ota)) {
                Check(zip.GetEntry(PinnedTransport.Target) == null, "outer OTA zip omits separate sing-box");
                using (var source = zip.GetEntry("RemoteAgents.exe").Open()) using (var image = new MemoryStream()) {
                    source.CopyTo(image);
                    Check(PinnedTransport.Hash(image.ToArray()) == Files.Hash(exe), "OTA carries the same full EXE retaining its embedded recovery source");
                }
            }
            Console.WriteLine("PASS: actual full EXE and OTA resources verified");
        }
    }
}
