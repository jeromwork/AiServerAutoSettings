package singbox

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"remoteagents/internal/api"
)

func lanRC() api.RenderContext {
	return api.RenderContext{
		Cfg: &api.Config{
			Servers: []api.Server{{Host: "203.0.113.9", Port: 22}},
			LAN:     []api.LANCfg{{Share: api.LANShare{Enabled: true, Subnets: []string{"10.250.0.0/24"}}}},
		},
		Instance: "0123456789abcdef0123456789abcdef", ChanPort: 1081, ClashPort: 9090, ClashSecret: "s",
		LANSocks: "127.0.0.1:1090", Effective: api.Effective{LAN: true},
	}
}

// DNS-запросы к адресу TUN ЛВС перехватываются первым правилом и уходят на внешний DNS; прочее не затрагивается.
func TestRenderLANHijackDNS(t *testing.T) {
	b, err := Render(lanRC())
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Route struct {
			Rules []map[string]any `json:"rules"`
			Res   string           `json:"default_domain_resolver"`
		} `json:"route"`
		DNS struct {
			Final   string           `json:"final"`
			Servers []map[string]any `json:"servers"`
		} `json:"dns"`
	}
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	var h map[string]any
	for _, r := range v.Route.Rules {
		if r["action"] == "hijack-dns" {
			h = r
			break
		}
	}
	if h == nil || h["inbound"] != "lan-in" || h["port"] != float64(53) || h["ip_cidr"].([]any)[0] != "172.19.9.2/32" {
		t.Fatalf("нет узкого hijack-dns: %s", b)
	}
	if v.DNS.Final != "dns-up" || v.Route.Res != "dns-sys" || len(v.DNS.Servers) != 2 {
		t.Fatalf("dns: %s", b)
	}
	if p, err := exec.LookPath("sing-box"); err == nil {
		f := filepath.Join(t.TempDir(), "c.json")
		os.WriteFile(f, b, 0600)
		if out, err := exec.Command(p, "check", "-c", f).CombinedOutput(); err != nil {
			t.Fatalf("sing-box check: %v %s", err, out)
		}
	}
}
