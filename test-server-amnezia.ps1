$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('awg-offline-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $script=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-amnezia.sh'))
    $script=$script.Replace('source /etc/os-release','ID=ubuntu').Replace('base=/var/lib/remote-agents-vpn','base="$FIXTURE/state"')
    $prefix=@'
FIXTURE=$1
shift
id() { printf '0\n'; }
uname() { printf 'x86_64\n'; }
stat() { printf '0\n'; }
find() { :; }
flock() { :; }
systemctl() { :; }
ip() { if [[ -f $FIXTURE/conflict ]]; then printf '1: tun0: <UP>\n'; fi; }
ss() { :; }
docker() {
    case "$1" in
        image) return 0 ;;
        inspect)
            [[ -f $FIXTURE/container ]] || return 1
            if [[ $2 == -f ]]; then printf 'awg-v1\n'; fi ;;
        run)
            if [[ " $* " == *' --rm '* ]]; then
                cat >/dev/null
                printf 'fixture-private-not-a-key\n' > "$FIXTURE/state/server.key"
                printf 'fixture-server-public\n' > "$FIXTURE/state/server.pub"
            else touch "$FIXTURE/container"; fi ;;
        exec)
            if [[ $2 == -i ]]; then
                cat >/dev/null
                printf 'fixture-client-private\n' > "$FIXTURE/state/client.pending.key"
                printf 'fixture-client-public\n' > "$FIXTURE/state/client.pending.pub"
                printf 'fixture-psk\n' > "$FIXTURE/state/client.pending.psk"
            fi ;;
        start|ps) return 0 ;;
        *) printf 'Unexpected Docker call\n' >&2; return 91 ;;
    esac
}
'@
    $file=Join-Path $fixture 'run.sh'
    [IO.File]::WriteAllText($file,($prefix+"`n"+$script).Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
    $bash='C:\Program Files\Git\bin\bash.exe'
    $client='0123456789abcdef0123456789abcdef'
    $out=@(& $bash $file.Replace('\','/') $fixture.Replace('\','/') '203.0.113.5' $client)
    if($LASTEXITCODE -ne 0 -or $out -notcontains 'Endpoint = 203.0.113.5:51820' -or $out -notcontains 'Address = 10.203.77.2/32'){throw 'Fresh server config failed'}
    $serverConfig=Join-Path $fixture 'state\awg0.conf'
    $before=(Get-FileHash -LiteralPath $serverConfig).Hash
    $again=@(& $bash $file.Replace('\','/') $fixture.Replace('\','/') '203.0.113.5' $client)
    if($LASTEXITCODE -ne 0 -or ($out -join "`n") -cne ($again -join "`n") -or (Get-FileHash -LiteralPath $serverConfig).Hash -ne $before){throw 'Rerun changed keys or duplicated peers'}
    $second=@(& $bash $file.Replace('\','/') $fixture.Replace('\','/') '203.0.113.5' '1123456789abcdef0123456789abcdef')
    if($LASTEXITCODE -ne 0 -or $second -notcontains 'Address = 10.203.77.3/32'){throw 'Second client address allocation failed'}
    $conflict=Join-Path $fixture 'other-vpn'
    [void][IO.Directory]::CreateDirectory($conflict)
    [IO.File]::WriteAllText((Join-Path $conflict 'conflict'),'fixture')
    $conflictOut=@(& $bash $file.Replace('\','/') $conflict.Replace('\','/') '203.0.113.5' $client)
    if($LASTEXITCODE -ne 13 -or $conflictOut.Count -ne 0 -or (Test-Path -LiteralPath (Join-Path $conflict 'container'))){throw 'Existing VPN was not preserved'}
    Write-Output 'PASS: offline AmneziaWG provisioning, stable rerun, separate clients, existing VPN refusal. Docker/network/system changes mocked.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'awg-offline-*'){throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
