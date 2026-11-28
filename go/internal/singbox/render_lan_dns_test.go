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

// TUN ЛВС не регистрирует DNS на адаптере и не перехватывает порт 53 (иначе чужой strict-TUN глушит запросы).
func TestRenderLANNoDNS(t *testing.T) {
	b, err := Render(lanRC())
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Inbounds []map[string]any `json:"inbounds"`
		Route    struct {
			Rules []map[string]any `json:"rules"`
		} `json:"route"`
		DNS map[string]any `json:"dns"`
	}
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	var lan map[string]any
	for _, in := range v.Inbounds {
		if in["tag"] == "lan-in" {
			lan = in
		}
	}
	if lan == nil || lan["dns_mode"] != "disabled" {
		t.Fatalf("lan-in без dns_mode=disabled: %s", b)
	}
	for _, r := range v.Route.Rules {
		if r["action"] == "hijack-dns" {
			t.Fatalf("hijack-dns не нужен: %s", b)
		}
	}
	if v.DNS != nil {
		t.Fatalf("секция dns не нужна: %s", b)
	}
	if p, err := exec.LookPath("sing-box"); err == nil {
		f := filepath.Join(t.TempDir(), "c.json")
		os.WriteFile(f, b, 0600)
		if out, err := exec.Command(p, "check", "-c", f).CombinedOutput(); err != nil {
			t.Fatalf("sing-box check: %v %s", err, out)
		}
	}
}
