#!/usr/bin/env bash
# Сборка lab/out/RemoteAgents-Lab.exe: сторож на C# + переносной Python + наш код + STOP.cmd (всё встроено в EXE).
# По образцу build/build-exe.sh основной программы (dotnet publish, закреплённая сумма для сторонних файлов).
# Запуск: timeout 420 flock --close /tmp/heavy-tests.lock bash lab/build.sh
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)   # lab/
out=${LAB_OUT:-$here/out}
cache=${RA_LAB_CACHE:-$HOME/.cache/ra-lab}
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
mkdir -p "$out/work" "$cache"
out=$(cd "$out" && pwd)
work=$out/work

# 1. Переносной Python: скачивается один раз, принимается только с закреплённой суммой (lab/python-embed.json).
read -r py_name py_url py_sha < <(python3 -I - "$here/python-embed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8-sig'))
print(d['name'], d['url'], d['sha256'])
PY
)
py_cache=$cache/$py_name
if [[ -f $py_cache ]] && [[ $(sha256sum "$py_cache" | cut -d' ' -f1) != "$py_sha" ]]; then
  echo "В кэше $py_cache не та сумма, скачиваю заново" >&2; rm -f "$py_cache"
fi
if [[ ! -f $py_cache ]]; then
  curl -fsSL --retry 2 -o "$py_cache.part" "$py_url"
  mv "$py_cache.part" "$py_cache"
fi
got=$(sha256sum "$py_cache" | cut -d' ' -f1)
if [[ $got != "$py_sha" ]]; then echo "ОШИБКА: sha256 $py_name = $got, ожидалось $py_sha" >&2; rm -f "$py_cache"; exit 1; fi
cp "$py_cache" "$work/python-embed.zip"

# 1б. Бинарники (lab/bundle.json): каждый скачивается один раз, принимается только с закреплёнными суммами; всё собирается в bin.zip.
python3 -I - "$here/bundle.json" "$cache" "$work/bin.zip" <<'PY'
import hashlib, json, os, sys, urllib.request, zipfile
spec, cache, target = sys.argv[1:4]
def sha(b): return hashlib.sha256(b).hexdigest()
def die(msg):
    print('ОШИБКА: ' + msg, file=sys.stderr); sys.exit(1)
items = json.load(open(spec, encoding='utf-8-sig'))['binaries']
files, manifest = {}, {}
for b in items:
    path = os.path.join(cache, 'bin-' + b['sha256'])
    if os.path.isfile(path) and sha(open(path, 'rb').read()) != b['sha256']:
        print('В кэше %s не та сумма, скачиваю заново' % path, file=sys.stderr); os.remove(path)
    if not os.path.isfile(path):
        with urllib.request.urlopen(b['url'], timeout=300) as r:
            data = r.read()
        with open(path + '.part', 'wb') as f: f.write(data)
        os.replace(path + '.part', path)
    raw = open(path, 'rb').read()
    if sha(raw) != b['sha256']:
        os.remove(path); die('sha256 %s = %s, ожидалось %s' % (b['name'], sha(raw), b['sha256']))
    if b.get('member'):
        with zipfile.ZipFile(path) as z: data = z.read(b['member'])
    else:
        data = raw
    if sha(data) != b['memberSha256']:
        die('sha256 файла %s в %s = %s, ожидалось %s' % (b.get('member') or b['name'], b['name'], sha(data), b['memberSha256']))
    files[b['target']] = data; manifest[b['target']] = b['memberSha256']
    if b.get('license'):   # текст лицензии из того же архива -> licenses/<имя>/ (в манифесте тоже)
        with zipfile.ZipFile(path) as z: lic = z.read(b['license'])
        lt = 'licenses/%s/%s' % (b['name'], b['license'].rsplit('/', 1)[-1])
        files[lt] = lic; manifest[lt] = sha(lic)
