package webui

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"testing"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/config"
	"remoteagents/internal/secret"
)

type cfgAct struct {
	fake.Actions
	cfg  []byte
	mode string
}

func (a *cfgAct) ConfigExport() ([]byte, error) { return a.cfg, nil }
func (a *cfgAct) ConfigSetVPN(ctx context.Context, mode string) error {
	a.mode = mode
	return nil
}

func sealedCfg(t *testing.T, pw string) []byte {
	t.Helper()
	salt := []byte("0123456789abcdef")
	key, err := secret.Derive(pw, salt, 10)
	if err != nil {
		t.Fatal(err)
	}
	seal := func(s string) string {
		v, err := secret.Seal(key, []byte(s))
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	b, _ := json.Marshal(map[string]any{
		"format": "remoteagents-2", "name": "pc-test",
		"server": map[string]any{"host": "h", "user": "u", "hostKey": "k", "key": seal("K\n")},
		"paths":  map[string]any{"channel": seal("{}")},
		"kdf":    map[string]any{"iterations": 10, "salt": base64.StdEncoding.EncodeToString(salt)},
		"check":  seal("remoteagents"),
	})
	return b
}

func startCfg(t *testing.T, act api.Actions) *UI {
	t.Helper()
	u, err := New(act, &fake.Logger{}, "")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	if err := u.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cancel)
	return u
}

func TestConfigExportNeedsTokenAndRoundTrips(t *testing.T) {
	want := sealedCfg(t, "pw")
	u := startCfg(t, &cfgAct{cfg: want})
	base := "http://127.0.0.1:" + itoa(u.Port()) + "/api/config"
	resp, err := http.Get(base)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatalf("без токена ответ %d", resp.StatusCode)
	}
	resp, err = http.Get(base + "?t=" + u.Token())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(got) != string(want) {
		t.Fatalf("code=%d body=%s", resp.StatusCode, got)
	}
	if _, err := config.Check(got, "pw"); err != nil {
		t.Fatalf("экспорт не проходит проверку: %v", err)
	}
}

func TestVPNEndpoint(t *testing.T) {
	act := &cfgAct{}
	u := startCfg(t, act)
	base := "http://127.0.0.1:" + itoa(u.Port()) + "/api/vpn"
	post := func(q, mode string) (int, string) {
		resp, err := http.PostForm(base+q, url.Values{"mode": {mode}})
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	if c, _ := post("", "auto"); c == http.StatusOK || act.mode != "" {
		t.Fatalf("без токена принято: %d", c)
	}
	if c, b := post("?t="+u.Token(), "bogus"); c != http.StatusBadRequest || act.mode != "" {
		t.Fatalf("неверный режим: %d %s", c, b)
	}
	if c, b := post("?t="+u.Token(), "only"); c != http.StatusOK || act.mode != "only" {
		t.Fatalf("only: %d %s mode=%q", c, b, act.mode)
	}
}
