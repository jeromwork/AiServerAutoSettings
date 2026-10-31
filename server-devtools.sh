#!/usr/bin/env bash
# Public Ubuntu-only payload. No Windows runtime dependencies or project secrets.
set -Eeuo pipefail
umask 022
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $server_user != root ]] || exit 2
[[ $(id -u) == 0 ]] || exit 3
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || exit 4
server_home=$(getent passwd "$server_user" | cut -d: -f6)
[[ $(id -u "$server_user") != 0 && $server_home == /home/"$server_user" ]] || exit 5
base=/opt/remote-agents/devtools
node_version=24.22.2
node_sha=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
composer_version=2.11.0
composer_sha=9674f12a2a181100d889ebfd0b4510805b3e94cea57869b14b383753d602599b
# Validate privileged paths before checking markers, executing caches, or writing.
python3 -I - "$base" <<'DEVTOOLS_TRUST'
import os, stat, sys
from pathlib import Path
base=Path(sys.argv[1])
def trusted(path):
    s=path.lstat()
    assert not stat.S_ISLNK(s.st_mode) and s.st_uid==0 and not s.st_mode & 0o022, str(path)
for p in map(Path,('/', '/opt', '/usr', '/usr/local', '/usr/local/bin')): trusted(p)
for p in (base.parent,base):
    if os.path.lexists(p): trusted(p)
if base.exists():
    assert (base/'.remoteagents-managed').is_file(), 'Unmanaged devtools directory'
    for p in base.rglob('*'):
        s=p.lstat()
        if stat.S_ISLNK(s.st_mode):
            assert s.st_uid==0 and p.is_relative_to(base/'node-v24.22.2') and p.resolve().is_relative_to(base/'node-v24.22.2'), str(p)
        else: trusted(p)
for name in ('node','npm','npx','composer'):
    p=Path('/usr/local/bin')/name
    if os.path.lexists(p):
        assert p.is_symlink() and p.lstat().st_uid==0 and p.resolve().is_relative_to(base), 'Unmanaged command: '+str(p)
