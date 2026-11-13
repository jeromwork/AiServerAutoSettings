using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal sealed class DiskShellCommands
    {
        readonly string home; readonly Func<Task<string>> bundle;
        readonly Action showProgress; readonly Action<string> notify, log, placeholder;
        internal DiskShellCommands(string home, Func<Task<string>> bundle, Action showProgress, Action<string> notify, Action<string> log, Action<string> placeholder)
        { this.home = home; this.bundle = bundle; this.showProgress = showProgress; this.notify = notify; this.log = log; this.placeholder = placeholder; }
        internal async Task Execute(IList<DiskShellRequest> requests, CancellationToken token)
        {
            if (requests.Count == 0) return;
            if (requests.All(r => r.Action == "progress")) { showProgress(); return; }
            if (BackgroundWork.Disk.Busy) throw new IOException("Сейчас применяется выбор папок. Повторите команду после завершения.");
            if (!Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(new Configuration(home).Data, "components")), "disk")), "enabled")) throw new IOException("Сначала включите Диск в программе");
            var profile = ConfigProfile.Load(home); var disk = Json.Map(Json.Get(profile, "disk"));
            string diskBase = Json.Text(disk, "base", ConfigSession.DiskBase());
            string diskHome = Json.Text(Json.Map(Json.Get(new Configuration(home).Data, "disk")), "home", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk"));
            string originalBinding = DiskApplyWait.Binding(profile);
            var model = new DiskFoldersModel(DiskChoice.FromProfile(profile), null, ConfigProfile.DiskExclusions(diskHome));
            if (model.Mode == DiskFoldersMode.All) {
                string currentBundle = await bundle();
                var tree = await Task.Run(() => WizardRunner.Run(home, currentBundle, "DiskTree", new { @base = diskBase, path = "" }, token));
                model.Level("", Json.Map(Json.Get(tree, "union")));
            }
            var evictions = new Dictionary<string, DiskEvictionCandidate>(StringComparer.OrdinalIgnoreCase);
            var refusals = new List<string>(); bool changed = false, transfers = false;
            foreach (var request in requests) {
                token.ThrowIfCancellationRequested();
                if (request.Action == "progress") { showProgress(); continue; }
                string path = Path.GetFullPath(request.Path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                if (!Directory.Exists(path)) throw new IOException("Папка больше не существует: " + path);
                var state = LocalFolders.State(model, path, diskBase, SystemFolders());
                if (request.Action == "add") {
                    if (state.Kind != LocalFolderKind.Free) throw new IOException(state.Reason.Length > 0 ? state.Reason : "«Добавить в Диск» работает для папок вне Диска");
                    string name = Path.GetFileName(path);
                    if (Directory.Exists(Path.Combine(diskBase, name)) || File.Exists(Path.Combine(diskBase, name))) throw new IOException("В Диске уже занято имя «" + name + "»");
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Соединение каталога нельзя добавить как исходную папку");
                    LocalFolders.Choose(model, path, name, DiskChoice.Both, diskBase, SystemFolders()); changed = transfers = true;
                    continue;
                }
                string project;
                if (state.Kind == LocalFolderKind.External) project = state.Entry.Remote;
                else if (state.Kind == LocalFolderKind.InDisk && state.DiskPath.IndexOf('/') < 0) project = state.DiskPath;
                else throw new IOException("Выберите папку проекта верхнего уровня внутри Диска");
                if (request.Action == "download" || request.Action == "sync") {
                    model.TakeToComputer(project); changed = transfers = true;
                } else if (request.Action == "keep-server") {
                    if (!model.Includes(project) && !model.Partial(project)) throw new IOException("Эта папка не выбрана для синхронизации");
                    if (state.Kind == LocalFolderKind.External || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) {
                        refusals.Add(project + ": внешняя папка сохранена в исходном месте; снять её выбор можно во вкладке «Папки»."); continue;
                    }
                    var proof = await Task.Run(() => DiskEvictionCandidate.Prepare(diskHome, project, path, token));
                    if (proof.Reason.Length > 0) refusals.Add(project + ": " + proof.Reason + ". Файлы оставлены на компьютере.");
                    else evictions[path] = proof;
                    model.StopSynchronizing(project); changed = true;
                }
            }
            if (!changed) { if (refusals.Count > 0) notify(string.Join("\n", refusals)); return; }
            var choice = model.ToChoice();
            if (originalBinding != DiskApplyWait.Binding(ConfigProfile.Load(home))) throw new IOException("Настройки папок изменились. Повторите команду.");
            string binding = DiskApplyWait.Binding(choice.WriteTo(profile, diskBase));
            var finished = new TaskCompletionSource<DiskRun>();
            bool started = BackgroundWork.Disk.TryStart(async ct => {
                var run = new DiskRun { Binding = binding, Choice = choice };
                try {
                    ConfigProfile.Update(home, p => {
                        if (originalBinding != DiskApplyWait.Binding(p)) throw new IOException("Настройки папок изменились. Повторите команду.");
                        p["disk"] = choice.WriteTo(p, diskBase)["disk"];
                    });
                    var session = new ConfigSession(home, bundle) { Log = message => log("disk-shell-apply-progress") };
                    session.DiskCurrent = () => binding == DiskApplyWait.Binding(ConfigProfile.Load(home));
                    var outcome = await session.ApplyDisk(ct); run.Ok = outcome.Ok; run.Summary = outcome.Summary;
                    if (outcome.Ok && session.DiskCurrent()) foreach (var pair in evictions) {
                        token.ThrowIfCancellationRequested();
                        if (!session.DiskCurrent()) throw new IOException("Выбор папок изменился; оставшиеся локальные файлы сохранены");
                        string reason = pair.Value.Revalidate();
                        if (reason.Length > 0) { refusals.Add(pair.Value.Project + ": " + reason + ". Файлы оставлены на компьютере."); continue; }
                        pair.Value.Recycle(); placeholder(pair.Key); log("disk-shell-recycled");
                    }
                    if (!outcome.Ok) refusals.Add("Выбор папок не применён: " + outcome.Summary + ". Локальные файлы оставлены.");
                } catch (Exception e) { run.Summary = e.Message; refusals.Add("Действие не завершено: " + e.Message); }
                finally { finished.TrySetResult(run); }
                return run;
            });
            if (!started) throw new IOException("Сейчас применяется выбор папок. Повторите команду после завершения.");
            if (transfers) showProgress();
            await finished.Task;
            if (refusals.Count > 0) notify(string.Join("\n", refusals));
        }
        static IEnumerable<string> SystemFolders()
        {
            return new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 }
                .Select(Environment.GetFolderPath).Where(p => p.Length > 0);
        }
    }
}
