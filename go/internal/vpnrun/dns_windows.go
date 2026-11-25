package vpnrun

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Задача с теми же HighestAvailable, что sing-box. Ответ одной команды — TCP,
// без опроса файлов/состояния задачи. Скрипт ставится один раз в Install.
const dnsScript = `$ErrorActionPreference='Stop'
$p=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'vpn-dns-request.json') -Raw | ConvertFrom-Json
$result='ok'
try {
 Get-DnsClientNrptRule | Where-Object { $_.Comment -eq 'RemoteAgents-Lab RA2-LAN' } | ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }
 foreach ($d in $p.domains) { Add-DnsClientNrptRule -Namespace ('.'+$d) -NameServers $p.address -Comment 'RemoteAgents-Lab RA2-LAN' | Out-Null }
} catch { $result='DNS rule command failed' }
$c=[Net.Sockets.TcpClient]::new('127.0.0.1',[int]$p.port)
$b=[Text.Encoding]::UTF8.GetBytes($result)
$c.GetStream().Write($b,0,$b.Length)
$c.Dispose()
`

func (r *Runner) dnsUpdate(ctx context.Context, address string, domains []string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer ln.Close()
	stop := context.AfterFunc(ctx, func() { ln.Close() })
	defer stop()
	data, err := json.Marshal(map[string]any{"address": address, "domains": domains, "port": ln.Addr().(*net.TCPAddr).Port})
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(filepath.Dir(r.Conf), "vpn-dns-request.json"), data, 0600); err != nil {
		return err
	}
	if _, err = runContext(ctx, "schtasks.exe", "/Run", "/TN", label+".dns"); err != nil {
		return err
	}
	c, err := ln.Accept()
	if err != nil {
		return err
	}
	defer c.Close()
	deadline, _ := ctx.Deadline()
	_ = c.SetDeadline(deadline)
	out, err := io.ReadAll(io.LimitReader(c, 1024))
	if err != nil {
		return err
	}
	if string(out) != "ok" {
		return fmt.Errorf("vpnrun: %s", out)
	}
	return nil
}
