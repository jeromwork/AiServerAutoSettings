#!/bin/bash
# Offline fixtures only. All privileged/system/network operations are replaced below.
set -euo pipefail
cd "$(dirname "$0")"
fixture="$PWD/.offline-codex-fixture"
test ! -e "$fixture"
mkdir -p "$fixture/archive" "$fixture/root/etc" "$fixture/root/opt" "$fixture/root/usr/local/bin" "$fixture/root/usr/local/lib" "$fixture/root/var/lib"
trap 'rm -rf -- "$fixture"' EXIT
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$fixture/root/etc/os-release"
mkdir -p "$fixture/archive/bin" "$fixture/archive/codex-path" "$fixture/archive/codex-resources"
printf '#!/bin/bash\nprintf "codex-cli 0.166.0\\n"\n' > "$fixture/archive/bin/codex"
for name in bin/codex-code-mode-host bin/codex-exec-server codex-path/rg codex-resources/bwrap; do cp "$fixture/archive/bin/codex" "$fixture/archive/$name"; done
chmod -R 755 "$fixture/archive"
printf '{"version":"0.166.0","target":"x86_64-unknown-linux-musl","entrypoint":"bin/codex"}\n' > "$fixture/archive/codex-package.json"
tar -czf "$fixture/release.tar.gz" -C "$fixture/archive" .
digest=$(sha256sum "$fixture/release.tar.gz" | cut -d' ' -f1)
# Rewrite the copy, never the shipped script; every absolute write stays in the fixture.
sed -e "s|/etc/os-release|$fixture/root/etc/os-release|g" -e "s|/var/lib/remote-agents|$fixture/root/var/lib/remote-agents|g" -e "s|/home/remoteagents|$fixture/root/home/remoteagents|g" -e "s|/usr/local|$fixture/root/usr/local|g" -e "s|/opt|$fixture/root/opt|g" -e "s|1d44b28bc4ac9937d7d3532264baa68a507ce364956a0d4ebb856f331cdee254|$digest|g" server-codex-v1.sh > "$fixture/bootstrap.sh"
export FIXTURE="$fixture"
cat > "$fixture/mocks.sh" <<'MOCKS'
id() { if [ "$1" = -u ] && [ "$#" = 1 ]; then echo 0; elif [ "$1" = -u ]; then echo 1001; elif [ "$1" = -gn ]; then echo remoteagents; elif [ -d "$FIXTURE/root/home/remoteagents" ]; then return 0; else return 1; fi; }
uname() { echo x86_64; }
stat() { echo 0; }
find() { case "$*" in *-maxdepth*) if [ "${UNSAFE_CACHE:-0}" = 1 ]; then printf '%s\n' "$1"; fi ;; *'-user root'*) : ;; *) command find "$@" ;; esac; }
flock() { return 0; }
getent() { printf 'remoteagents:x:1001:1001::%s:/bin/bash\n' "$FIXTURE/root/home/remoteagents"; }
useradd() { mkdir -p "$FIXTURE/root/home/remoteagents"; }
runuser() { [ "$1" = -u ] && [ "$2" = remoteagents ] && [ "$3" = -- ] || exit 80; shift 3; "$@"; }
curl() { printf 'download\n' >> "$FIXTURE/downloads"; local output; while [ "$#" -gt 0 ]; do if [ "$1" = --output ]; then output=$2; shift; fi; shift; done; cp "$FIXTURE/release.tar.gz" "$output"; }
apt-get() { echo 'UNEXPECTED APT CALL' >&2; return 81; }
if [ -n "${FIXTURE_PYTHON:-}" ]; then python3() { "$FIXTURE_PYTHON" "$@"; }; export -f python3; fi
export -f id uname stat find flock getent useradd runuser curl apt-get
MOCKS
export BASH_ENV="$fixture/mocks.sh"
sed -e "s|/var/lib/remote-agents|$fixture/root/var/lib/remote-agents|g" -e "s|/home/remoteagents|$fixture/root/home/remoteagents|g" server-agent-user-v1.sh > "$fixture/account.sh"
bash "$fixture/account.sh" > "$fixture/account.out"
test ! -e "$fixture/downloads"
grep -q 'AGENT_ACCOUNT_READY=remoteagents' "$fixture/account.out"
bash "$fixture/bootstrap.sh" > "$fixture/first.out"
test "$(wc -l < "$fixture/downloads")" = 1
printf 'keep-work\n' > "$fixture/root/home/remoteagents/work/owner-file"
bash "$fixture/bootstrap.sh" > "$fixture/repeat.out"
test "$(wc -l < "$fixture/downloads")" = 1
test -f "$fixture/root/home/remoteagents/work/owner-file"
grep -q 'Existing Codex installation passed' "$fixture/repeat.out"
# A checksum-valid legacy single-binary cache must migrate, preserving its old tree.
release="$fixture/root/opt/remote-agents/codex/0.166.0"
rm "$release/codex-package.json"
(cd "$release" && find . -type f ! -name release.sha256 -exec sha256sum '{}' \; > "$fixture/legacy.sha256")
cp "$fixture/legacy.sha256" "$release/release.sha256"
bash "$fixture/bootstrap.sh" > "$fixture/migrate.out"
test "$(wc -l < "$fixture/downloads")" = 2
for name in codex-package.json bin/codex-code-mode-host bin/codex-exec-server codex-path/rg codex-resources/bwrap; do test -f "$release/$name"; done
test -n "$(find "$(dirname "$release")" -maxdepth 1 -name '0.166.0.previous.*' -print -quit)"
# Exercise the installed wrapper with public marker names and a harmless CLI stub.
mkdir -p "$fixture/commands"
cat > "$fixture/commands/codex" <<'PUBLIC_CLI'
#!/bin/bash
if [ "${1:-}" = login ]; then exit 0; fi
printf 'cwd=%s\n' "$PWD"
printf '%s\n' "$@"
PUBLIC_CLI
chmod 755 "$fixture/commands/codex"
sed -e 's|id -un|printf remoteagents|' -e "s|export PATH=|export PATH=$fixture/commands:|" "$fixture/root/usr/local/lib/remoteagents/codex-session" > "$fixture/session.sh"
name=windows-win-0123456789abcdef0123456789ab
touch "$fixture/root/var/lib/remote-agents/windows-mcp/$name"
touch "$fixture/root/var/lib/remote-agents/windows-mcp/unrelated-mcp"
bash "$fixture/session.sh" chat > "$fixture/server-chat.out"
grep -q "mcp_servers.$name.enabled=false" "$fixture/server-chat.out"
grep -q "cwd=$fixture/root/home/remoteagents/work" "$fixture/server-chat.out"
! grep -q unrelated-mcp "$fixture/server-chat.out"
bash "$fixture/session.sh" chat -c "mcp_servers.$name.enabled=true" > "$fixture/windows-chat.out"
test "$(tail -n 1 "$fixture/windows-chat.out")" = "mcp_servers.$name.enabled=true"
printf 'corrupt\n' > "$fixture/root/opt/remote-agents/codex/0.166.0/bin/codex"
bash "$fixture/bootstrap.sh" > "$fixture/repair.out"
test "$(wc -l < "$fixture/downloads")" = 3
test -f "$fixture/root/home/remoteagents/work/owner-file"
test -n "$(find "$fixture/root/opt/remote-agents/codex" -maxdepth 1 -name '0.166.0.previous.*' -print -quit)"
if UNSAFE_CACHE=1 bash "$fixture/bootstrap.sh" > "$fixture/unsafe.out" 2>&1; then echo 'unsafe path accepted'; exit 82; fi
test "$(wc -l < "$fixture/downloads")" = 3
# A wrong expected archive checksum must stop before replacing the active release.
sed "s|$digest|0000000000000000000000000000000000000000000000000000000000000000|g" "$fixture/bootstrap.sh" > "$fixture/bad-hash.sh"
printf 'corrupt-again\n' > "$fixture/root/opt/remote-agents/codex/0.166.0/bin/codex"
if bash "$fixture/bad-hash.sh" > "$fixture/hash.out" 2>&1; then echo 'wrong archive checksum accepted'; exit 83; fi
grep -q 'corrupt-again' "$fixture/root/opt/remote-agents/codex/0.166.0/bin/codex"
echo 'PASS: install/reuse/repair/preservation, unsafe-path/SHA denial, server-only wrapper/workdir, explicit Windows override; unrelated MCP untouched (offline fixtures; ownership mocked on Windows).'