DEVTOOLS_TRUST
install -d -m 0755 "$base"
printf 'devtools-v1\n' > "$base/.remoteagents-managed"
stage=$(mktemp -d /tmp/remoteagents-devtools-install.XXXXXXXX)
chmod 0700 "$stage"
trap 'rm -rf -- "$stage"' EXIT
fetch() { /usr/bin/curl -q --fail --location --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 "$1" -o "$2"; }
packages=(ca-certificates curl xz-utils unzip git php8.3-cli php8.3-curl php8.3-mbstring php8.3-xml php8.3-zip php8.3-sqlite3)
missing=0
for package in "${packages[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || missing=1
done
if [[ $missing == 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update
  # Refuse package candidates supplied by a third-party repository.
  python3 -I - "${packages[@]}" <<'DEVTOOLS_APT'
import apt, sys
c=apt.Cache()
for name in sys.argv[1:]:
    candidate=c[name].candidate
    assert candidate and any(o.origin=='Ubuntu' and o.trusted and o.codename.startswith('noble') for o in candidate.origins), name
DEVTOOLS_APT
  apt-get install -y --no-install-recommends "${packages[@]}"
fi
node_dir="$base/node-v$node_version"
if [[ ! -e $node_dir ]]; then
  archive="node-v$node_version-linux-x64.tar.xz"
  fetch "https://nodejs.org/download/release/v$node_version/$archive" "$stage/$archive"
  fetch "https://nodejs.org/download/release/v$node_version/SHASUMS256.txt" "$stage/node-shasums"
  [[ $(awk -v name="$archive" '$2==name {print $1}' "$stage/node-shasums") == "$node_sha" ]] || exit 10
  printf '%s  %s\n' "$node_sha" "$stage/$archive" | sha256sum -c -
  tar -xJf "$stage/$archive" -C "$stage" --no-same-owner
  mv -- "$stage/node-v$node_version-linux-x64" "$node_dir"
  chmod -R go-w "$node_dir"
fi
[[ $("$node_dir/bin/node" --version) == v"$node_version" ]] || exit 11
composer_file="$base/composer-$composer_version.phar"
if [[ ! -e $composer_file ]]; then
  fetch https://getcomposer.org/installer "$stage/composer-setup.php"
  fetch https://composer.github.io/installer.sig "$stage/composer-setup.sig"
  expected=$(tr -d '\r\n' < "$stage/composer-setup.sig")
  [[ $expected =~ ^[a-f0-9]{96}$ && $(sha384sum "$stage/composer-setup.php" | cut -d' ' -f1) == "$expected" ]] || exit 12
  env -i HOME="$stage" PATH=/usr/bin:/bin /usr/bin/php "$stage/composer-setup.php" --version="$composer_version" --install-dir="$stage" --filename=composer.phar
  printf '%s  %s\n' "$composer_sha" "$stage/composer.phar" | sha256sum -c -
  install -m 0755 "$stage/composer.phar" "$composer_file"
fi
printf '%s  %s\n' "$composer_sha" "$composer_file" | sha256sum -c -
for name in node npm npx; do ln -sfn "$node_dir/bin/$name" "/usr/local/bin/$name"; done
ln -sfn "$composer_file" /usr/local/bin/composer
: > "$base/npm-user.conf"
: > "$base/npm-global.conf"
install -d -m 0755 "$base/demo-template/public"
cat > "$base/demo-template/package.json" <<'DEMO_PACKAGE'
{"name":"remoteagents-devtools-smoke","private":true,"version":"1.0.0","type":"module","scripts":{"build":"vite build"},"dependencies":{"vue":"3.5.44"},"devDependencies":{"vite":"8.3.5"},"engines":{"node":">=24.12.0 <25"}}
DEMO_PACKAGE
cat > "$base/demo-template/vite.config.mjs" <<'DEMO_VITE'
import { defineConfig } from 'vite'
export default defineConfig({ envDir: false, publicDir: false, build: { outDir: 'public/build', emptyOutDir: true } })
DEMO_VITE
cat > "$base/demo-template/index.html" <<'DEMO_HTML'
<!doctype html><html lang="ru"><meta charset="UTF-8"><title>VPS PHP + Vue smoke</title><div id="app">Загрузка теста…</div><script type="module" src="/main.js"></script></html>
DEMO_HTML
cat > "$base/demo-template/main.js" <<'DEMO_JS'
import { createApp, h, ref, onMounted } from 'vue'
createApp({ setup() {
  const status = ref('Проверка PHP…')
  const count = ref(0)
  onMounted(async () => {
    const data = await fetch('/api.php', { cache: 'no-store' }).then(r => { if (!r.ok) throw new Error(r.status); return r.json() })
    if (data.marker !== 'remoteagents-php-smoke') throw new Error('Unexpected backend')
    status.value = 'VUE_PHP_SMOKE_OK — PHP ' + data.php + ', Vue работает на VPS'
    document.documentElement.dataset.smoke = 'ready'
  })
  return () => h('main', { style: 'font:20px sans-serif;max-width:800px;margin:60px auto' }, [
    h('h1', 'Тестовый workspace сервера'), h('p', status.value),
    h('button', { onClick: () => count.value++ }, 'Проверить Vue: ' + count.value),
    h('p', 'Это отдельный тест. Данных рабочего проекта здесь нет.')
  ])
} }).mount('#app')
DEMO_JS
cat > "$base/demo-template/public/api.php" <<'DEMO_PHP'
<?php
declare(strict_types=1);
if ($_SERVER['REQUEST_METHOD'] !== 'GET') { http_response_code(405); exit; }
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
echo json_encode(['marker' => 'remoteagents-php-smoke', 'php' => PHP_VERSION], JSON_THROW_ON_ERROR);
DEMO_PHP
cat > "$base/demo-template/router.php" <<'DEMO_ROUTER'
<?php
declare(strict_types=1);
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/') { header('Content-Type: text/html; charset=utf-8'); readfile(__DIR__.'/public/build/index.html'); return true; }
if ($path === '/api.php') { require __DIR__.'/public/api.php'; return true; }
if (is_string($path) && str_starts_with($path, '/assets/') && preg_match('~^/assets/[a-zA-Z0-9_.-]+$~D', $path)) {
    $file = __DIR__.'/public/build'.$path;
    if (is_file($file)) { header('Content-Type: '.(str_ends_with($path, '.css') ? 'text/css' : 'application/javascript')); readfile($file); return true; }
}
http_response_code(404); return true;
DEMO_ROUTER
cat > "$base/demo-template/composer.json" <<'DEMO_COMPOSER'
{"name":"remoteagents/devtools-smoke","description":"Isolated PHP and Vue development smoke","type":"project","license":"proprietary","require":{"php":"^8.3"}}
DEMO_COMPOSER
cat > "$base/demo-template/start.sh" <<'DEMO_START'
#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
[[ $(id -u) != 0 ]] || { echo 'Run this test as your desktop user.' >&2; exit 2; }
echo 'Откройте в Chrome НА СЕРВЕРЕ: http://127.0.0.1:8088'
echo 'Остановить: Ctrl+C в этом терминале. Публичный порт не используется.'
exec /usr/bin/php8.3 -S 127.0.0.1:8088 -t public router.php
DEMO_START
chmod 0755 "$base/demo-template/start.sh"
cat > "$base/demo-workspace" <<'DEVTOOLS_WORKSPACE'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $(id -u) != 0 && $HOME == /home/"$(id -un)" ]] || exit 2
template=/opt/remote-agents/devtools/demo-template
workspace="$HOME/work/devtools-smoke"
[[ ! -L $HOME/work && ! -L $workspace ]] || exit 3
mkdir -p "$HOME/work"
if [[ ! -e $workspace ]]; then
  mkdir "$workspace"
  cp -R -- "$template/." "$workspace/"
  printf 'devtools-smoke-v1\n' > "$workspace/.remoteagents-smoke"