files['bin-manifest.json'] = (json.dumps(manifest, sort_keys=True, indent=1) + '\n').encode()
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel in sorted(files):
        info = zipfile.ZipInfo(rel, (1980, 1, 1, 0, 0, 0))   # фиксированная дата, как у lab-code.zip
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, files[rel])
print('bin.zip: %s %d' % (sha(open(target, 'rb').read()), os.path.getsize(target)))
PY

# 2. Версия кода (как у ra-lab push: короткий sha, -dirty при незакоммиченном).
sha=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo nocommit)
if [[ -n $(git -C "$here" status --porcelain -- . ':!out' 2>/dev/null || true) ]]; then sha=$sha-dirty; fi
printf '%s\n' "$sha" > "$work/code-version.txt"
stage=$(tr -d ' \r\n' < "$here/STAGE" 2>/dev/null || echo dev)
version="$stage-$(date -u +%Y%m%d.%H%M%S)-$sha"

# 3. lab-code.zip: run_lab.py, ralab/**/*.py, code-version.txt (тот же состав, что пакует ra-lab push; updater принимает только .py и code-version.txt).
python3 -I - "$here" "$work/lab-code.zip" "$work/code-version.txt" <<'PY'
import os, sys, zipfile
lab, target, version = sys.argv[1:4]
files = []
if os.path.isfile(os.path.join(lab, 'run_lab.py')):
    files.append('run_lab.py')
else:
    print('ПРЕДУПРЕЖДЕНИЕ: lab/run_lab.py ещё нет, пакую то, что есть', file=sys.stderr)
for root, dirs, names in os.walk(os.path.join(lab, 'ralab')):
    dirs[:] = sorted(d for d in dirs if d != '__pycache__')
    for name in sorted(names):
        if name.endswith('.py'):
            files.append(os.path.relpath(os.path.join(root, name), lab).replace(os.sep, '/'))
files = sorted(files)
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel in files + ['code-version.txt']:
        src = version if rel == 'code-version.txt' else os.path.join(lab, rel)
        info = zipfile.ZipInfo(rel, (1980, 1, 1, 0, 0, 0))   # фиксированная дата: одинаковый код -- одинаковый zip
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, open(src, 'rb').read())
print('lab-code.zip: %d файлов' % (len(files) + 1))
PY

# 4. СТОП.cmd: в репозитории с LF, на выходе строго CRLF (cmd).
sed 's/\r$//; s/$/\r/' "$here/exe/STOP.cmd" > "$out/RemoteAgents-Lab-STOP.cmd"

# 4б. Клиент меню Проводника (asInvoker): собирается до основного EXE и встраивается в него.
rm -rf "$out/publish-shell"
"$dotnet" publish "$here/exe/shell/RemoteAgents.Lab.Shell.csproj" -c Release -o "$out/publish-shell"
cp "$out/publish-shell/RemoteAgents-Lab-shell.exe" "$out/RemoteAgents-Lab-shell.exe"

# 5. Публикация EXE.
rm -rf "$out/publish"
"$dotnet" publish "$here/exe/RemoteAgents.Lab.csproj" -c Release \
  -p:LabVersion="$version" -p:PythonEmbedZip="$work/python-embed.zip" -p:LabCodeZip="$work/lab-code.zip" -p:BinZip="$work/bin.zip" -p:StopCmdPath="$out/RemoteAgents-Lab-STOP.cmd" -p:ShellExePath="$out/RemoteAgents-Lab-shell.exe" \
  -o "$out/publish"
cp "$out/publish/RemoteAgents-Lab.exe" "$out/RemoteAgents-Lab.exe"
echo "версия: $version"
ls -l "$out/RemoteAgents-Lab.exe" "$out/RemoteAgents-Lab-shell.exe" "$out/RemoteAgents-Lab-STOP.cmd"
sha256sum "$out/RemoteAgents-Lab.exe" "$out/RemoteAgents-Lab-STOP.cmd"
