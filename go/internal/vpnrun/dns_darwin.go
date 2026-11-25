package vpnrun

import "context"

const dnsHelper = "/Library/PrivilegedHelperTools/ru.remoteagents.vpn-dns"
const dnsScript = `#!/bin/sh
set -eu
marker='# RemoteAgents-Lab RA2-LAN'
if [ "$1" = clear ]; then
 for f in /etc/resolver/*; do
  [ -f "$f" ] || continue
  IFS= read -r first < "$f" || true
  [ "$first" != "$marker" ] || rm -f "$f"
 done
 exit 0
fi
[ "$1" = set ] || exit 1
domain=$2
address=$3
case "$domain" in ''|*[!a-z0-9.-]*|.*|*..*) exit 1;; esac
case "$address" in ''|*[!0-9.]* ) exit 1;; esac
mkdir -p /etc/resolver
f=/etc/resolver/$domain
if [ -e "$f" ]; then
 IFS= read -r first < "$f" || true
 [ "$first" = "$marker" ] || exit 1
fi
printf '%s\nnameserver %s\n' "$marker" "$address" > "$f"
`

func (r *Runner) dnsUpdate(ctx context.Context, address string, domains []string) error {
	if _, err := runContext(ctx, "sudo", "-n", dnsHelper, "clear"); err != nil {
		return err
	}
	for _, d := range domains {
		if _, err := runContext(ctx, "sudo", "-n", dnsHelper, "set", d, address); err != nil {
			return err
		}
	}
	return nil
}
