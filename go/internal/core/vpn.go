package core

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/singbox"
)

func (a *App) applyVPN(ctx context.Context) {
	a.vpnMu.Lock()
	defer a.vpnMu.Unlock()
	if ctx.Err() != nil {
		return
	}
	paths, _ := singbox.BuildPaths(a.vpnCfg, nil, "")
	var vpnPaths []api.VPNPath
	var excludes []string
	for _, p := range paths {
		vpnPaths = append(vpnPaths, api.VPNPath{Name: p.Name, Kind: p.Kind, Final: p.Final, Outs: p.Outbounds})
		for _, o := range p.Outbounds {
			if host, ok := o["server"].(string); ok {
				if ips, err := net.DefaultResolver.LookupHost(ctx, host); err == nil {
					excludes = append(excludes, ips...)
				}
			}
		}
	}
	for _, s := range a.vpnCfg.Servers {
		if ips, err := net.DefaultResolver.LookupHost(ctx, s.Host); err == nil {
			excludes = append(excludes, ips...)
		}
	}
	foreign := ""
	if ifaces, err := net.Interfaces(); err == nil {
		for _, i := range ifaces {
			n := strings.ToLower(i.Name)
			if i.Flags&net.FlagUp != 0 && i.Name != "RA2-VPN" && (strings.Contains(n, "tun") || strings.Contains(n, "wireguard") || strings.Contains(n, "ppp")) {
				foreign = i.Name
				break
			}
		}
	}
	rc := api.RenderContext{Cfg: a.vpnCfg, Mode: a.f.Mode, GeoIPPath: filepath.Join(a.p.State, "geoip-ru.srs"), ExcludeIPs: excludes}
	if err := singbox.ApplyVPN(ctx, rc, vpnPaths, foreign, a.vpn); err != nil {
		a.log.Warn("vpn.failed", "err", err)
		a.bus.Publish("vpn.state", map[string]any{"mode": a.vpnCfg.VPN.Mode, "state": err.Error()})
		return
	}
	a.bus.Publish("vpn.state", map[string]any{"mode": a.vpnCfg.VPN.Mode, "state": a.vpn.Running()})
}
func (a *App) loadVPNMode() {
	var state struct {
		Mode string `json:"mode"`
	}
	if b, err := os.ReadFile(filepath.Join(a.p.State, "vpn.json")); err == nil && json.Unmarshal(b, &state) == nil && (state.Mode == "off" || state.Mode == "auto" || state.Mode == "only") {
		a.vpnCfg.VPN.Mode = state.Mode
		var raw map[string]json.RawMessage
		_ = json.Unmarshal(a.vpnCfg.Raw, &raw)
		var v map[string]any
		_ = json.Unmarshal(raw["vpn"], &v)
		if v != nil {
			v["mode"] = state.Mode
			raw["vpn"], _ = json.Marshal(v)
			a.vpnCfg.Raw, _ = json.Marshal(raw)
		}
	}
}