fi
[[ -f $workspace/.remoteagents-smoke && $(cat "$workspace/.remoteagents-smoke") == devtools-smoke-v1 ]] || { echo 'Unmanaged test workspace; preserved.' >&2; exit 4; }
# These are public demo files only. Preserve edits instead of running unknown code.
for name in package.json vite.config.mjs index.html main.js public/api.php router.php composer.json start.sh; do
  [[ ! -L $workspace/$name ]] && cmp -s "$template/$name" "$workspace/$name" || { echo "Edited demo preserved: $name" >&2; exit 5; }
done
cd "$workspace"
[[ ! -e .npmrc && ! -L .npmrc ]] || { echo 'Local npm configuration is present; automatic smoke skipped.' >&2; exit 6; }
npm_args=(--userconfig=/opt/remote-agents/devtools/npm-user.conf --globalconfig=/opt/remote-agents/devtools/npm-global.conf --cache "$workspace/.npm-cache" --registry=https://registry.npmjs.org --ignore-scripts --no-audit --no-fund --engine-strict)
if [[ -f package-lock.json ]]; then npm "${npm_args[@]}" ci; else npm "${npm_args[@]}" install; fi
npm "${npm_args[@]}" run build
/usr/bin/php8.3 -l public/api.php
/usr/bin/php8.3 -l router.php
composer_home=$(mktemp -d /tmp/remoteagents-composer-smoke.XXXXXXXX)
trap 'rm -rf -- "$composer_home"' EXIT
COMPOSER_HOME="$composer_home" COMPOSER_CACHE_DIR="$composer_home/cache" composer --no-plugins --no-scripts validate --strict
COMPOSER_HOME="$composer_home" COMPOSER_CACHE_DIR="$composer_home/cache" composer --no-plugins --no-scripts --version
if [[ -d $HOME/Desktop && ! -L $HOME/Desktop && ! -e $HOME/Desktop/RemoteAgents-Dev-Smoke.desktop ]]; then
  cat > "$HOME/Desktop/RemoteAgents-Dev-Smoke.desktop" <<SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=Тест PHP + Vue
Comment=Локальный тест разработки на сервере; остановить Ctrl+C
Exec=xfce4-terminal --hold --command "$workspace/start.sh"
Path=$workspace
Icon=utilities-terminal
Terminal=false
SHORTCUT
  chmod 0700 "$HOME/Desktop/RemoteAgents-Dev-Smoke.desktop"
fi
echo "DEMO_READY=$workspace/start.sh"
DEVTOOLS_WORKSPACE
chmod 0755 "$base/demo-workspace"
cat > "$base/android-preflight" <<'DEVTOOLS_ANDROID'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $(id -u) != 0 ]] || exit 2
for name in java javac adb sdkmanager emulator; do
  if command -v "$name" >/dev/null; then printf 'ANDROID_TOOL_%s=present\n' "$name"; else printf 'ANDROID_TOOL_%s=missing\n' "$name"; fi
done
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then echo ANDROID_KVM=accessible; else echo ANDROID_KVM=unavailable; fi
if awk '/^flags/ {for(i=1;i<=NF;i++)if($i=="vmx"||$i=="svm")found=1} END{exit !found}' /proc/cpuinfo; then echo ANDROID_CPU_VIRTUALIZATION=present; else echo ANDROID_CPU_VIRTUALIZATION=absent; fi
echo 'ANDROID_AVD=not-installed-not-tested'
DEVTOOLS_ANDROID
chmod 0755 "$base/android-preflight"
runuser -u "$server_user" -- env -i HOME="$server_home" USER="$server_user" LOGNAME="$server_user" PATH=/usr/local/bin:/usr/bin:/bin "$base/demo-workspace"
runuser -u "$server_user" -- env -i HOME="$server_home" PATH=/usr/local/bin:/usr/bin:/bin "$base/android-preflight"
runuser -u "$server_user" -- env -i HOME="$server_home" PATH=/usr/local/bin:/usr/bin:/bin node --version
runuser -u "$server_user" -- env -i HOME="$server_home" PATH=/usr/local/bin:/usr/bin:/bin npm --userconfig="$base/npm-user.conf" --globalconfig="$base/npm-global.conf" --version
/usr/bin/php8.3 -r 'if (PHP_MAJOR_VERSION!==8 || PHP_MINOR_VERSION!==3) exit(1); echo "PHP_VERSION=".PHP_VERSION.PHP_EOL;'
/usr/bin/git --version
echo "DEVTOOLS_READY=node-$node_version,php-8.3,composer-$composer_version,git"
